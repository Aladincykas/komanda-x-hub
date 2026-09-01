-- hub.lua -- entry point for the Komanda X media hub.
-- State machine: mainmenu -> {videomenu <-> videoplayer, musicplayer}.
--
-- Main menu and the video-selection list are built with Basalt 2.5
-- (require("basalt"), installed alongside this file -- see install.lua).
-- The matrix background and main-menu music run as basalt.schedule()
-- background coroutines while basalt.run() drives the menu; a button's
-- onClick calls basalt.stop() to hand control back to this state machine,
-- which is exactly the run()/stop() contract Basalt's own docs describe.
-- musicplayer.lua is NOT ported to Basalt -- it's a near-verbatim port of
-- your already-working music.lua, and rebuilding a proven screen on a new
-- framework for its own sake isn't worth the risk, so it keeps its own
-- raw term.blit + key-driven UI.

local config = require("config")
local Matrix = require("matrix")
local videoplayer = require("videoplayer")
local musicplayer = require("musicplayer")
local basalt = require("basalt")

local mon = peripheral.wrap(config.MONITOR_NAME)
if not mon then error("Monitor '" .. config.MONITOR_NAME .. "' not found. Check config.lua.") end
mon.setTextScale(config.MONITOR_TEXT_SCALE)
local w, h = mon.getSize()

local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
    error("No speakers found on the network. Check they're connected via modem.")
end

mon.setTextColor(colors.white)
mon.setBackgroundColor(colors.black)

-- ==== Shared: fetch + merge a manifest across a list of repos ====
local function fetchMergedManifest(urls, manifestFile)
    local items = {}
    for _, url in ipairs(urls) do
        local full = ("%s/%s?t=%s"):format(url, manifestFile, tostring(os.epoch("utc")))
        local response = http.get(full)
        if response then
            local body = response.readAll()
            response.close()
            local parsed = textutils.unserialiseJSON(body)
            if type(parsed) == "table" then
                for _, item in ipairs(parsed) do table.insert(items, item) end
            end
        end
    end
    return items
end

local function musicManifestUrls()
    local urls = {}
    for _, lib in ipairs(config.MUSIC_LIBRARIES) do
        table.insert(urls, ("https://raw.githubusercontent.com/%s/%s/%s"):format(config.GITHUB_USER, lib.repo, lib.branch))
    end
    return urls
end

local function videoManifestUrls()
    local urls = {}
    for _, lib in ipairs(config.VIDEO_LIBRARIES) do
        table.insert(urls, ("https://raw.githubusercontent.com/%s/%s/%s"):format(config.GITHUB_USER, lib.repo, lib.branch))
    end
    return urls
end

