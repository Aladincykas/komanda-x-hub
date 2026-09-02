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

-- The whole UI lives on the monitor -- this program never writes anything
-- else to the Computer's OWN terminal, on purpose (that's what a kiosk
-- setup is), which makes the Computer's screen look frozen/dead even while
-- everything is working fine on the monitor. Print a plain static status
-- line here so it's obvious at a glance the program actually started, and
-- as a reminder of the Q-quit hotkey (see the watcher below and the
-- matching handler in videoplayer.lua) without needing to already know it.
term.clear()
term.setCursorPos(1, 1)
print(config.TITLE .. " is running.")
print("Monitor: " .. config.MONITOR_NAME .. " (" .. w .. "x" .. h .. ")")
print("Speakers found: " .. #speakers)
print("")
print("The menu/UI is on the monitor, not here.")
print("Press Q on THIS keyboard any time to quit.")

-- ONE Basalt frame for the whole hub, shared across every screen, instead
-- of each screen creating its own via basalt.createFrame(mon). Two
-- separate frame objects wrapping the SAME physical monitor each keep
-- their own independent "what's already on screen" diff buffer -- Basalt
-- only flushes cells that changed FROM THAT FRAME's OWN point of view, so
-- switching from one frame to another leaves the previous frame's pixels
-- sitting there, since the new frame has no idea they exist and never
-- decided to repaint over them. Confirmed in-game: the music player (which
-- used two separate frames, one for the library list and one for Now
-- Playing) rendered as "a complete mess" that "overwrites to black
-- screen" when switching between those two screens. One shared frame,
-- cleared and rebuilt for whatever screen is active (clearFrameChildren
-- below), avoids this entirely -- exactly the pattern already proven safe
-- for the video list rebuilding itself after every video watched.
local mainFrame = basalt.createFrame(mon)
mainFrame:setBackground(colors.black)

-- Ctrl+T ("terminate") STILL couldn't close the program -- traced this by
-- reading basalt.run() directly: it catches EVERY error internally
-- (including a "Terminated" error from any of our own code) via xpcall,
-- and its own event loop treats "terminate" as a normal signal to just
-- stop *that one* run() call cleanly -- it NEVER re-throws, so run()
-- always returns normally no matter why it stopped. That means nothing in
-- our surrounding while-loops could ever tell "the user hit Ctrl+T" apart
-- from "a button called basalt.stop()", so they just kept looping into
-- the next screen instead of actually exiting.
--
-- Fix: a global flag, set by our OWN watcher coroutine using
-- os.pullEventRaw (which does NOT throw on terminate, unlike plain
-- pullEvent), checked after every basalt.run() call at every level
-- (here, runVideoMenu, and musicplayer.lua's loops) so the exit actually
-- propagates all the way out instead of stopping at whichever screen
-- happened to be open. A real Lua global (not `local`) since this needs
-- to be visible from musicplayer.lua too, a separate module/file. Basalt
-- schedules persist across separate run() calls (the `schedules` table is
-- never cleared between them), so this only needs to be registered once,
-- here, and it keeps working for every screen after this point.
-- Also quits on the Q key -- pressed at the COMPUTER's own terminal, not a
-- touch on the monitor (a "key" event only fires from the Computer's
-- keyboard; monitor taps are a completely separate "monitor_touch" event),
-- so this only works standing at the Computer, on purpose -- registered
-- once here, same as the terminate watcher above/below, so it works from
-- any screen (main menu, video, music) without needing to be re-added
-- anywhere else.
_G.KOMANDA_TERMINATED = false
basalt.schedule(function()
    while true do
        local event, key = os.pullEventRaw()
        if event == "terminate" or (event == "key" and key == keys.q) then
            _G.KOMANDA_TERMINATED = true
            basalt.stop()
            return
        end
    end
end)

-- basalt.schedule() should be used through THIS wrapper everywhere in this
-- codebase, not called directly -- plain sleep() (an os.sleep alias) is
-- itself just os.pullEvent("timer") under the hood, and pullEvent THROWS
-- on a terminate event no matter what filter it's given. Basalt resumes
-- scheduled coroutines in REVERSE registration order, so any coroutine
-- using plain sleep() (the matrix loop, menu music, the visualizer, etc)
-- could throw first and abort that whole resume pass before the watcher
-- above ever got a turn -- i.e. depend on scheduling order to work at
-- all, which isn't good enough. Wrapping every scheduled function's body
-- in its own pcall means each one independently notices its own
-- termination and cooperatively sets the flag + stops, regardless of
-- what order Basalt happens to resume them in.
local function safeSchedule(fn)
    return basalt.schedule(function()
        local ok, err = pcall(fn)
        if not ok then
            if tostring(err):find("Terminated") then
                _G.KOMANDA_TERMINATED = true
            end
            pcall(basalt.stop)
        end
    end)
end

-- basalt.createFrame() appends to a module-level list with no matching
-- "destroy the frame" call anywhere in this codebase, and its click router
-- (basalt.lua ~118-125) dispatches monitor_touch to EVERY frame whose
-- .monitor field matches, with no break -- so this clears a frame's own
-- children (same pattern Container:destroy() uses internally, minus
-- destroying the frame itself) so mainFrame can be reused for every
-- screen instead of leaking a new frame per screen switch.
local function clearFrameChildren(frame)
    local children = rawget(frame, "_children")
    while children and #children > 0 do
        local child = children[#children]
        if child.destroy then child:destroy() end
        if children[#children] == child then frame:removeChild(child) end
    end
end

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
local function runMainMenu(frame)
    local matrix = Matrix.new(mon)
    local chosen = nil

    clearFrameChildren(frame)

    local title = config.TITLE:upper()
    local spaced = title:gsub(".", "%1 "):sub(1, -2) -- letter-spaced for a "big" look on a 1-row font
    local buttonW = math.min(w - 6, 22) -- "slim" -- narrower than before (was up to 24/w-4)

    -- A bordered box drawn with plain addLabel border characters (top/
    -- bottom rule lines, left/right single-char columns), NOT addFrame --
    -- addFrame nesting rendered as a totally blank screen in-game at any
    -- depth (confirmed by testing both a double- and single-nested
    -- version), even though clicks landed fine, so it's a render-only bug
    -- with addFrame specifically in this Basalt build. Plain labels are
    -- the same element type already proven working everywhere else.
    --
    -- The box's dark interior needs no separate fill: `frame` already
    -- paints its own solid black background across the whole monitor on
    -- the forced frame:draw() below, before the matrix ever runs its
    -- first step -- as long as the box's full rectangle (border AND
    -- interior gaps) stays inside the matrix's exclusion zone, that black
    -- fill is never touched again and reads as a solid panel.
    -- Dark theme: black interior, muted gray border/buttons, white text.
    -- Extra +6/9-row sizing (was +4/7) gives the box real breathing room
    -- (a blank row after the top border, before the bottom border, and
    -- around the title) instead of text crammed right against the edges.
    local boxW = math.max(#spaced, buttonW) + 6
    local boxH = 9 -- border, gap, title, gap, button, gap, button, gap, border
    local boxX = math.max(1, math.floor((w - boxW) / 2) + 1)
    local boxY = math.max(1, math.floor((h - boxH) / 2) + 1)

    local BORDER_COLOR = colors.lime -- matches the matrix rain's own accent color
    frame:addLabel()
        :setText(("="):rep(boxW))
        :setPosition(boxX, boxY)
        :setForeground(BORDER_COLOR)
        :setBackground(colors.black)
    frame:addLabel()
        :setText(("="):rep(boxW))
        :setPosition(boxX, boxY + boxH - 1)
        :setForeground(BORDER_COLOR)
        :setBackground(colors.black)
    for row = boxY + 1, boxY + boxH - 2 do
        frame:addLabel():setText("|"):setPosition(boxX, row):setForeground(BORDER_COLOR):setBackground(colors.black)
        frame:addLabel():setText("|"):setPosition(boxX + boxW - 1, row):setForeground(BORDER_COLOR):setBackground(colors.black)
    end

    local titleY = boxY + 2
    local menuTop = titleY + 2
    local tx = boxX + math.max(1, math.floor((boxW - #spaced) / 2))
    local bx = boxX + math.max(1, math.floor((boxW - buttonW) / 2))

    frame:addLabel()
        :setText(spaced)
        :setPosition(tx, titleY)
        :setForeground(colors.lime)
        :setBackground(colors.black)

    frame:addButton()
        :setText("VIDEO PLAYER")
        :setPosition(bx, menuTop)
        :setSize(buttonW, 1)
        :setBackground(colors.gray)
        :setForeground(colors.lime)
        :onClick(function()
            chosen = "video"
            basalt.stop()
        end)

    frame:addButton()
        :setText("MUSIC PLAYER")
        :setPosition(bx, menuTop + 2)
        :setSize(buttonW, 1)
        :setBackground(colors.gray)
        :setForeground(colors.lime)
        :onClick(function()
            chosen = "music"
            basalt.stop()
        end)

    -- Force the very first real render now, before the matrix starts
    -- ticking below -- basalt.schedule() runs its function immediately
    -- (up to its first yield), so without this the matrix's first step
    -- could run before Basalt has ever actually flushed the box to the
    -- monitor.
    frame:draw()

    -- Quitting is a Q keypress at the Computer's own keyboard now, not a
    -- monitor button -- see the Q-key watcher near the top of this file
    -- (main menu/music) and the matching handler in videoplayer.lua's input
    -- loop (video playback, which runs its own raw event loop instead of
    -- going through Basalt).

    -- The whole box (border + interior) needs to be off-limits to the
    -- rain, not just the individual text cells -- see the note above on
    -- why the interior doesn't need its own separate fill.
    matrix:setExclusions({
        { boxX, boxY, boxX + boxW - 1, boxY + boxH - 1 },
    })

    -- Background matrix rain, redrawn continuously behind the frame's
    -- widgets while Basalt's own event loop is running.
    safeSchedule(function()
        while not chosen do
            matrix:step(0.2)
            sleep(0.2)
        end
    end)

    -- Main menu music: looks up the configured track name in the merged
    -- music library and loops it at MENU_MUSIC_VOLUME until a selection is
    -- made. Silently does nothing if no track is configured yet.
    safeSchedule(function()
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
    if _G.KOMANDA_TERMINATED then return "quit" end
    return chosen or "video"
end

-- ==== Video selection menu ====
local function runVideoMenu(frame)
    local videoplayer = require("videoplayer") -- loaded on first entry to this screen only
    local exitReason = nil
    local page = 1

    -- addButton-per-row instead of Basalt's List element -- a video
    -- ("Bad Apple 2") confirmed present in the fetched data (checked
    -- directly against the raw CDN endpoint, not just the GitHub API)
    -- still didn't show up in-game through List. List is a much more
    -- complex element (scroll state, item views, click-vs-drag handling)
    -- than addLabel/addButton, which have been reliable everywhere else
    -- in this codebase, so rather than keep debugging a black box,
    -- switched to the exact pattern already proven working on the music
    -- library screen: real pagination via addButton rows.
    local ROW_STEP = 2
    local contentTop = 3
    local footerRow = h

    while not exitReason and not _G.KOMANDA_TERMINATED do
        local videos = fetchMergedManifest(videoManifestUrls(), "videos.json")
        local selectedVideo = nil
        local perPage = math.max(1, math.floor((footerRow - contentTop) / ROW_STEP))
        local totalPages = math.max(1, math.ceil(#videos / perPage))

        local function drawVideoMenu()
            clearFrameChildren(frame)
            if page > totalPages then page = totalPages end

            frame:addLabel()
                :setText((" SELECT A VIDEO "):sub(1, w))
                :setSize(w, 1)
                :setPosition(1, 1)
                :setForeground(colors.lime)
                :setBackground(colors.gray)

            frame:addLabel()
                :setText(#videos == 0 and "No videos yet." or ("%d video(s) -- page %d/%d"):format(#videos, page, totalPages))
                :setPosition(2, 2)
                :setForeground(colors.lightGray)
                :setBackground(colors.black)

            if #videos == 0 then
                frame:addLabel()
                    :setText("Upload one with addmedia (Video mode).")
                    :setPosition(2, contentTop)
                    :setForeground(colors.lightGray)
                    :setBackground(colors.black)
            else
                local startIdx = (page - 1) * perPage + 1
                for i = 0, perPage - 1 do
                    local idx = startIdx + i
                    local video = videos[idx]
                    if video then
                        frame:addButton()
                            :setText(video.name:sub(1, w - 4))
                            :setPosition(2, contentTop + i * ROW_STEP)
                            :setSize(w - 2, 1)
                            :setBackground(colors.gray)
                            :setForeground(colors.lime)
                            :onClick(function()
                                selectedVideo = video
                                basalt.stop()
                            end)
                    end
                end
            end

            local navW = math.min(math.floor((w - 8) / 3), 14)
            frame:addButton()
                :setText("< Prev")
                :setPosition(2, footerRow)
                :setSize(navW, 1)
                :setBackground(colors.gray)
                :setForeground(colors.lime)
                :onClick(function()
                    if page > 1 then page = page - 1 end
                    drawVideoMenu()
                end)

            frame:addButton()
                :setText("Next >")
                :setPosition(4 + navW, footerRow)
                :setSize(navW, 1)
                :setBackground(colors.gray)
                :setForeground(colors.lime)
                :onClick(function()
                    if page < totalPages then page = page + 1 end
                    drawVideoMenu()
                end)

            frame:addButton()
                :setText("Back to Menu")
                :setPosition(w - math.min(w - 2, 16) + 1, footerRow)
                :setSize(math.min(w - 2, 16), 1)
                :setBackground(colors.red)
                :setForeground(colors.white)
                :onClick(function()
                    exitReason = "menu"
                    basalt.stop()
                end)
        end

        drawVideoMenu()
        frame:draw() -- force the first real render before any schedule()d coroutine runs

        -- Idle timeout: event polling, not a Basalt event hook -- basalt.
        -- onEvent/removeEvent turned out not to exist in the installed
        -- (minified) build despite being in the docs (confirmed in-game:
        -- "attempt to call field 'onEvent' (a nil value)"). CC broadcasts
        -- every event to all coroutines waiting on pullEvent, Basalt's own
        -- included, so this runs alongside it safely.
        --
        -- Uses pullEventRaw, NOT plain pullEvent -- plain pullEvent THROWS
        -- on a terminate event regardless of any filter, and Basalt
        -- resumes scheduled coroutines in REVERSE order, so this one (added
        -- after the terminate watcher near the top of this file) would get
        -- resumed FIRST and its error would abort that whole resume pass
        -- before the watcher ever got a turn -- i.e. Ctrl+T could get
        -- silently eaten depending on scheduling order. Checking for
        -- "terminate" explicitly here too means this doesn't depend on
        -- that ordering at all.
        safeSchedule(function()
            local lastActivity = os.epoch("utc")
            local timeoutMs = (config.VIDEO_MENU_IDLE_TIMEOUT_SEC or 150) * 1000
            while true do
                local timerId = os.startTimer(5)
                repeat
                    local event, p1 = os.pullEventRaw()
                    if event == "terminate" then
                        _G.KOMANDA_TERMINATED = true
                        basalt.stop()
                        return
                    elseif event == "monitor_touch" or event == "key" or event == "char" or event == "mouse_click" then
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

        if selectedVideo and not _G.KOMANDA_TERMINATED then
            videoplayer.play(mon, speakers, selectedVideo, config)
            -- loop back around: rebuild the list fresh after playback
        end
    end

    return _G.KOMANDA_TERMINATED and "quit" or exitReason
end

-- ==== Top-level state machine ====
while not _G.KOMANDA_TERMINATED do
    local target = runMainMenu(mainFrame)
    if target == "quit" or _G.KOMANDA_TERMINATED then break end
    if target == "video" then
        runVideoMenu(mainFrame) -- returns on "menu" (Back button), "idle", or "quit" -> main menu (or exit, below)
    else
        local musicplayer = require("musicplayer") -- loaded on first entry to this screen only
        musicplayer.run(mon, speakers, config, mainFrame) -- returns on "menu", "idle", or "quit" -> main menu (or exit, below)
    end
end
