-- musicplayer.lua -- touch-driven music library + player, built on Basalt.
--
-- This replaced an earlier version ported almost verbatim from the
-- original Pocket-Computer jukebox (music.lua), which was keyboard-only
-- (Up/Down/Enter/F5, a typed search box). That's unusable on an
-- installation meant to be operated by touching a wall-mounted monitor --
-- there's no keyboard there at all -- so this is a full rewrite: a
-- paginated, tappable song list (no search box, since there's nothing to
-- type on) and a Now Playing screen with Play/Pause/Stop/Volume buttons
-- instead of key bindings.

local dfpwm = require("cc.audio.dfpwm")
local basalt = require("basalt")
local settings = require("settings")

local M = {}

local function buildManifestUrls(config)
    local urls = {}
    for _, lib in ipairs(config.MUSIC_LIBRARIES) do
        table.insert(urls, ("https://raw.githubusercontent.com/%s/%s/%s/songs.json")
            :format(config.GITHUB_USER, lib.repo, lib.branch))
    end
    return urls
end

local function fetchSongs(manifestUrls)
    local songs = {}
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
            if type(parsed) == "table" then
                for _, song in ipairs(parsed) do table.insert(songs, song) end
            else
                table.insert(errors, manifestUrl .. " -> invalid JSON")
            end
        end
    end
    return songs, errors
end