-- ==== Main menu ====
local function runMainMenu()
    local matrix = Matrix.new(mon)
    local chosen = nil

    local frame = basalt.createFrame():setTerm(mon)
    frame:setBackground(colors.black)

    local titleY = math.max(2, math.floor(h * 0.28))
    local title = config.TITLE:upper()
    local spaced = title:gsub(".", "%1 "):sub(1, -2) -- letter-spaced for a "big" look on a 1-row font
    local tx = math.max(1, math.floor((w - #spaced) / 2) + 1)

    frame:addLabel()
        :setText(spaced)
        :setPosition(tx, titleY)
        :setForeground(colors.yellow)
        :setBackground(colors.black)

    local buttonW = math.min(w - 4, 24)
    local bx = math.floor((w - buttonW) / 2) + 1
    local menuTop = titleY + 3

    frame:addButton()
        :setText("VIDEO PLAYER")
        :setPosition(bx, menuTop)
        :setSize(buttonW, 1)
        :setBackground(colors.gray)
        :setForeground(colors.white)
        :onClick(function()
            chosen = "video"
            basalt.stop()
        end)

    frame:addButton()
        :setText("MUSIC PLAYER")
        :setPosition(bx, menuTop + 2)
        :setSize(buttonW, 1)
        :setBackground(colors.gray)
        :setForeground(colors.white)
        :onClick(function()
            chosen = "music"
            basalt.stop()
        end)

    -- Basalt only repaints a widget's own cells when one of its properties
    -- changes -- it does not continuously redraw the whole frame. So the
    -- matrix rain must never write into a cell a widget owns, or it
    -- permanently erases it the first time it passes through (confirmed
    -- in-game). Every widget's rectangle above must be listed here.
    matrix:setExclusions({
        { tx, titleY, tx + #spaced - 1, titleY },
        { bx, menuTop, bx + buttonW - 1, menuTop },
        { bx, menuTop + 2, bx + buttonW - 1, menuTop + 2 },
    })

    -- Background matrix rain, redrawn continuously behind the frame's
    -- widgets while Basalt's own event loop is running.
    basalt.schedule(function()
        while not chosen do
            matrix:step(0.2)
            sleep(0.2)
        end
    end)

    -- Main menu music: looks up the configured track name in the merged
    -- music library and loops it at MENU_MUSIC_VOLUME until a selection is
    -- made. Silently does nothing if no track is configured yet.
    basalt.schedule(function()
        if not config.MENU_MUSIC_NAME then return end
        local dfpwm = require("cc.audio.dfpwm")
        while not chosen do
            local songs = fetchMergedManifest(musicManifestUrls(), "songs.json")
            local track = nil
            for _, s in ipairs(songs) do
                if s.name == config.MENU_MUSIC_NAME then track = s break end
            end
            if not track then
                sleep(5)
            else
                local response = http.get(track.url, nil, true)
                if response then
                    local decoder = dfpwm.make_decoder()
                    while not chosen do
                        local chunk = response.read(16 * 1024)
                        if not chunk then break end
                        local buffer = decoder(chunk)
                        for _, speaker in ipairs(speakers) do
                            while not chosen and not speaker.playAudio(buffer, config.MENU_MUSIC_VOLUME) do
                                os.pullEvent("speaker_audio_empty")
                            end
                        end
                    end
                    response.close()
                end
            end
        end
    end)

    basalt.run()

    for _, speaker in ipairs(speakers) do pcall(speaker.stop) end
    return chosen or "video"
end

-- ==== Video selection menu ====
local function runVideoMenu()
    local exitReason = nil

    while not exitReason do
        local videos = fetchMergedManifest(videoManifestUrls(), "videos.json")
        local selectedVideo = nil

        local frame = basalt.createFrame():setTerm(mon)
        frame:setBackground(colors.black)

        frame:addLabel()
            :setText("SELECT A VIDEO")
            :setPosition(2, 1)
            :setForeground(colors.yellow)
            :setBackground(colors.black)

        if #videos == 0 then
            frame:addLabel()
                :setText("No videos yet. Upload with addmedia (Video mode).")
                :setPosition(2, 3)
                :setForeground(colors.lightGray)
                :setBackground(colors.black)
        else
            local list = frame:addList()
                :setPosition(2, 3)
                :setSize(w - 2, h - 5)
                :setBackground(colors.black)
                :setForeground(colors.white)
            for _, v in ipairs(videos) do list:addItem(v.name) end
            list:onSelect(function(_, index)
                selectedVideo = videos[index]
                basalt.stop()
            end)
        end

        frame:addButton()
            :setText("Back to Menu")
            :setPosition(2, h)
            :setSize(math.min(w - 2, 16), 1)
            :setBackground(colors.gray)
            :setForeground(colors.white)
            :onClick(function()
                exitReason = "menu"
                basalt.stop()
            end)

        -- Idle timeout: any key or touch resets the clock; a background
        -- coroutine stops the UI once it's been quiet too long.
        local lastActivity = os.epoch("utc")
        local function touch() lastActivity = os.epoch("utc") end
        basalt.onEvent("monitor_touch", touch)
        basalt.onEvent("key", touch)

        basalt.schedule(function()
            local timeoutMs = (config.VIDEO_MENU_IDLE_TIMEOUT_SEC or 150) * 1000
            while true do
                sleep(5)
                if os.epoch("utc") - lastActivity > timeoutMs then
                    exitReason = exitReason or "idle"
                    basalt.stop()
                    return
                end
            end
        end)

        basalt.run()
        basalt.removeEvent("monitor_touch", touch)
        basalt.removeEvent("key", touch)

        if selectedVideo then
            videoplayer.play(mon, speakers, selectedVideo, config)
            -- loop back around: rebuild the list fresh after playback
        end
    end

    return exitReason
end

-- ==== Top-level state machine ====
while true do
    local target = runMainMenu()
    if target == "video" then
        runVideoMenu() -- returns on "menu" (Back button) or "idle" -> main menu
    else
        musicplayer.run(mon, speakers, config) -- returns on "menu" or "idle" -> main menu
    end
end
