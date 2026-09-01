-- music.lua
-- Local GitHub-hosted DFPWM streaming jukebox for ComputerCraft/CC:Tweaked.
-- Streams .dfpwm files straight from raw.githubusercontent.com and plays them
-- through attached speaker peripherals, without ever writing to disk.

local dfpwm = require("cc.audio.dfpwm")

-- ==== CONFIG ====
-- Your GitHub username, plus one entry per library repo. cli.js writes
-- songs.json into whichever repo it's currently pointed at; every repo
-- listed here gets fetched and merged into one combined library in-game.
-- To add a repo: create it on GitHub (public), then add one line below.
local GITHUB_USER = "Aladincykas"
local LIBRARIES = {
    { label = "Library 1", repo = "cctwmusics", branch = "main" },
    { label = "Library 2", repo = "cctwmusics2", branch = "main" },
    { label = "Library 3", repo = "cctwmusics3", branch = "main" },
}

local MANIFEST_URLS = {}
for _, lib in ipairs(LIBRARIES) do
    table.insert(MANIFEST_URLS, ("https://raw.githubusercontent.com/%s/%s/%s/songs.json")
        :format(GITHUB_USER, lib.repo, lib.branch))
end

-- ==== Load song list (fetched live from GitHub each time / on refresh) ====
local songs = {}
local loadError = nil

local function fetchSongs()
    loadError = nil
    songs = {}
    local errors = {}

    for _, manifestUrl in ipairs(MANIFEST_URLS) do
        -- raw.githubusercontent.com sits behind a CDN that can serve a cached
        -- copy for a few minutes after a file changes. Appending a changing
        -- query string forces a fresh fetch instead of a stale cached one.
        local cacheBustUrl = manifestUrl .. "?t=" .. tostring(os.epoch("utc"))
        local response, err, failingResponse = http.get(cacheBustUrl)
        if not response then
            -- A 404 here just means that repo doesn't have a songs.json yet
            -- (nothing uploaded to it via cli.js so far) -- that's a normal,
            -- expected "empty library" state, not a real error worth
            -- alarming about.
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
                for _, song in ipairs(parsed) do
                    table.insert(songs, song)
                end
            end
        end
    end

    if #errors > 0 then
        loadError = table.concat(errors, "; ")
    end
end

-- The on-screen status bar is one line, so a long load error gets truncated
-- and unreadable. Save the full text to a file every time, so it can always
-- be read in full (open it with `edit musicplayer_lasterror.txt`, or press
-- E on the library screen).
local ERROR_LOG_PATH = "musicplayer_lasterror.txt"

local function saveErrorLog(text)
    local f = fs.open(ERROR_LOG_PATH, "w")
    if not f then return end
    f.write(text)
    f.close()
end

fetchSongs()
if loadError then
    saveErrorLog(loadError)
end
if #songs == 0 and loadError then
    error(loadError .. "\nCheck MANIFEST_URLS at the top of music.lua, and if this is a" ..
        "\nPocket Computer, make sure a wireless modem is equipped if this keeps failing.")
end

-- ==== Find speakers ====
-- Regular Computers need a Speaker block placed adjacent (or reached via a
-- wired/wireless modem). Recent CC:Tweaked versions give Pocket Computers a
-- built-in speaker automatically, so this should just work there too.
local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
    error("No speaker found. If this is a regular Computer, place a Speaker block" ..
        "\nnext to it. If this is a Pocket Computer, your CC:Tweaked version may" ..
        "\nbe too old for the built-in speaker feature.")
end

local function stopSpeakers()
    for _, speaker in ipairs(speakers) do
        pcall(speaker.stop)
    end
end

-- ==== Settings (persisted locally on this computer) ====
local SETTINGS_PATH = "musicplayer_settings.json"
local MAX_VOLUME = 2.0

local function loadSettings()
    if not fs.exists(SETTINGS_PATH) then return end
    local f = fs.open(SETTINGS_PATH, "r")
    if not f then return end
    local content = f.readAll()
    f.close()
    local ok, parsed = pcall(textutils.unserialiseJSON, content)
    if ok and type(parsed) == "table" and type(parsed.volume) == "number" then
        return parsed.volume
    end
end

local function saveSettings(volume)
    local f = fs.open(SETTINGS_PATH, "w")
    if not f then return end
    f.write(textutils.serialiseJSON({ volume = volume }))
    f.close()
end