-- Same pattern as hub.lua's clearFrameChildren -- see the comment there for
-- why frames get reused instead of recreated (createFrame() never gets
-- cleaned up, and its click router keeps dispatching to every frame it's
-- ever created, forever).
local function clearFrameChildren(frame)
    local children = rawget(frame, "_children")
    while children and #children > 0 do
        local child = children[#children]
        if child.destroy then child:destroy() end
        if children[#children] == child then frame:removeChild(child) end
    end
end

local function formatTime(seconds)
    seconds = math.floor(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return ("%d:%02d"):format(m, s)
end

-- Use instead of basalt.schedule() everywhere in this file. Plain sleep()
-- (an os.sleep alias) is just os.pullEvent("timer") under the hood, which
-- THROWS on a terminate event no matter what filter it's given, and
-- Basalt resumes scheduled coroutines in reverse registration order -- so
-- any coroutine using plain sleep() could throw first and abort that
-- whole resume pass before hub.lua's terminate watcher ever got a turn.
-- Wrapping every scheduled function's body in its own pcall means each
-- one independently notices its own termination and cooperatively sets
-- the shared flag + stops, regardless of Basalt's resume order. See the
-- matching note in hub.lua next to safeSchedule there.
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

-- `frame` is ONE Basalt frame shared across the whole hub (hub.lua creates
-- it once via basalt.createFrame(mon) and passes it into every screen).
-- Two separate frame objects wrapping the same monitor each keep their
-- own independent redraw buffer -- confirmed in-game: using a separate
-- libraryFrame and nowPlayingFrame rendered as "a complete mess" that
-- "overwrites to black screen" when switching between the library and Now
-- Playing, since switching frames doesn't repaint over the other frame's
-- leftover pixels. One shared frame, cleared and rebuilt for whichever
-- screen is active, avoids that entirely.
function M.run(mon, speakers, config, frame)
    local w, h = mon.getSize()
    local manifestUrls = buildManifestUrls(config)

    -- Declared here (not down by the library loop) so playSong()'s closure
    -- below can set it directly -- an idle timeout firing WHILE a song is
    -- playing needs to force all the way out to the main menu, not just
    -- back to the library screen.
    local exitReason = nil

    -- Idle watcher: reusable, but scheduled FRESH inside whichever
    -- basalt.run() session is actually pumping events (once at the top of
    -- the library loop, once at the top of playSong), rather than trying to
    -- keep ONE watcher coroutine alive across two separate basalt.run()
    -- calls. A single coroutine scheduled once used to sit suspended
    -- between the library's run() and playSong's own run() -- Basalt's
    -- `schedules` table is never cleared between run() calls so it wasn't
    -- literally dead, but it only gets resumed (and can only make forward
    -- progress) while SOME run() loop is actively dispatching events, and a
    -- long-idle Now Playing screen with nothing else scheduling frequent
    -- events made that unreliable in practice (confirmed in-game: idle
    -- timeout wasn't firing while a song was left playing). Rescheduling
    -- fresh inside the run() that's actually live removes that ambiguity
    -- entirely. `lastActivityMs` is a shared upvalue so activity carries
    -- over between the library and Now Playing without resetting the clock
    -- just because the screen changed.
    local lastActivityMs = os.epoch("utc")
    local function startIdleWatcher(onIdle)
        safeSchedule(function()
            local timeoutMs = (config.MUSIC_MENU_IDLE_TIMEOUT_SEC or 300) * 1000
            while true do
                local timerId = os.startTimer(5)
                repeat
                    local event, p1 = os.pullEventRaw()
                    if event == "terminate" then
                        _G.KOMANDA_TERMINATED = true
                        for _, spk in ipairs(speakers) do pcall(spk.stop) end
                        basalt.stop()
                        return
                    elseif event == "monitor_touch" or event == "key" or event == "char" or event == "mouse_click" then
                        lastActivityMs = os.epoch("utc")
                    end
                until event == "timer" and p1 == timerId
                if os.epoch("utc") - lastActivityMs > timeoutMs then
                    onIdle()
                    return
                end
            end
        end)
    end

    -- ==== Now Playing screen ====
    -- 5-row bar equalizer, old-media-player style: each of the VIZ_COLS
    -- columns has its own random height 0-5, one addLabel per ROW (not per
    -- cell -- that would be VIZ_COLS*5 elements, too many for a CC
    -- computer to push every tick) built by concatenating a character per
    -- column for that row. CC has no real audio-analysis API, so like the
    -- original Pocket-Computer jukebox's equalizer this is decorative/
    -- randomized while playing, not a real spectrum.
    local VIZ_COLS = math.min(w - 4, 40)
    local VIZ_ROWS = 5
    local VIZ_ROW_COLORS = { colors.red, colors.orange, colors.yellow, colors.lime, colors.green } -- top -> bottom
    local vizHeights = {}
    for i = 1, VIZ_COLS do vizHeights[i] = 0 end

    local function playSong(song)
        clearFrameChildren(frame)
        local f = frame

        f:addLabel()
            :setText((" NOW PLAYING "):sub(1, w))
            :setSize(w, 1)
            :setPosition(1, 1)
            :setForeground(colors.lime)
            :setBackground(colors.gray)

        -- Whole content block (song name, status, volume, visualizer,
        -- controls) centered as one unit in the space below the header and
        -- above the footer button, instead of hugging the top-left with a
        -- lot of empty black space below (the "very very empty" complaint).
        -- Real gaps (2 rows) between name/status/volume now too, instead
        -- of them sitting directly on top of each other.
        local buttonW = math.min(math.floor((w - 6) / 2), 16)
        -- name(1) gap(2) status(1) gap(2) volume(1) gap(3) viz(VIZ_ROWS) gap(2) 4 button rows w/ 1-row gaps(7)
        local BLOCK_HEIGHT = 1 + 2 + 1 + 2 + 1 + 3 + VIZ_ROWS + 2 + 7
        local blockTop = math.max(3, math.floor((h - 1 - BLOCK_HEIGHT) / 2) + 1)
        local nameY = blockTop
        local statusY = nameY + 2
        local volY = statusY + 2
        local vizY = volY + 3
        local btnRow1Y = vizY + VIZ_ROWS + 2
        local btnRow2Y = btnRow1Y + 2
        local btnRow3Y = btnRow2Y + 2
        local btnRow4Y = btnRow3Y + 2

        local vizX = math.max(1, math.floor((w - VIZ_COLS) / 2) + 1)
        local bx = math.max(1, math.floor((w - (buttonW * 2 + 2)) / 2) + 1)

        local function centerLabel(label, y, text, color)
            label:setText(text)
            if color then label:setForeground(color) end
            label:setPosition(math.max(1, math.floor((w - #text) / 2) + 1), y)
        end

        local nameLabel = f:addLabel()
            :setForeground(colors.white)
            :setBackground(colors.black)
        centerLabel(nameLabel, nameY, song.name:sub(1, w - 2))

        local statusLabel = f:addLabel()
            :setForeground(colors.white)
            :setBackground(colors.black)
        centerLabel(statusLabel, statusY, "Loading...")

        local volLabel = f:addLabel()
            :setForeground(colors.lime)
            :setBackground(colors.black)

        local vizRowLabels = {}
        for r = 1, VIZ_ROWS do
            vizRowLabels[r] = f:addLabel()
                :setText((" "):rep(VIZ_COLS))
                :setSize(VIZ_COLS, 1)
                :setPosition(vizX, vizY + r - 1)
                :setForeground(VIZ_ROW_COLORS[r])
                :setBackground(colors.black)
        end

        -- Volume persists across songs/sessions (a saved settings file, not
        -- an in-memory default) -- it used to reset to config.DEFAULT_VOLUME
        -- every single time, which was loud and annoying on a public
        -- installation.
        local savedSettings = settings.load()
        local state = {
            paused = false,
            stopRequested = false,
            -- Real wall-clock elapsed time (like the video player's
            -- os.epoch-paced clock), NOT inferred from DFPWM byte count.
            -- The old version divided bytes-read-so-far by 6000 (the
            -- DFPWM-at-48kHz byte rate) -- mathematically reasonable, but
            -- it counted bytes as soon as they were DOWNLOADED, not as
            -- they were actually PLAYED, so it could run ahead of (or
            -- behind) what was actually audible rather than tracking real
            -- time. elapsedMs only advances while actually playing
            -- (paused time doesn't count), accumulated in small real
            -- deltas by the status-label tick below.
            elapsedMs = 0,
            lastTickMs = os.epoch("utc"),
            volume = savedSettings.musicVolume or config.DEFAULT_VOLUME,
        }

        local function updateVolLabel()
            local pct = math.floor(state.volume / config.MAX_VOLUME * 100 + 0.5)
            centerLabel(volLabel, volY, ("Volume: %d%%"):format(pct))
        end
        updateVolLabel()

        -- setVolume(delta) where delta is a FRACTION of MAX_VOLUME (e.g.
        -- 0.05 = "+5%"), not a raw volume unit, since that's how the step
        -- size was asked for ("every 5 +/-", "every 20 +/-").
        local function adjustVolume(deltaFraction)
            local step = deltaFraction * config.MAX_VOLUME
            state.volume = math.max(0, math.min(config.MAX_VOLUME, state.volume + step))
            updateVolLabel()
            savedSettings.musicVolume = state.volume
            settings.save(savedSettings)
        end

        local playPauseBtn = f:addButton()
            :setText("Pause")
            :setPosition(bx, btnRow1Y)
            :setSize(buttonW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function(self)
                state.paused = not state.paused
                self:setText(state.paused and "Play" or "Pause")
                os.queueEvent("music_control")
            end)

        f:addButton()
            :setText("Stop")
            :setPosition(bx + buttonW + 2, btnRow1Y)
            :setSize(buttonW, 1)
            :setBackground(colors.red)
            :setForeground(colors.white)
            :onClick(function()
                state.stopRequested = true
                os.queueEvent("music_control")
            end)

        f:addButton()
            :setText("Vol -1%")
            :setPosition(bx, btnRow2Y)
            :setSize(buttonW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function() adjustVolume(-0.01) end)

        f:addButton()
            :setText("Vol +1%")
            :setPosition(bx + buttonW + 2, btnRow2Y)
            :setSize(buttonW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function() adjustVolume(0.01) end)

        f:addButton()
            :setText("Vol -5%")
            :setPosition(bx, btnRow3Y)
            :setSize(buttonW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function() adjustVolume(-0.05) end)

        f:addButton()
            :setText("Vol +5%")
            :setPosition(bx + buttonW + 2, btnRow3Y)
            :setSize(buttonW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function() adjustVolume(0.05) end)

        f:addButton()
            :setText("Vol -20%")
            :setPosition(bx, btnRow4Y)
            :setSize(buttonW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function() adjustVolume(-0.20) end)

        f:addButton()
            :setText("Vol +20%")
            :setPosition(bx + buttonW + 2, btnRow4Y)
            :setSize(buttonW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function() adjustVolume(0.20) end)

        f:addButton()
            :setText("Back to Library")
            :setPosition(2, h)
            :setSize(math.min(w - 2, 20), 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                state.stopRequested = true
                os.queueEvent("music_control")
            end)

        f:draw()

        safeSchedule(function()
            local response, err = http.get(song.url, nil, true)
            if not response then
                centerLabel(statusLabel, statusY, "ERROR: " .. tostring(err))
                sleep(1.5)
                basalt.stop()
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

                -- Dispatch to every speaker IN PARALLEL, not one at a time.
                -- The old version looped speakers sequentially, each
                -- blocking (potentially waiting on speaker_audio_empty)
                -- before the NEXT speaker even got this chunk -- fine with
                -- a couple of speakers, but the delay compounds with every
                -- speaker added, and confirmed in-game as real desync once
                -- more speakers joined ("not every speaker sound the
                -- same and gets delayed"). Same fix already applied to
                -- video playback's audio dispatch: fan out with
                -- parallel.waitForAll, each speaker waiting only for ITS
                -- OWN ack (filtered by peripheral name -- an unfiltered
                -- wait could resume on a DIFFERENT speaker's empty event
                -- and retry too early), with a 3s timeout so one dead
                -- speaker among many can't stall the whole song.
                local buffer = decoder(chunk)
                if #speakers > 0 then
                    local funcs = {}
                    for _, speaker in ipairs(speakers) do
                        funcs[#funcs + 1] = function()
                            while not state.stopRequested and not speaker.playAudio(buffer, state.volume) do
                                local timerId = os.startTimer(3)
                                local gaveUp = false
                                repeat
                                    local ev, a = os.pullEvent()
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
                    parallel.waitForAll(table.unpack(funcs))
                end
            end

            response.close()
            for _, spk in ipairs(speakers) do pcall(spk.stop) end
            basalt.stop()
        end)

        safeSchedule(function()
            while true do
                -- Real wall-clock elapsed time -- only advances while
                -- actually playing (a real delta each tick, so pausing
                -- genuinely freezes it instead of it drifting from
                -- inferred data rates). See the state table's comment
                -- above for why this replaced byte-count-based timing.
                local nowMs = os.epoch("utc")
                if not state.paused then
                    state.elapsedMs = state.elapsedMs + (nowMs - state.lastTickMs)
                end
                state.lastTickMs = nowMs

                centerLabel(statusLabel, statusY,
                    (state.paused and "|| PAUSED  " or "> PLAYING  ") .. formatTime(state.elapsedMs / 1000))
                playPauseBtn:setText(state.paused and "Play" or "Pause")

                -- Roll new random bar heights (only while actually playing,
                -- so it goes still on pause instead of animating uselessly)
                -- and redraw all VIZ_ROWS at once.
                if not state.paused then
                    for c = 1, VIZ_COLS do
                        vizHeights[c] = math.random(0, VIZ_ROWS)
                    end
                end
                for r = 1, VIZ_ROWS do
                    local chars = {}
                    for c = 1, VIZ_COLS do
                        -- row 1 is the TOP of the bar, so a column needs
                        -- height >= (VIZ_ROWS - r + 1) to reach this row.
                        chars[c] = (vizHeights[c] >= (VIZ_ROWS - r + 1)) and "#" or " "
                    end
                    vizRowLabels[r]:setText(table.concat(chars))
                end

                sleep(0.3)
            end
        end)

        startIdleWatcher(function()
            exitReason = exitReason or "idle"
            state.stopRequested = true
            os.queueEvent("music_control")
            for _, spk in ipairs(speakers) do pcall(spk.stop) end
            basalt.stop()
        end)

        basalt.run()
    end

    -- ==== Library list (paginated, tappable rows) ====
    local ROW_STEP = 2 -- 1 row for the button + 1 row gap, for touch accuracy and readability
    local contentTop = 4
    local footerRow = h
    local perPage = math.max(1, math.floor((footerRow - contentTop) / ROW_STEP))

    local songs, loadErrors = fetchSongs(manifestUrls)
    local page = 1
    local selectedSong = nil -- set by a song button's onClick, read by the loop below AFTER run() returns

    local function drawLibrary()
        clearFrameChildren(frame)
        local f = frame
        local totalPages = math.max(1, math.ceil(#songs / perPage))
        if page > totalPages then page = totalPages end

        f:addLabel()
            :setText((" MUSIC LIBRARY "):sub(1, w))
            :setSize(w, 1)
            :setPosition(1, 1)
            :setForeground(colors.lime)
            :setBackground(colors.gray)

        if #loadErrors > 0 then
            f:addLabel()
                :setText(("Load error(s): %d -- showing what loaded"):format(#loadErrors))
                :setPosition(2, 2)
                :setForeground(colors.red)
                :setBackground(colors.black)
        else
            f:addLabel()
                :setText(("%d song(s) -- page %d/%d"):format(#songs, page, totalPages))
                :setPosition(2, 2)
                :setForeground(colors.lightGray)
                :setBackground(colors.black)
        end

        if #songs == 0 then
            f:addLabel()
                :setText("No songs found.")
                :setPosition(2, contentTop)
                :setForeground(colors.lightGray)
                :setBackground(colors.black)
        else
            local startIdx = (page - 1) * perPage + 1
            for i = 0, perPage - 1 do
                local idx = startIdx + i
                local song = songs[idx]
                if song then
                    f:addButton()
                        :setText(song.name:sub(1, w - 4))
                        :setPosition(2, contentTop + i * ROW_STEP)
                        :setSize(w - 2, 1)
                        :setBackground(colors.gray)
                        :setForeground(colors.lime)
                        :onClick(function()
                            -- MUST NOT call playSong() (and its basalt.run())
                            -- directly from here -- we're still inside THIS
                            -- frame's own active basalt.run() call, and
                            -- basalt.run() errors ("Basalt is already
                            -- running") if called again before the outer
                            -- one has actually returned. Same pattern as
                            -- runVideoMenu in hub.lua: just record the
                            -- selection and stop; the loop below calls
                            -- playSong() only once run() has truly exited.
                            selectedSong = song
                            basalt.stop()
                        end)
                end
            end
        end

        local navW = math.min(math.floor((w - 8) / 3), 14)
        f:addButton()
            :setText("< Prev")
            :setPosition(2, footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                if page > 1 then page = page - 1 end
                drawLibrary()
            end)

        f:addButton()
            :setText("Next >")
            :setPosition(4 + navW, footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                if page < totalPages then page = page + 1 end
                drawLibrary()
            end)

        f:addButton()
            :setText("Refresh")
            :setPosition(6 + navW * 2, footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                songs, loadErrors = fetchSongs(manifestUrls)
                page = 1
                drawLibrary()
            end)

        f:addButton()
            :setText("Main Menu")
            :setPosition(w - math.min(w - 2, 14) + 1, footerRow)
            :setSize(math.min(w - 2, 14), 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                exitReason = "menu"
                basalt.stop()
            end)
    end

    -- Same reuse-the-frame pattern as hub.lua's runVideoMenu: rebuild and
    -- run the library screen; if a song was picked, play it (its own,
    -- separate basalt.run() call, only reached once THIS run() has fully
    -- returned) then loop back around to the library, fresh. The idle
    -- watcher is (re)scheduled fresh each pass -- see startIdleWatcher's
    -- comment up top for why -- and shares lastActivityMs with playSong's
    -- own watcher so activity carries over across screen switches.
    while not exitReason and not _G.KOMANDA_TERMINATED do
        selectedSong = nil
        drawLibrary()
        frame:draw()
        startIdleWatcher(function()
            exitReason = exitReason or "idle"
            for _, spk in ipairs(speakers) do pcall(spk.stop) end
            basalt.stop()
        end)
        basalt.run()

        if selectedSong and not _G.KOMANDA_TERMINATED then
            playSong(selectedSong)
        end
    end

    return _G.KOMANDA_TERMINATED and "quit" or exitReason
end

return M
