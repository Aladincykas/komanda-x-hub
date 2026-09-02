-- 32vid-decode.lua
-- Module form of MCJack123's 32vid-player-MINI.lua (from the sanjuuni
-- project, https://github.com/MCJack123/sanjuuni, MIT licensed).
--
-- NOTE ON WHICH PLAYER THIS IS: sanjuuni's 0.5 release ships several player
-- scripts (32vid-player.lua, 32vid-player-mini.lua, ...). This project
-- originally vendored 32vid-player.lua (the OLDER per-stream Huffman-coded
-- format), which does not match what sanjuuni.exe 0.5 actually produces by
-- default -- confirmed in-game ("No video stream found") and then by
-- directly parsing an uploaded chunk's header with Node: the single stream
-- present has type 12 (Vid32Chunk::Type::Combined, confirmed against
-- sanjuuni's own C++ source, src/sanjuuni.hpp), not type 0 (Video). Passing
-- -S/--separate-streams does NOT change this -- verified by converting a
-- fresh test clip and re-parsing the header, still type 12. 32vid-player-
-- mini.lua is the one that explicitly requires ctype == 0x0C (Combined)
-- and uses a completely different per-frame ANS/tANS-style entropy coder
-- (init/read below) instead of the older Huffman-tree approach -- this is
-- the actually-correct decoder for what this sanjuuni build outputs, and
-- is ported here as faithfully as possible. Do not "clean up" the ANS
-- table-construction math by hand; there's no independent way to verify
-- correctness of a change to it outside a real CC:Tweaked runtime.
--
-- STREAMING, NOT BATCH: this was previously rewritten to collect every
-- decoded video frame and audio chunk into video[]/audio[] arrays and
-- return them all at once after reading the whole chunk file. That was a
-- real mistake -- the ORIGINAL 32vid-player-mini.lua never does this, it
-- renders each video frame and plays each audio chunk immediately as it's
-- decoded, in one single streaming pass, holding at most one frame/chunk in
-- memory at a time. A real chunk is ~90s * ~10fps = ~900 video frame
-- records, each holding several ~2.7KB blit strings, plus ~90 one-second
-- audio chunks decoded as raw PCM tables (which have far more overhead per
-- element than packed bytes) -- collecting ALL of that into two big Lua
-- tables before playback even starts is a genuinely large amount of memory
-- pressure on a real CC:Tweaked computer, and is a very plausible
-- contributor to the monitor corruption/freeze symptoms that persisted even
-- after fps-capping and row-diffing the render side. This version goes back
-- to the reference design: M.decode() takes `handlers` and invokes them
-- inline per-record as it reads through the file, never accumulating more
-- than the current frame/chunk. See videoplayer.lua for how playback pacing
-- and audio dispatch now live inside those handler callbacks instead of a
-- separate post-decode phase.

local bit32_band, bit32_lshift, bit32_rshift, math_frexp = bit32.band, bit32.lshift, bit32.rshift, math.frexp
local function log2(n) local _, r = math_frexp(n) return r - 1 end
local dfpwm = require("cc.audio.dfpwm")

local blitColors = { [0] = "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f" }

local M = {}

-- Streams an already-open 32vid file handle (opened "rb") through
-- `handlers`, a table of:
--   handlers.onHeader(width, height, fps)       -- called once, up front
--   handlers.onVideoFrame(frame, frameIndex)     -- frame = {palette=..., [1..height]={text,fg,bg}}
--   handlers.onAudioChunk(chunk)                 -- chunk = PCM sample table (fire-and-forget, matches reference player)
--   handlers.shouldStop() -> bool                -- checked before each record; decode aborts early if true
-- Only supports the single-stream, Combined (type 0x0C), ANS-compressed
-- format sanjuuni.exe 0.5 actually produces with -3 -d (with or without -S)
-- -- see the header comment above. Closes `file` when done (including on
-- early stop or error).
function M.decode(file, handlers)
    handlers = handlers or {}
    if file.read(4) ~= "32VD" then file.close() error("Not a 32vid file") end
    local width, height, fps, nstreams, flags = ("<HHBBH"):unpack(file.read(8))
    if nstreams ~= 1 then
        file.close()
        error("This 32vid file uses separate streams, which this decoder doesn't support -- only the default Combined/ANS format is handled.")
    end
    if bit32_band(flags, 1) == 0 then
        file.close()
        error("This 32vid file isn't ANS-compressed, which this decoder doesn't support.")
    end
    local _, nframes, ctype = ("<IIB"):unpack(file.read(9))
    if ctype ~= 0x0C then
        file.close()
        error(("This 32vid file's stream type (%d) isn't Combined (12), which this decoder doesn't support."):format(ctype))
    end

    if handlers.onHeader then handlers.onHeader(width, height, fps) end

    -- ==== ANS (tANS-style) entropy decoder, ported verbatim ====
    local function readDict(size)
        local retval = {}
        for i = 0, size - 1, 2 do
            local b = file.read()
            retval[i] = bit32_rshift(b, 4)
            retval[i + 1] = bit32_band(b, 15)
        end
        return retval
    end

    local init, read
    local decodingTable, X, readbits, isColor
    function init(c)
        isColor = c
        local R = file.read()
        local L = 2 ^ R
        local Ls = readDict(c and 24 or 32)
        if R == 0 then
            decodingTable = file.read()
            X = nil
            return
        end
        local a = 0
        for i = 0, #Ls do Ls[i] = Ls[i] == 0 and 0 or 2 ^ (Ls[i] - 1) a = a + Ls[i] end
        assert(a == L, a)
        decodingTable = { R = R }
        local x, step, next_, symbol = 0, 0.625 * L + 3, {}, {}
        for i = 0, #Ls do
            next_[i] = Ls[i]
            for _ = 1, Ls[i] do
                while symbol[x] do x = (x + 1) % L end
                x, symbol[x] = (x + step) % L, i
            end
        end
        for x2 = 0, L - 1 do
            local s = symbol[x2]
            local t = { s = s, n = R - log2(next_[s]) }
            t.X, decodingTable[x2], next_[s] = bit32_lshift(next_[s], t.n) - L, t, 1 + next_[s]
        end
        local partial, bits, pos = 0, 0, 1
        function readbits(n)
            if not n then n = bits % 8 end
            if n == 0 then return 0 end
            while bits < n do pos, bits, partial = pos + 1, bits + 8, bit32_lshift(partial, 8) + file.read() end
            local retval = bit32_band(bit32_rshift(partial, bits - n), 2 ^ n - 1)
            bits = bits - n
            return retval
        end
        X = readbits(R)
    end
    function read(nsym)
        local retval = {}
        if X == nil then
            for i = 1, nsym do retval[i] = decodingTable end
            return retval
        end
        local i = 1
        local last = 0
        while i <= nsym do
            local t = decodingTable[X]
            if isColor and t.s >= 16 then
                local l = 2 ^ (t.s - 15)
                for n = 0, l - 1 do retval[i + n] = last end
                i = i + l
            else
                retval[i], last, i = t.s, t.s, i + 1
            end
            X = t.X + readbits(t.n)
        end
        return retval
    end

    -- ==== Main per-frame loop -- streams straight to handlers, nothing
    -- retained past the current record ====
    local vframe = 0

    for i = 1, nframes do
        if handlers.shouldStop and handlers.shouldStop() then break end

        local size, ftype = ("<IB"):unpack(file.read(5))

        if ftype == 0 then
            -- video frame: size is informational only, NOT used to bound
            -- the read -- the ANS init/read calls consume exactly as many
            -- bytes as they need, same as the original player.
            init(false)
            local screen = read(width * height)
            init(true)
            local bg = read(width * height)
            local fg = read(width * height)

            local frame = { palette = {} }
            for y = 0, height - 1 do
                local text, fgs, bgs = {}, {}, {}
                for x = 1, width do
                    text[x] = string.char(128 + screen[y * width + x])
                    fgs[x] = blitColors[fg[y * width + x]]
                    bgs[x] = blitColors[bg[y * width + x]]
                end
                frame[y + 1] = { table.concat(text), table.concat(fgs), table.concat(bgs) }
            end
            for n = 1, 16 do
                frame.palette[n] = { file.read() / 255, file.read() / 255, file.read() / 255 }
            end

            vframe = vframe + 1
            if handlers.onVideoFrame then handlers.onVideoFrame(frame, vframe) end
        elseif ftype == 1 then
            local data = file.read(size)
            local chunk
            if bit32_band(flags, 12) == 0 then
                chunk = { data:byte(1, -1) }
                for j = 1, #chunk do chunk[j] = chunk[j] - 128 end
            else
                chunk = dfpwm.decode(data)
            end
            -- This decoder itself never waits on anything here -- it just
            -- hands the decoded chunk to the handler and moves straight on
            -- to the next record, so decode throughput is never gated by
            -- speaker state. What the handler DOES with the chunk (dispatch
            -- immediately, queue it, wait for acks, ...) is entirely up to
            -- the caller -- see videoplayer.lua's onAudioChunk for why it
            -- queues rather than dispatching inline (a genuine
            -- fire-and-forget dispatch broke multi-speaker sync badly when
            -- tried, confirmed in-game).
            if handlers.onAudioChunk then handlers.onAudioChunk(chunk) end
        elseif ftype == 8 then
            -- Subtitle record: nothing in this project's UI renders
            -- subtitles, so just consume the bytes and move on rather than
            -- building tables no one reads.
            file.read(size)
        else
            file.close()
            error(("Unknown/unsupported frame type %d (multi-monitor output isn't supported here)"):format(ftype))
        end
    end

    file.close()
    if vframe == 0 then error("No video stream found in 32vid chunk") end
end

return M
