-- musicplayer.lua -- the original Pocket-Computer jukebox (music.lua),
-- ported to draw on a wrapped monitor instead of the terminal, driven by
-- hub/config.lua's MUSIC_LIBRARIES, and extended with a few switchable
-- visualizer patterns (cycle with V) plus a return-to-menu key (Tab) and an
-- idle timeout back to the main menu, matching the video menu's behavior.

local dfpwm = require("cc.audio.dfpwm")

local M = {}

local function buildManifestUrls(config)
    local urls = {}
    for _, lib in ipairs(config.MUSIC_LIBRARIES) do
        table.insert(urls, ("https://raw.githubusercontent.com/%s/%s/%s/songs.json")
            :format(config.GITHUB_USER, lib.repo, lib.branch))
    end
    return urls
end

function M.run(mon, speakers, config)
    local w, h = mon.getSize()
    local manifestUrls = buildManifestUrls(config)

    local songs = {}
    local loadError = nil

    local function fetchSongs()
        loadError = nil
        songs = {}
        local errors = {}
        for _, manifestUrl in ipairs(manifestUrls) do
            local cacheBustUrl = manifestUrl .. "?t=" .. tostring(os.epoch("utc"))
            local response, err, failingResponse = http.get(cacheBustUrl)
            if not response then
                local code = failingResponse and failingResponse.getResponseCode
                    and select(1, failingResponse.getResponseCode())
                if code ~= 404 then
                    table.insert(errors, manifestUrl .. " -> " .. tostring(err))
                end
            else
                local body = response.readAll()
                response.close()
                local parsed = textutils.unserialiseJSON(body)
                if type(parsed) ~= "table" then
                    table.insert(errors, manifestUrl .. " -> invalid JSON")
                else
                    for _, song in ipairs(parsed) do table.insert(songs, song) end
                end
            end
        end
        if #errors > 0 then loadError = table.concat(errors, "; ") end
    end

    fetchSongs()

    local state = {
        screen = "library",
        filter = "",
        selected = 1,
        scrollOffset = 0,
        playing = false,
        paused = false,
        stopRequested = false,
        nowPlaying = nil,
        elapsedBytes = 0,
        volume = config.DEFAULT_VOLUME,
        vizPattern = 1,
    }

    local VIZ_PATTERNS = { "bars", "wave", "starfield" }

    local function listHeight()
        local lh = h - 4 - 2
        return lh < 1 and 1 or lh
    end

    local function filteredSongs()
        if state.filter == "" then return songs end
        local out = {}
        local f = state.filter:lower()
        for _, s in ipairs(songs) do
            if s.name:lower():find(f, 1, true) then table.insert(out, s) end
        end
        return out
    end

    local function formatTime(seconds)
        seconds = math.floor(seconds)
        local m = math.floor(seconds / 60)
        local s = seconds % 60
        return ("%d:%02d"):format(m, s)
    end

    local function drawLibrary()
        mon.setBackgroundColor(colors.black)
        mon.clear()

        mon.setCursorPos(1, 1)
        mon.setTextColor(colors.yellow)
        mon.setBackgroundColor(colors.gray)
        mon.clearLine()
        mon.write((" MUSIC LIBRARY "):sub(1, w))

        mon.setCursorPos(1, 2)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.lightGray)
        mon.clearLine()
        mon.write("Search: ")
        mon.setTextColor(colors.white)
        mon.write(state.filter)

        local list = filteredSongs()
        local listTop = 4
        local lh = listHeight()

        if #list == 0 then
            state.selected = 0
            state.scrollOffset = 0
        else
            if state.selected > #list then state.selected = #list end
            if state.selected < 1 then state.selected = 1 end
            if state.selected <= state.scrollOffset then
                state.scrollOffset = state.selected - 1
            elseif state.selected > state.scrollOffset + lh then
                state.scrollOffset = state.selected - lh
            end
            local maxOffset = math.max(0, #list - lh)
            state.scrollOffset = math.max(0, math.min(state.scrollOffset, maxOffset))
        end

        for i = 1, lh do
            local idx = state.scrollOffset + i
            local song = list[idx]
            local selectedRow = song and idx == state.selected
            local text = song and ((" " .. song.name):sub(1, w)) or ""
            if #text < w then text = text .. (" "):rep(w - #text) end
            local fgChar = colors.toBlit(colors.white)
            local bgChar
            if selectedRow then bgChar = colors.toBlit(colors.lightBlue)
            elseif song then bgChar = colors.toBlit((idx % 2 == 0) and colors.black or colors.gray)
            else bgChar = colors.toBlit(colors.black) end
            mon.setCursorPos(1, listTop + i - 1)
            mon.blit(text, fgChar:rep(w), bgChar:rep(w))
        end
        mon.setBackgroundColor(colors.black)

        mon.setBackgroundColor(colors.gray)
        mon.setTextColor(colors.white)
        mon.setCursorPos(1, h - 1)
        mon.clearLine()
        if loadError then
            mon.write((" Load error: " .. loadError):sub(1, w))
        elseif #list == 0 then
            mon.write(" No songs found ")
        else
            mon.write((" %d song(s) - %d librar%s "):format(#list, #config.MUSIC_LIBRARIES,
                #config.MUSIC_LIBRARIES == 1 and "y" or "ies"):sub(1, w))
        end

        mon.setCursorPos(1, h)
        mon.setBackgroundColor(colors.gray)
        mon.setTextColor(colors.lightGray)
        mon.clearLine()
        mon.write((" Up/Down: select  Enter: play  F5: refresh  Tab: main menu "):sub(1, w))

        mon.setBackgroundColor(colors.black)
    end

    -- === Visualizer patterns ===
    local LEVEL_CHARS = { " ", ".", ":", "-", "=", "+", "*", "#" }
    local LEVEL_COLORS = {
        colors.gray, colors.cyan, colors.lightBlue, colors.lime,
        colors.lime, colors.yellow, colors.orange, colors.red,
    }
    local bgBlitBlack = colors.toBlit(colors.black)
    local wavePhase = 0
    local stars = {}

    local function drawBars(y, width)
        local startX = math.floor((w - width) / 2) + 1
        local maxLevel = #LEVEL_CHARS - 1
        local chars, fg = {}, {}
        for i = 1, width do
            local level = (state.playing and not state.paused) and math.random(0, maxLevel) or 0
            chars[i] = LEVEL_CHARS[level + 1]
            fg[i] = colors.toBlit(LEVEL_COLORS[level + 1])
        end
        mon.setCursorPos(startX, y)
        mon.blit(table.concat(chars), table.concat(fg), bgBlitBlack:rep(width))
    end

    local function drawWave(y, width)
        local startX = math.floor((w - width) / 2) + 1
        wavePhase = wavePhase + (state.playing and not state.paused and 0.6 or 0)
        local chars, fg = {}, {}
        for i = 1, width do
            local v = math.sin((i / width) * math.pi * 4 + wavePhase)
            local level = math.floor((v + 1) / 2 * (#LEVEL_CHARS - 1) + 0.5)
            chars[i] = LEVEL_CHARS[level + 1]
            fg[i] = colors.toBlit(LEVEL_COLORS[level + 1])
        end
        mon.setCursorPos(startX, y)
        mon.blit(table.concat(chars), table.concat(fg), bgBlitBlack:rep(width))
    end

    local function drawStarfield(y, width)
        local startX = math.floor((w - width) / 2) + 1
        if state.playing and not state.paused and math.random() < 0.6 then
            local i = math.random(1, width)
            stars[i] = { char = ("."):rep(1), color = LEVEL_COLORS[math.random(1, #LEVEL_COLORS)] }
        end
        local chars, fg = {}, {}
        for i = 1, width do
            local s = stars[i]
            chars[i] = s and (({ ".", "*", "+" })[math.random(1, 3)]) or " "
            fg[i] = colors.toBlit(s and s.color or colors.black)
            if s and math.random() < 0.15 then stars[i] = nil end
        end
        mon.setCursorPos(startX, y)
        mon.blit(table.concat(chars), table.concat(fg), bgBlitBlack:rep(width))
    end

    local function drawVisualizer(y, width)
        local kind = VIZ_PATTERNS[state.vizPattern]
        if kind == "bars" then drawBars(y, width)
        elseif kind == "wave" then drawWave(y, width)
        else drawStarfield(y, width) end
    end

    local function centeredWrite(y, text, color, bg)
        local line = text:sub(1, w)
        local x = math.max(1, math.floor((w - #line) / 2) + 1)
        mon.setCursorPos(1, y)
        mon.setBackgroundColor(bg or colors.black)
        mon.clearLine()
        mon.setCursorPos(x, y)
        if color then mon.setTextColor(color) end
        mon.write(line)
    end

    local function hrule(y)
        mon.setCursorPos(1, y)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.gray)
        mon.write(("-"):rep(w))
    end

    local function drawNowPlaying()
        mon.setBackgroundColor(colors.black)
        mon.clear()

        mon.setCursorPos(1, 1)
        mon.setTextColor(colors.yellow)
        mon.setBackgroundColor(colors.gray)
        mon.clearLine()
        mon.write((" NOW PLAYING "):sub(1, w))
        mon.setBackgroundColor(colors.black)
        hrule(2)

        local titleY = 4
        local vizY = titleY + 3
        local statusY = vizY + 3
        local dividerY = statusY + 2
        local volumeY = dividerY + 2

        centeredWrite(titleY, state.nowPlaying or "...", colors.white, colors.black)

        local vizWidth = math.min(40, w - 10)
        local startX = math.floor((w - vizWidth) / 2)
        mon.setCursorPos(startX, vizY)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.gray)
        mon.write("[")
        mon.setCursorPos(startX + vizWidth + 1, vizY)
        mon.write("]")
        drawVisualizer(vizY, vizWidth)

        local status = state.paused and "|| PAUSED" or "> PLAYING"
        local elapsed = formatTime(state.elapsedBytes / 6000)
        centeredWrite(statusY, status .. "    " .. elapsed .. ("   [%s]"):format(VIZ_PATTERNS[state.vizPattern]),
            state.paused and colors.orange or colors.lime)

        hrule(dividerY)

        local segments = math.max(4, math.min(30, w - 20))
        local filled = math.max(0, math.min(segments, math.floor((state.volume / config.MAX_VOLUME) * segments + 0.5)))
        local bar = ("#"):rep(filled) .. ("-"):rep(segments - filled)
        local pct = math.floor((state.volume / config.MAX_VOLUME) * 100 + 0.5)
        centeredWrite(volumeY, ("Vol [%s] %3d%%"):format(bar, pct), colors.cyan)

        mon.setBackgroundColor(colors.gray)
        mon.setTextColor(colors.lightGray)
        mon.setCursorPos(1, h)
        mon.clearLine()
        mon.write((" Space: pause  Left/Right: volume  V: visual  S: stop "):sub(1, w))
        mon.setBackgroundColor(colors.black)
    end

    local function streamAndPlay(song)
        state.nowPlaying = song.name
        state.paused = false
        state.stopRequested = false
        state.elapsedBytes = 0
        drawNowPlaying()

        local response, err = http.get(song.url, nil, true)
        if not response then
            state.nowPlaying = "ERROR: " .. tostring(err)
            drawNowPlaying()
            os.sleep(1.5)
            return
        end

        local decoder = dfpwm.make_decoder()
        local chunkSize = 16 * 1024

        while not state.stopRequested do
            while state.paused and not state.stopRequested do
                os.pullEvent("music_control")
            end
            if state.stopRequested then break end

            local chunk = response.read(chunkSize)
            if not chunk then break end
            state.elapsedBytes = state.elapsedBytes + #chunk

            local buffer = decoder(chunk)
            for _, speaker in ipairs(speakers) do
                while not state.stopRequested and not speaker.playAudio(buffer, state.volume) do
                    os.pullEvent("speaker_audio_empty")
                end
                if state.stopRequested then break end
            end
        end

        response.close()
        for _, speaker in ipairs(speakers) do pcall(speaker.stop) end
        state.nowPlaying = nil
        state.playing = false
    end

    -- Returns "menu" if the user asked to go back to the main menu, or
    -- "idle" if the idle timeout fired while sitting on the library screen.
    local exitReason = nil
    drawLibrary()

    local IDLE_TIMEOUT = config.MUSIC_MENU_IDLE_TIMEOUT_SEC or 150
    local idleTimer = os.startTimer(IDLE_TIMEOUT)

    while not exitReason do
        local event, a, b = os.pullEvent()

        if event == "timer" and a == idleTimer and not state.playing then
            exitReason = "idle"
        elseif not state.playing then
            if event == "key" then
                idleTimer = os.startTimer(IDLE_TIMEOUT)
                local key = a
                if key == keys.up then
                    state.selected = math.max(1, state.selected - 1)
                elseif key == keys.down then
                    local list = filteredSongs()
                    state.selected = math.min(#list, state.selected + 1)
                elseif key == keys.pageUp then
                    state.selected = math.max(1, state.selected - listHeight())
                elseif key == keys.pageDown then
                    local list = filteredSongs()
                    state.selected = math.min(#list, state.selected + listHeight())
                elseif key == keys.tab then
                    exitReason = "menu"
                elseif key == keys.enter then
                    local list = filteredSongs()
                    local song = list[state.selected]
                    if song then
                        state.playing = true
                        drawNowPlaying()
                        parallel.waitForAny(
                            function() streamAndPlay(song) end,
                            function()
                                while state.playing do
                                    local e, k = os.pullEvent("key")
                                    if k == keys.space then
                                        state.paused = not state.paused
                                        os.queueEvent("music_control")
                                        drawNowPlaying()
                                    elseif k == keys.s then
                                        state.stopRequested = true
                                        os.queueEvent("music_control")
                                    elseif k == keys.v then
                                        state.vizPattern = (state.vizPattern % #VIZ_PATTERNS) + 1
                                        drawNowPlaying()
                                    elseif k == keys.left then
                                        state.volume = math.max(0, math.floor((state.volume - 0.1) * 10 + 0.5) / 10)
                                        drawNowPlaying()
                                    elseif k == keys.right then
                                        state.volume = math.min(config.MAX_VOLUME, math.floor((state.volume + 0.1) * 10 + 0.5) / 10)
                                        drawNowPlaying()
                                    end
                                end
                            end,
                            function()
                                while state.playing do
                                    drawNowPlaying()
                                    os.sleep(0.2)
                                end
                            end
                        )
                        state.playing = false
                        idleTimer = os.startTimer(IDLE_TIMEOUT)
                        drawLibrary()
                    end
                elseif key == keys.backspace then
                    if #state.filter > 0 then
                        state.filter = state.filter:sub(1, -2)
                        state.selected = 1
                    end
                elseif key == keys.f5 then
                    fetchSongs()
                    state.selected = 1
                end
                if not exitReason then drawLibrary() end
            elseif event == "char" then
                idleTimer = os.startTimer(IDLE_TIMEOUT)
                state.filter = state.filter .. a
                state.selected = 1
                drawLibrary()
            end
        end
    end

    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.clear()
    return exitReason
end

return M
