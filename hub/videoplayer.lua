-- videoplayer.lua -- full-screen 32vid playback on the wrapped monitor,
-- with a bottom control bar (play/pause, elapsed/remaining, volume) laid
-- over the video, chaining through a video's chunk list fetched from
-- raw.githubusercontent.com. Uses hub/vendor/32vid-decode.lua (a lightly
-- adapted copy of sanjuuni's own player) for the actual frame decoding --
-- see that file's header comment before touching the decode logic.

local decodeModule = require("vendor.32vid-decode")
local settings = require("settings")

local M = {}

local function drawLoading(mon, w, h, text)
    mon.setBackgroundColor(colors.black)
    mon.clear()
    mon.setTextColor(colors.white)
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    mon.setCursorPos(x, math.floor(h / 2))
    mon.write(text)
end

-- Downloads a chunk straight into memory and returns a "file"-like table
-- (read/seek/close) the decoder can use directly, exactly the same way
-- musicplayer.lua streams DFPWM straight from an http response without
-- ever touching disk. The original version here wrote the chunk to a temp
-- file on the COMPUTER's own storage first -- CC computers typically have
-- a tiny disk quota (well under 1MB in a lot of server configs), and even
-- a modest video segment blows straight through that ("Out of space",
-- confirmed in-game). There's no reason to touch the filesystem for this
-- at all; the whole point of streaming is that the bytes are already in
-- memory the moment http.get finishes.
local function fetchChunkToMemory(url)
    local cacheBustUrl = url .. (url:find("?") and "&" or "?") .. "t=" .. tostring(os.epoch("utc"))
    local response, err = http.get(cacheBustUrl, nil, true)
    if not response then
        error("Failed to download video chunk: " .. tostring(err))
    end
    local body = response.readAll()
    response.close()
    if not body or #body == 0 then
        error("Downloaded video chunk was empty (0 bytes) -- check the chunk actually has data.")
    end

    local pos = 1
    local file = {}
    -- Must match real fs.open(path,"rb")'s contract exactly, not just the
    -- "n bytes as a string" form: file.read() with NO argument returns ONE
    -- byte AS A NUMBER (0-255) or nil at EOF -- the ANS decoder in
    -- vendor/32vid-decode.lua reads bit-by-bit this way constantly
    -- (readDict, readbits). Calling body:sub(pos, pos+n-1) with n=nil
    -- crashed with "attempt to perform arithmetic" (confirmed in-game) --
    -- the old decoder never needed the no-argument form, the new one relies
    -- on it throughout.
    function file.read(n)
        if pos > #body then return nil end
        if n == nil then
            local b = body:byte(pos)
            pos = pos + 1
            return b
        end
        local piece = body:sub(pos, pos + n - 1)
        pos = pos + #piece
        return piece
    end
    -- decodeModule only calls seek() with no arguments, to report a
    -- position in an error message -- not used for actual seeking.
    function file.seek()
        return pos - 1
    end
    function file.close() end
    return file
end

local function formatTime(seconds)
    if seconds < 0 then seconds = 0 end
    seconds = math.floor(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return ("%d:%02d"):format(m, s)
end

-- ONE line, black background: elapsed time on the left, small buttons in
-- the middle, remaining time on the right. This screen draws the whole
-- video frame with raw mon.blit every frame (like the main menu's matrix
-- rain, at a much higher redraw rate), so it can't use Basalt here the way
-- the music player does -- Basalt only repaints on property changes, and a
-- full-screen redraw every frame would either fight it or get overdrawn by
-- it. Buttons are just drawn rectangles + monitor_touch hit-testing,
-- computed fresh each call and reused by the input handler below.
local BUTTON_LABELS = { "||", "X", "<<", "<", ">", ">>" } -- pause/play, stop, -10%, -1%, +1%, +10%
local function buildButtonLayout(w, h, centerX)
    local n = #BUTTON_LABELS
    local btnW = 3
    local gap = 1
    local totalW = btnW * n + gap * (n - 1)
    local startX = math.max(1, centerX - math.floor(totalW / 2))
    local buttons = {}
    for i, label in ipairs(BUTTON_LABELS) do
        local x1 = startX + (i - 1) * (btnW + gap)
        buttons[i] = { label = label, x1 = x1, x2 = x1 + btnW - 1, y = h, w = btnW }
    end
    return buttons
end

local function drawControls(mon, w, h, state, totalDurationSec, buttons)
    local elapsed = state.elapsedSec
    local remaining = math.max(0, totalDurationSec - elapsed)
    local pct = math.floor(state.volume / state.maxVolume * 100 + 0.5)

    mon.setBackgroundColor(colors.black)
    mon.setCursorPos(1, h)
    mon.clearLine()

    local playIcon = state.paused and ">" or "||"
    local left = (" %s %s"):format(playIcon, formatTime(elapsed))
    local right = ("%d%% -%s "):format(pct, formatTime(remaining))

    mon.setTextColor(colors.white)
    mon.setCursorPos(1, h)
    mon.write(left)
    mon.setCursorPos(w - #right + 1, h)
    mon.write(right)

    for i, btn in ipairs(buttons) do
        local label = (i == 1 and state.paused) and ">" or btn.label
        mon.setCursorPos(btn.x1, btn.y)
        mon.setTextColor(i == 2 and colors.red or colors.lime)
        local pad = btn.w - #label
        local leftPad = math.floor(pad / 2)
        mon.write((" "):rep(math.max(0, leftPad)) .. label .. (" "):rep(math.max(0, pad - leftPad)))
    end

    mon.setBackgroundColor(colors.black)
end

local function hitTestButton(buttons, x, y)
    for i, btn in ipairs(buttons) do
        if y == btn.y and x >= btn.x1 and x <= btn.x2 then return i end
    end
    return nil
end

-- lastPalette (a {r,g,b} per color, mutated in place) lets this skip a
-- setPaletteColor call for any color that didn't actually change since the
-- previous frame. lastRows (a {text,fg,bg} per row, mutated in place) does
-- the same for mon.blit -- skip rows that are byte-for-byte identical to
-- what's already on screen. Capping fps alone didn't fix the physical
-- monitor corrupting (confirmed in-game even at 10fps), which points at
-- total data per redraw being the real cost, not calls-per-second -- a
-- video like Bad Apple has large static black/white regions, so most rows
-- often don't change between consecutive frames at all. This keeps full
-- resolution (no downgrade) while cutting actual blit throughput based on
-- what's really different, frame to frame.
local function drawFrame(mon, image, lastPalette, lastRows)
    for i, v in ipairs(image.palette) do
        local prev = lastPalette[i]
        if not prev or prev[1] ~= v[1] or prev[2] ~= v[2] or prev[3] ~= v[3] then
            mon.setPaletteColor(2 ^ (i - 1), v[1], v[2], v[3])
            lastPalette[i] = v
        end
    end
    for y, r in ipairs(image) do
        local prevRow = lastRows[y]
        if not prevRow or prevRow[1] ~= r[1] or prevRow[2] ~= r[2] or prevRow[3] ~= r[3] then
            mon.setCursorPos(1, y)
            mon.blit(r[1], r[2], r[3])
            lastRows[y] = r
        end
    end
end

local function resetPalette(mon)
    for i = 0, 15 do
        mon.setPaletteColor(2 ^ i, mon.nativePaletteColor and mon.nativePaletteColor(2 ^ i) or 0)
    end
end

-- Plays every chunk of `entry` ({name, chunks, width, height, fps,
-- durationSec}) in order. Returns "done" when playback finishes normally,
-- or "stopped" if the user pressed S. Any key other than the recognized
-- controls is ignored (there is no idle-timeout *during* playback -- only
-- the video/music list screens time out).
function M.play(mon, speakers, entry, config)
    local w, h = mon.getSize()
    -- Volume persists across videos/sessions (same fix as the music
    -- player) instead of resetting to config.DEFAULT_VOLUME -- and loud --
    -- every single time.
    local savedSettings = settings.load()
    local state = {
        paused = false,
        stopRequested = false,
        volume = savedSettings.videoVolume or config.DEFAULT_VOLUME,
        maxVolume = config.MAX_VOLUME,
        elapsedSec = 0,
    }

    local cumulativeSec = 0
    local result = "done"

    for chunkIndex, url in ipairs(entry.chunks) do
        if state.stopRequested then break end

        drawLoading(mon, w, h, ("Loading %s (part %d/%d)..."):format(entry.name, chunkIndex, #entry.chunks))

        local file = fetchChunkToMemory(url)
        drawLoading(mon, w, h, ("Decoding %s (part %d/%d)..."):format(entry.name, chunkIndex, #entry.chunks))

        local buttons = buildButtonLayout(w, h, math.floor(w / 2) + 1)

        local function saveVolume()
            savedSettings.videoVolume = state.volume
            settings.save(savedSettings)
        end
        local function adjustVolume(deltaFraction)
            local step = deltaFraction * state.maxVolume
            state.volume = math.max(0, math.min(state.maxVolume, state.volume + step))
            saveVolume()
        end

        -- Streaming decode+play: decodeModule.decode() calls these
        -- handlers inline as it reads through the chunk, one record at a
        -- time (see vendor/32vid-decode.lua's header comment for why this
        -- replaced the old decode-everything-into-arrays-first approach).
        -- Video frames are paced to fps and drawn here; audio chunks are
        -- fired at every speaker with no wait/retry, exactly like
        -- sanjuuni's own reference player -- the video pacing (interleaved
        -- with audio records in file order) is what keeps playback roughly
        -- real-time, not a separate acknowledgment-based audio clock.
        local fps = 10
        local frameStart = os.epoch("utc")
        local lastPalette, lastRows = {}, {}
        local framesPlayed = 0

        local handlers = {
            shouldStop = function() return state.stopRequested end,
            onHeader = function(_, _, headerFps)
                fps = headerFps
                frameStart = os.epoch("utc")
            end,
            onVideoFrame = function(frame, frameIndex)
                while state.paused and not state.stopRequested do
                    os.pullEvent("video_control")
                    frameStart = os.epoch("utc") - (frameIndex - 1) / fps * 1000 -- resume timing cleanly
                end
                if state.stopRequested then return end

                drawFrame(mon, frame, lastPalette, lastRows)
                state.elapsedSec = cumulativeSec + (frameIndex - 1) / fps
                drawControls(mon, w, h, state, entry.durationSec or 0, buttons)
                framesPlayed = frameIndex

                while os.epoch("utc") < frameStart + (frameIndex + 1) / fps * 1000 do
                    os.sleep(1 / fps)
                    if state.stopRequested then break end
                end
            end,
            onAudioChunk = function(chunk)
                if state.stopRequested then return end
                for _, speaker in ipairs(speakers) do
                    speaker.playAudio(chunk, state.volume)
                end
            end,
        }

        local playOk, playErr = pcall(function()
            parallel.waitForAny(
                function()
                    decodeModule.decode(file, handlers)
                    cumulativeSec = cumulativeSec + framesPlayed / fps
                end,
                function() -- input handling: keyboard (at the Computer) and touch (at the monitor)
                    while not state.stopRequested do
                        local event, a, b, c = os.pullEvent()
                        local action = nil

                        if event == "key" then
                            if a == keys.space then action = "playpause"
                            elseif a == keys.s then action = "stop"
                            elseif a == keys.left then action = "vol-1"
                            elseif a == keys.right then action = "vol+1"
                            end
                        elseif event == "monitor_touch" then
                            local idx = hitTestButton(buttons, b, c)
                            if idx == 1 then action = "playpause"
                            elseif idx == 2 then action = "stop"
                            elseif idx == 3 then action = "vol-10"
                            elseif idx == 4 then action = "vol-1"
                            elseif idx == 5 then action = "vol+1"
                            elseif idx == 6 then action = "vol+10"
                            end
                        end

                        if action == "playpause" then
                            state.paused = not state.paused
                            os.queueEvent("video_control")
                        elseif action == "stop" then
                            state.stopRequested = true
                            os.queueEvent("video_control")
                        elseif action == "vol-1" then adjustVolume(-0.01)
                        elseif action == "vol+1" then adjustVolume(0.01)
                        elseif action == "vol-10" then adjustVolume(-0.10)
                        elseif action == "vol+10" then adjustVolume(0.10)
                        end
                    end
                end
            )
        end)

        for _, speaker in ipairs(speakers) do pcall(speaker.stop) end
        resetPalette(mon)

        if not playOk then
            -- Ctrl+T raises "Terminated" through os.pullEvent -- pcall would
            -- otherwise silently swallow that and let playback continue, so
            -- Ctrl+T would appear to do nothing while a video is playing.
            -- Re-raise it so termination actually propagates and stops the
            -- whole program, same as it would anywhere else.
            if tostring(playErr):find("Terminated") then
                mon.setBackgroundColor(colors.black)
                mon.setTextColor(colors.white)
                mon.clear()
                error(playErr, 0)
            end
            drawLoading(mon, w, h, "Playback error: " .. tostring(playErr))
            os.sleep(2)
            result = "done"
            break
        end

        if state.stopRequested then
            result = "stopped"
            break
        end
    end

    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.clear()
    return result
end

return M
