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
--
-- videoplayer.lua and musicplayer.lua are required lazily, right where
-- each is first used (inside runVideoMenu / the music branch below), not
-- up front here -- so picking "Music" never even loads the video/32vid
-- decoder code, and vice versa. Lua caches a module after its first
-- require() either way, so entering that screen twice doesn't reload it.

local config = require("config")
local Matrix = require("matrix")
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

    -- MUST pass mon directly to createFrame (not createFrame():setTerm(mon))
    -- -- createFrame(t) resolves peripheral.getName(t) into the frame's
    -- internal "monitor" field, which is what routes monitor_touch events
    -- to this frame at all. setTerm() alone never sets that field, so
    -- clicks silently do nothing (confirmed by reading basalt.lua directly
    -- after in-game testing showed clicks never registering).
    local frame = basalt.createFrame(mon)
    frame:setBackground(colors.black)

    local title = config.TITLE:upper()
    local spaced = title:gsub(".", "%1 "):sub(1, -2) -- letter-spaced for a "big" look on a 1-row font
    local buttonW = math.min(w - 4, 24)

    -- Whole menu (title + gap + 2 buttons) centered as one block, rather
    -- than an arbitrary "28% down" title with buttons hanging off it.
    local BLOCK_HEIGHT = 6 -- title(1) + gap(2) + button(1) + gap(1) + button(1)
    local blockTop = math.max(2, math.floor((h - BLOCK_HEIGHT) / 2) + 1)
    local titleY = blockTop
    local menuTop = titleY + 3

    local tx = math.max(1, math.floor((w - #spaced) / 2) + 1)
    local bx = math.floor((w - buttonW) / 2) + 1

    frame:addLabel()
        :setText(spaced)
        :setPosition(tx, titleY)
        :setForeground(colors.yellow)
        :setBackground(colors.black)

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

    -- Force the very first real render now, before the matrix starts
    -- ticking below -- basalt.schedule() runs its function immediately
    -- (up to its first yield), so without this the matrix's first step
    -- could run before Basalt has ever actually flushed the title/buttons
    -- to the monitor.
    frame:draw()

    -- Basalt only repaints a widget's own cells when one of its properties
    -- changes -- it does not continuously redraw the whole frame. So the
    -- matrix rain must never write into a cell a widget owns, or it
    -- permanently erases it the first time it passes through (confirmed
    -- in-game). A 1-cell padding margin keeps the rain from crowding right
    -- up against the text too. Every widget's rectangle above must be
    -- listed here.
    local PAD = 1
    matrix:setExclusions({
        { tx - PAD, titleY, tx + #spaced - 1 + PAD, titleY },
        { bx - PAD, menuTop - PAD, bx + buttonW - 1 + PAD, menuTop + PAD },
        { bx - PAD, menuTop + 2 - PAD, bx + buttonW - 1 + PAD, menuTop + 2 + PAD },
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

-- basalt.createFrame() appends to a module-level list with no matching
-- "destroy the frame" call anywhere in this codebase, and its click router
-- (basalt.lua ~118-125) dispatches monitor_touch to EVERY frame whose
-- .monitor field matches, with no break -- so calling createFrame() again
-- on every loop pass (once per video watched) would leak one frame per
-- video, each one still receiving future clicks forever. This clears a
-- frame's own children (same pattern Container:destroy() uses internally,
-- minus destroying the frame itself) so one frame can be reused instead.
local function clearFrameChildren(frame)
    local children = rawget(frame, "_children")
    while children and #children > 0 do
        local child = children[#children]
        if child.destroy then child:destroy() end
        if children[#children] == child then frame:removeChild(child) end
    end
end

-- ==== Video selection menu ====
local function runVideoMenu()
    local videoplayer = require("videoplayer") -- loaded on first entry to this screen only
    local exitReason = nil
    local frame = basalt.createFrame(mon) -- see the note in runMainMenu above; created ONCE and reused
    frame:setBackground(colors.black)

    while not exitReason do
        clearFrameChildren(frame)
        local videos = fetchMergedManifest(videoManifestUrls(), "videos.json")
        local selectedVideo = nil

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

        frame:draw() -- force the first real render before any schedule()d coroutine runs

        -- Idle timeout: plain os.pullEvent polling, not a Basalt event hook
        -- -- basalt.onEvent/removeEvent turned out not to exist in the
        -- installed (minified) build despite being in the docs (confirmed
        -- in-game: "attempt to call field 'onEvent' (a nil value)"). CC
        -- broadcasts every event to all coroutines waiting on pullEvent,
        -- Basalt's own included, so this runs alongside it safely.
        basalt.schedule(function()
            local lastActivity = os.epoch("utc")
            local timeoutMs = (config.VIDEO_MENU_IDLE_TIMEOUT_SEC or 150) * 1000
            while true do
                local timerId = os.startTimer(5)
                repeat
                    local event, p1 = os.pullEvent()
                    if event == "monitor_touch" or event == "key" or event == "char" or event == "mouse_click" then
                        lastActivity = os.epoch("utc")
                    end
                until event == "timer" and p1 == timerId
                if os.epoch("utc") - lastActivity > timeoutMs then
                    exitReason = exitReason or "idle"
                    basalt.stop()
                    return
                end
            end
        end)

        basalt.run()

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
        local musicplayer = require("musicplayer") -- loaded on first entry to this screen only
        musicplayer.run(mon, speakers, config) -- returns on "menu" or "idle" -> main menu
    end
end