-- ==== State ====
local state = {
    screen = "library", -- "library" | "nowplaying"
    filter = "",
    selected = 1,
    scrollOffset = 0,
    playing = false,
    paused = false,
    stopRequested = false,
    nowPlaying = nil,
    elapsedBytes = 0,
    volume = loadSettings() or 1.0, -- defaults to 1.0 if no saved settings yet
}

local w, h = term.getSize()

local function listHeight()
    local listTop = 4
    local lh = h - listTop - 2
    return lh < 1 and 1 or lh
end

local function filteredSongs()
    if state.filter == "" then return songs end
    local out = {}
    local f = state.filter:lower()
    for _, s in ipairs(songs) do
        if s.name:lower():find(f, 1, true) then
            table.insert(out, s)
        end
    end
    return out
end

-- Rough elapsed-time estimate: DFPWM is 1 bit/sample, encoded from 48000Hz
-- mono 8-bit PCM, so seconds = bytesRead * 8 / 48000 = bytesRead / 6000.
local function formatTime(seconds)
    seconds = math.floor(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return ("%d:%02d"):format(m, s)
end

-- ==== Screen: Library ====
local function drawLibrary()
    term.setBackgroundColor(colors.black)
    term.clear()

    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    write((" MUSIC LIBRARY "):sub(1, w))

    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.clearLine()
    write("Search: ")
    term.setTextColor(colors.white)
    write(state.filter)
    term.setCursorBlink(true)

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
        if state.scrollOffset > maxOffset then state.scrollOffset = maxOffset end
        if state.scrollOffset < 0 then state.scrollOffset = 0 end
    end

    -- Each row is built as one string and drawn with a single term.blit call
    -- (instead of clearLine + several setColor/write calls per row) -- this
    -- is what was causing the visible typing/redraw delay.
    for i = 1, lh do
        local idx = state.scrollOffset + i
        local song = list[idx]
        local selectedRow = song and idx == state.selected

        local text = song and ((" " .. song.name):sub(1, w)) or ""
        if #text < w then text = text .. (" "):rep(w - #text) end

        local fgChar = colors.toBlit(colors.white)
        local bgChar
        if selectedRow then
            bgChar = colors.toBlit(colors.lightBlue)
        elseif song then
            -- faint alternating stripe so rows are easy to track by eye
            bgChar = colors.toBlit((idx % 2 == 0) and colors.black or colors.gray)
        else
            bgChar = colors.toBlit(colors.black)
        end

        term.setCursorPos(1, listTop + i - 1)
        term.blit(text, fgChar:rep(w), bgChar:rep(w))
    end
    term.setBackgroundColor(colors.black)

    if #list > lh then
        local totalPages = math.max(1, math.ceil(#list / lh))
        local currentPage = math.floor(state.scrollOffset / lh) + 1
        local pageLabel = ("[%d/%d]"):format(currentPage, totalPages)
        term.setCursorPos(math.max(1, w - #pageLabel), 2)
        term.setTextColor(colors.gray)
        write(pageLabel)
    end

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, h - 1)
    term.clearLine()
    if loadError then
        write((" Load error (press E for full details) "):sub(1, w))
    elseif #list == 0 then
        write(" No songs found ")
    else
        write((" %d song(s) in library "):format(#list):sub(1, w))
    end

    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.lightGray)
    term.clearLine()
    local hint
    if loadError then
        hint = w >= 55
            and " Up/Down: select  Enter: play  F5: refresh  E: error "
            or " Up/Dn Enter:play F5:refr E:err "
    else
        hint = w >= 55
            and " Up/Down: select  PgUp/PgDn: page  Enter: play  F5: refresh "
            or " Up/Dn Enter:play F5:refresh "
    end
    write(hint:sub(1, w))

    term.setBackgroundColor(colors.black)
end

-- Breaks text into lines no wider than `width`, breaking on spaces where
-- possible so words don't get chopped mid-way.
local function wrapText(text, width)
    local lines = {}
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        if paragraph == "" then
            table.insert(lines, "")
        else
            local current = ""
            for word in paragraph:gmatch("%S+") do
                if current == "" then
                    current = word
                elseif #current + 1 + #word <= width then
                    current = current .. " " .. word
                else
                    table.insert(lines, current)
                    current = word
                end
                -- A single word longer than the whole line width has to be
                -- hard-split, or it would silently overflow forever.
                while #current > width do
                    table.insert(lines, current:sub(1, width))
                    current = current:sub(width + 1)
                end
            end
            table.insert(lines, current)
        end
    end
    return lines
end

-- Full-screen viewer for the load error, since the status bar can only show
-- a truncated one-liner. Also saved to ERROR_LOG_PATH on disk.
local function drawErrorScreen()
    term.setBackgroundColor(colors.black)
    term.clear()

    term.setCursorPos(1, 1)
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.red)
    term.clearLine()
    write((" LOAD ERROR "):sub(1, w))
    term.setBackgroundColor(colors.black)

    local lines = wrapText(loadError or "(no error)", w)
    local maxLines = h - 3
    for i = 1, math.min(#lines, maxLines) do
        term.setCursorPos(1, i + 1)
        term.setTextColor(colors.white)
        write(lines[i])
    end
    if #lines > maxLines then
        term.setCursorPos(1, h - 1)
        term.setTextColor(colors.gray)
        write(("...and %d more line(s), see %s"):format(#lines - maxLines, ERROR_LOG_PATH):sub(1, w))
    end

    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.lightGray)
    term.clearLine()
    write((" Full text saved to " .. ERROR_LOG_PATH .. " - press any key "):sub(1, w))
    term.setBackgroundColor(colors.black)
end

-- Purely decorative animated "equalizer" — not real audio analysis, just a
-- flickering bar pattern to make the Now Playing screen feel alive.
-- Built as one string + one color-gradient string and drawn with a single
-- term.blit call, instead of setCursorPos/setColor/write per character.
local LEVEL_CHARS = { " ", ".", ":", "-", "=", "+", "*", "#" }
local LEVEL_COLORS = {
    colors.gray, colors.cyan, colors.lightBlue, colors.lime,
    colors.lime, colors.yellow, colors.orange, colors.red,
}
local bgBlitBlack = colors.toBlit(colors.black)

-- mirrorY optionally draws a second, dimmer "reflection" row below the main
-- bars using the same heights, for a fuller equalizer look on taller screens.
local function drawVisualizer(y, width, mirrorY)
    local barsCount = math.max(1, width)
    local startX = math.floor((w - barsCount) / 2) + 1
    local maxLevel = #LEVEL_CHARS - 1

    local heights = {}
    local chars, fg = {}, {}
    for i = 1, barsCount do
        local heightLevel = (state.playing and not state.paused) and math.random(0, maxLevel) or 0
        heights[i] = heightLevel
        chars[i] = LEVEL_CHARS[heightLevel + 1]
        fg[i] = colors.toBlit(LEVEL_COLORS[heightLevel + 1])
    end

    term.setCursorPos(startX, y)
    term.blit(table.concat(chars), table.concat(fg), bgBlitBlack:rep(barsCount))

    if mirrorY then
        local mchars, mfg = {}, {}
        local grayBlit = colors.toBlit(colors.gray)
        for i = 1, barsCount do
            local reflected = math.max(0, heights[i] - 3) -- reflection fades out quicker
            mchars[i] = LEVEL_CHARS[reflected + 1]
            mfg[i] = grayBlit
        end
        term.setCursorPos(startX, mirrorY)
        term.blit(table.concat(mchars), table.concat(mfg), bgBlitBlack:rep(barsCount))
    end
end

local function centeredWrite(y, text, color, bg)
    local line = text:sub(1, w)
    local x = math.max(1, math.floor((w - #line) / 2) + 1)
    term.setCursorPos(1, y)
    term.setBackgroundColor(bg or colors.black)
    term.clearLine()
    term.setCursorPos(x, y)
    if color then term.setTextColor(color) end
    write(line)
end

local function hrule(y)
    term.setCursorPos(1, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    write(("-"):rep(w))
end

-- ==== Screen: Now Playing ====
local function drawNowPlaying()
    term.setBackgroundColor(colors.black)
    term.clear()

    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    write((" NOW PLAYING "):sub(1, w))
    term.setBackgroundColor(colors.black)
    hrule(2)

    local compact = h < 14
    local titleY = 4
    local vizY = titleY + 2
    local useMirror = not compact and h >= 18
    local statusY = compact and (titleY + 2) or (vizY + (useMirror and 3 or 2))
    local dividerY = statusY + 2
    local volumeY = math.max(dividerY + 1, h - 3)
    volumeY = math.max(dividerY + 1, math.min(volumeY, h - 1)) -- never collide with the footer row

    -- Song title, larger visual weight via its own highlighted row.
    centeredWrite(titleY, state.nowPlaying or "...", colors.white, colors.black)

    if not compact and w >= 20 then
        local vizWidth = math.min(24, w - 6)
        local bracketed = w >= vizWidth + 6
        if bracketed then
            local startX = math.floor((w - vizWidth) / 2)
            local bracketRows = useMirror and { vizY, vizY + 1 } or { vizY }
            for _, by in ipairs(bracketRows) do
                term.setCursorPos(startX, by)
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.gray)
                write("[")
                term.setCursorPos(startX + vizWidth + 1, by)
                write("]")
            end
        end
        drawVisualizer(vizY, vizWidth, useMirror and (vizY + 1) or nil)
    end

    local status = state.paused and "|| PAUSED" or "> PLAYING"
    local elapsed = formatTime(state.elapsedBytes / 6000)
    centeredWrite(statusY, status .. "    " .. elapsed, state.paused and colors.orange or colors.lime)

    hrule(dividerY)

    -- Volume bar
    local segments = math.max(4, math.min(20, w - 14))
    local filled = math.max(0, math.min(segments, math.floor((state.volume / MAX_VOLUME) * segments + 0.5)))
    local bar = ("#"):rep(filled) .. ("-"):rep(segments - filled)
    local pct = math.floor((state.volume / MAX_VOLUME) * 100 + 0.5)
    centeredWrite(volumeY, ("Vol [%s] %3d%%"):format(bar, pct), colors.cyan)

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(1, h)
    term.clearLine()
    local hint = w >= 45
        and " Space: pause  Left/Right: volume  S: stop "
        or " Sp:pause </>:vol S:stop "
    write(hint:sub(1, w))

    term.setBackgroundColor(colors.black)
end

-- ==== Streaming playback ====
local function streamAndPlay(song)
    state.nowPlaying = song.name
    state.paused = false
    state.stopRequested = false
    state.elapsedBytes = 0
    drawNowPlaying()

    local response, err = http.get(song.url, nil, true) -- binary mode
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
        if not chunk then
            break -- end of stream
        end
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
    stopSpeakers() -- cut off anything still queued in the speaker's buffer immediately
    state.nowPlaying = nil
    state.playing = false
end

-- ==== Menu loop ====
local function menuLoop()
    drawLibrary()
    while true do
        local event, key = os.pullEvent()

        if state.screen == "error" then
            -- Any key or char press dismisses the error screen; swallow it
            -- here so it can't also leak into the search filter below.
            if event == "key" or event == "char" then
                state.screen = "library"
            end
            drawErrorScreen()
        elseif not state.playing then
            if event == "key" then
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
                elseif key == keys.enter then
                    local list = filteredSongs()
                    local song = list[state.selected]
                    if song then
                        state.playing = true
                        state.screen = "nowplaying"
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
                                    elseif k == keys.left then
                                        -- Writing to disk on every single keypress added a small but
                                        -- noticeable delay; just update in memory and save once below.
                                        state.volume = math.max(0, math.floor((state.volume - 0.1) * 10 + 0.5) / 10)
                                        drawNowPlaying()
                                    elseif k == keys.right then
                                        state.volume = math.min(MAX_VOLUME, math.floor((state.volume + 0.1) * 10 + 0.5) / 10)
                                        drawNowPlaying()
                                    end
                                end
                            end,
                            function()
                                while state.playing do
                                    drawNowPlaying()
                                    os.sleep(0.5)
                                end
                            end
                        )
                        state.playing = false
                        state.screen = "library"
                        saveSettings(state.volume)
                        drawLibrary()
                    end
                elseif key == keys.backspace then
                    if #state.filter > 0 then
                        state.filter = state.filter:sub(1, -2)
                        state.selected = 1
                    end
                elseif key == keys.f5 then
                    fetchSongs()
                    if loadError then saveErrorLog(loadError) end
                    state.selected = 1
                elseif key == keys.e and loadError then
                    state.screen = "error"
                end
            elseif event == "char" then
                state.filter = state.filter .. key
                state.selected = 1
            end
            drawLibrary()
        end
    end
end

term.setCursorBlink(false)
local okRun, errRun = pcall(menuLoop)
stopSpeakers()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not okRun then
    print("Music player stopped: " .. tostring(errRun))
end
