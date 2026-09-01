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
    function file.read(n)
        if pos > #body then return nil end
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

-- Draws the bottom control bar on top of whatever frame is currently shown.
local function drawControls(mon, w, h, state, totalDurationSec)
    local elapsed = state.elapsedSec
    local remaining = math.max(0, totalDurationSec - elapsed)

    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.white)
    mon.setCursorPos(1, h)
    mon.clearLine()

    local playIcon = state.paused and "||" or ">"
    local left = (" %s %s"):format(playIcon, formatTime(elapsed))
    local right = ("-%s "):format(formatTime(remaining))
    local volSegments = 8
    local filled = math.max(0, math.min(volSegments, math.floor((state.volume / state.maxVolume) * volSegments + 0.5)))
    local volBar = ("Vol[" .. ("#"):rep(filled) .. ("-"):rep(volSegments - filled) .. ("%3d%%"):format(math.floor(state.volume / state.maxVolume * 100 + 0.5)) .. "]")

    mon.setCursorPos(1, h)
    mon.write(left)
    mon.setCursorPos(w - #right + 1, h)
    mon.write(right)
    local volX = math.max(#left + 2, math.floor((w - #volBar) / 2) + 1)
    mon.setCursorPos(volX, h)
    mon.write(volBar)

    mon.setBackgroundColor(colors.black)
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
                        drawControls(mon, w, h, state, entry.durationSec or 0)

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
                                while not state.stopRequested and not speaker.playAudio(chunk, state.volume) do
                                    repeat
                                        local ev, name = os.pullEvent("speaker_audio_empty")
                                    until state.stopRequested or name == peripheral.getName(speaker)
                                end
                            end
                        end
                    end
                    parallel.waitForAll(table.unpack(funcs))
                end,
                function() -- input handling
                    while not state.stopRequested do
                        local ev, key = os.pullEvent("key")
                        if key == keys.space then
                            state.paused = not state.paused
                            os.queueEvent("video_control")
                        elseif key == keys.s then
                            state.stopRequested = true
                            os.queueEvent("video_control")
                        elseif key == keys.left then
                            state.volume = math.max(0, math.floor((state.volume - 0.1) * 10 + 0.5) / 10)
                            savedSettings.videoVolume = state.volume
                            settings.save(savedSettings)
                        elseif key == keys.right then
                            state.volume = math.min(state.maxVolume, math.floor((state.volume + 0.1) * 10 + 0.5) / 10)
                            savedSettings.videoVolume = state.volume
                            settings.save(savedSettings)
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
