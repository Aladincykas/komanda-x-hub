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

-- Two-row touch control bar: row h-1 is info text (elapsed/volume%/
-- remaining), row h is real buttons with known hit-test rectangles. This
-- screen draws the whole video frame with raw mon.blit every frame (like
-- the main menu's matrix rain, at a much higher redraw rate), so it can't
-- use Basalt here the same way the music player does -- Basalt only
-- repaints on property changes, and a full-screen redraw every frame would
-- either fight it or get overdrawn by it. Buttons are just drawn rectangles
-- + monitor_touch hit-testing, computed fresh each call and reused by the
-- input handler below.
local function buildButtonLayout(w, h)
    local labels = { "Pause", "Stop", "-10%", "-1%", "+1%", "+10%" }
    local n = #labels
    local gap = 1
    local btnW = math.max(4, math.floor((w - gap * (n - 1)) / n))
    local totalW = btnW * n + gap * (n - 1)
    local startX = math.max(1, math.floor((w - totalW) / 2) + 1)
    local buttons = {}
    for i, label in ipairs(labels) do
        local x1 = startX + (i - 1) * (btnW + gap)
        buttons[i] = { label = label, x1 = x1, x2 = x1 + btnW - 1, y = h, w = btnW }
    end
    return buttons
end

local function drawControls(mon, w, h, state, totalDurationSec, buttons)
    local elapsed = state.elapsedSec
    local remaining = math.max(0, totalDurationSec - elapsed)
    local pct = math.floor(state.volume / state.maxVolume * 100 + 0.5)

    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.white)
    mon.setCursorPos(1, h - 1)
    mon.clearLine()
    local infoText = ("%s   Vol %d%%   -%s"):format(formatTime(elapsed), pct, formatTime(remaining))
    mon.setCursorPos(math.max(1, math.floor((w - #infoText) / 2) + 1), h - 1)
    mon.write(infoText)

    mon.setCursorPos(1, h)
    mon.clearLine()
    for i, btn in ipairs(buttons) do
        local label = (i == 1 and state.paused) and "Play" or btn.label
        mon.setCursorPos(btn.x1, btn.y)
        mon.setBackgroundColor(i == 2 and colors.red or colors.gray)
        mon.setTextColor(colors.lime)
        local text = label
        local pad = btn.w - #text
        local leftPad = math.floor(pad / 2)
        mon.write((" "):rep(math.max(0, leftPad)) .. text .. (" "):rep(math.max(0, pad - leftPad)))
    end

    mon.setBackgroundColor(colors.black)
end

local function hitTestButton(buttons, x, y)
    for i, btn in ipairs(buttons) do
        if y == btn.y and x >= btn.x1 and x <= btn.x2 then return i end
    end
    return nil
end

local function drawFrame(mon, image)
    for i, v in ipairs(image.palette) do
        mon.setPaletteColor(2 ^ (i - 1), table.unpack(v))
    end
    for y, r in ipairs(image) do
        mon.setCursorPos(1, y)
        mon.blit(table.unpack(r))
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

        local ok, decoded = pcall(decodeModule.decode, file, function(i, n)
            drawLoading(mon, w, h, ("Loading %s (part %d/%d) %d%%..."):format(entry.name, chunkIndex, #entry.chunks, math.floor(i / n * 100)))
        end)
        if not ok then
            if tostring(decoded):find("Terminated") then error(decoded, 0) end -- see the note by the playback pcall below
            drawLoading(mon, w, h, "Video decode error: " .. tostring(decoded))
            os.sleep(2)
            result = "done"
            break
        end

        local fps = decoded.fps
        local nFrames = #decoded.video
        local buttons = buildButtonLayout(w, h)

        local function saveVolume()
            savedSettings.videoVolume = state.volume
            settings.save(savedSettings)
        end
        local function adjustVolume(deltaFraction)
            local step = deltaFraction * state.maxVolume
            state.volume = math.max(0, math.min(state.maxVolume, state.volume + step))
            saveVolume()
        end

        local playOk, playErr = pcall(function()
            parallel.waitForAll(
                function() -- video render, paced to fps
                    local start = os.epoch("utc")
                    local f = 1
                    while f <= nFrames and not state.stopRequested do
                        while state.paused and not state.stopRequested do
                            os.pullEvent("video_control")
                            start = os.epoch("utc") - (f - 1) / fps * 1000 -- resume timing cleanly
                        end
                        if state.stopRequested then break end

                        drawFrame(mon, decoded.video[f])
                        state.elapsedSec = cumulativeSec + (f - 1) / fps
                        drawControls(mon, w, h, state, entry.durationSec or 0, buttons)

                        while os.epoch("utc") < start + (f + 1) / fps * 1000 do
                            os.sleep(1 / fps)
                            if state.stopRequested then break end
                        end
                        f = f + 1
                    end
                    cumulativeSec = cumulativeSec + nFrames / fps
                end,
                function() -- audio, fanned out to every networked speaker
                    if not decoded.audio or #speakers == 0 then return end
                    local funcs = {}
                    for _, speaker in ipairs(speakers) do
                        funcs[#funcs + 1] = function()
                            for _, chunk in ipairs(decoded.audio) do
                                if state.stopRequested then break end
                                -- Timeout on speaker_audio_empty, NOT an
                                -- unbounded wait -- with many networked
                                -- speakers (confirmed: this installation
                                -- has dozens), if even ONE never fires that
                                -- event (out of range, disconnected,
                                -- whatever), the whole video froze forever
                                -- waiting on it (confirmed in-game: playback
                                -- stuck at a fixed elapsed time with no
                                -- error). After 3s of no response from THIS
                                -- speaker, just move on instead of hanging.
                                while not state.stopRequested and not speaker.playAudio(chunk, state.volume) do
                                    local timerId = os.startTimer(3)
                                    local gaveUp = false
                                    repeat
                                        local ev, a, b = os.pullEvent()
                                        if ev == "speaker_audio_empty" and a == peripheral.getName(speaker) then
                                            break
                                        elseif ev == "timer" and a == timerId then
                                            gaveUp = true
                                            break
                                        end
                                    until state.stopRequested
                                    if gaveUp or state.stopRequested then break end
                                end
                            end
                        end
                    end
                    parallel.waitForAll(table.unpack(funcs))
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
