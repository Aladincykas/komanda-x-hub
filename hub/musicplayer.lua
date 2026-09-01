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
        local buttonW = math.min(math.floor((w - 6) / 2), 16)
        local BLOCK_HEIGHT = 3 + 2 + VIZ_ROWS + 2 + 2 -- name/status/vol(3) + gap(2) + viz + gap(2) + 2 button rows(2)
        local blockTop = math.max(3, math.floor((h - 1 - BLOCK_HEIGHT) / 2) + 1)
        local nameY = blockTop
        local statusY = nameY + 1
        local volY = statusY + 1
        local vizY = volY + 2
        local btnRow1Y = vizY + VIZ_ROWS + 2
        local btnRow2Y = btnRow1Y + 2

        local vizX = math.max(1, math.floor((w - VIZ_COLS) / 2) + 1)
        local bx = math.max(1, math.floor((w - (buttonW * 2 + 2)) / 2) + 1)

        f:addLabel()
            :setText(song.name:sub(1, w - 2))
            :setPosition(math.max(1, math.floor((w - #song.name:sub(1, w - 2)) / 2) + 1), nameY)
            :setForeground(colors.white)
            :setBackground(colors.black)

        local statusLabel = f:addLabel()
            :setText("Loading...")
            :setPosition(2, statusY)
            :setForeground(colors.white)
            :setBackground(colors.black)

        local volLabel = f:addLabel()
            :setPosition(2, volY)
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

        local state = {
            paused = false,
            stopRequested = false,
            elapsedBytes = 0,
            volume = config.DEFAULT_VOLUME,
        }

        local function updateVolLabel()
            local pct = math.floor(state.volume / config.MAX_VOLUME * 100 + 0.5)
            volLabel:setText(("Volume: %d%%  (- / + below)"):format(pct))
        end
        updateVolLabel()

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
            :setText("Vol -")
            :setPosition(bx, btnRow2Y)
            :setSize(buttonW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                state.volume = math.max(0, math.floor((state.volume - 0.1) * 10 + 0.5) / 10)
                updateVolLabel()
            end)

        f:addButton()
            :setText("Vol +")
            :setPosition(bx + buttonW + 2, btnRow2Y)
            :setSize(buttonW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                state.volume = math.min(config.MAX_VOLUME, math.floor((state.volume + 0.1) * 10 + 0.5) / 10)
                updateVolLabel()
            end)

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

        basalt.schedule(function()
            local response, err = http.get(song.url, nil, true)
            if not response then
                statusLabel:setText("ERROR: " .. tostring(err))
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
            for _, spk in ipairs(speakers) do pcall(spk.stop) end
            basalt.stop()
        end)

        basalt.schedule(function()
            while true do
                statusLabel:setText((state.paused and "|| PAUSED  " or "> PLAYING  ") .. formatTime(state.elapsedBytes / 6000))
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

        basalt.run()
    end

    -- ==== Library list (paginated, tappable rows) ====
    local ROW_STEP = 2 -- 1 row for the button + 1 row gap, for touch accuracy and readability
    local contentTop = 4
    local footerRow = h
    local perPage = math.max(1, math.floor((footerRow - contentTop) / ROW_STEP))

    local exitReason = nil
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

    -- Idle timeout, same os.pullEvent-polling pattern as the video menu
    -- (see hub.lua's note on why basalt.onEvent isn't used here). Started
    -- ONCE for the whole session below, not per-loop-pass -- CC broadcasts
    -- events to every coroutine waiting on pullEvent regardless of which
    -- frame/run() is currently active, so this correctly tracks activity
    -- across both the library and the now-playing screen without needing
    -- to be restarted, and without leaking a new one per song played.
    -- If idle fires mid-playback it also force-stops the speakers directly
    -- (rather than relying on the playback coroutine to notice) since
    -- stopping THAT frame's run() loop doesn't by itself stop audio
    -- already queued on the speakers.
    basalt.schedule(function()
        local lastActivity = os.epoch("utc")
        local timeoutMs = (config.MUSIC_MENU_IDLE_TIMEOUT_SEC or 150) * 1000
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
                for _, spk in ipairs(speakers) do pcall(spk.stop) end
                basalt.stop()
                return
            end
        end
    end)

    -- Same reuse-the-frame pattern as hub.lua's runVideoMenu: rebuild and
    -- run the library screen; if a song was picked, play it (its own,
    -- separate basalt.run() call, only reached once THIS run() has fully
    -- returned) then loop back around to the library, fresh.
    while not exitReason do
        selectedSong = nil
        drawLibrary()
        frame:draw()
        basalt.run()

        if selectedSong then
            playSong(selectedSong)
        end
    end

    return exitReason
end

return M
