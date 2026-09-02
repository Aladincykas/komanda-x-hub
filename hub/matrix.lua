-- matrix.lua -- decorative "digital rain" background for the main menu.
--
-- IMPORTANT: this does NOT sit "behind" a Basalt frame in any z-order
-- sense -- there is no such thing here. Basalt only repaints a widget's
-- cells when one of that widget's properties changes; it does not
-- continuously repaint the whole frame. So if this draws into a cell a
-- Basalt widget owns, it permanently overwrites it (confirmed in-game:
-- without exclusions, the very first matrix tick erased the title and
-- both menu buttons and Basalt never repainted them). setExclusions()
-- must be called with every widget's cell rectangle before step() runs.
--
-- Plain one-directional fall, no back-and-forth reversal -- an earlier
-- version alternated fall/rise, which read as the screen "resetting" and
-- was asked to be reverted to normal matrix-style rain.
--
-- RENDERING: batched per-ROW mon.blit, not per-cell mon.setCursorPos+write.
-- The original version wrote every visible cell individually -- for a
-- 71-wide monitor with ~70 active columns and trails up to ~10 cells long,
-- that's 700+ separate peripheral calls every single step (every 0.2s),
-- forever, for as long as the main menu sits idle. That's the exact same
-- "too much monitor I/O" pattern that caused video playback's monitor
-- corruption (fixed there by switching to row-diffed blit) -- just via a
-- different code path that was never fixed here, and a very plausible
-- cause of the monitor eventually going blank after the main menu sits
-- untouched for a while. This version keeps the identical visual output
-- (same glyphs, same colors, same fall/flicker behavior) but builds a
-- full-width text/color buffer per row and does ONE mon.blit per row that
-- actually changed (skipping the excluded box's column range within that
-- row, so its own content is never touched), cutting per-step peripheral
-- calls from 700+ down to roughly the monitor's row count.

local GLYPHS = "01ABCDEFGHIJKLMNOPQRSTUVWXYZ#$%&*+-/<>=?"

local function splice(s, pos, repl)
    return s:sub(1, pos - 1) .. repl .. s:sub(pos + #repl)
end

local Matrix = {}
Matrix.__index = Matrix

function Matrix.new(mon)
    local w, h = mon.getSize()
    local self = setmetatable({
        mon = mon, w = w, h = h,
        columns = {},
        exclusions = {},
        text = {}, fg = {}, bg = {},
        prevText = {}, prevFg = {},
    }, Matrix)

    local blankText = (" "):rep(w)
    local blankFg = colors.toBlit(colors.white):rep(w)
    local blankBg = colors.toBlit(colors.black):rep(w)
    for y = 1, h do
        self.text[y], self.fg[y], self.bg[y] = blankText, blankFg, blankBg
        self.prevText[y], self.prevFg[y] = nil, nil -- force the first flush to draw every row
    end

    for x = 1, w do
        self.columns[x] = self:newColumn(x, true)
    end
    return self
end

-- rects: array of {x1, y1, x2, y2} (inclusive, 1-based) cell rectangles
-- that belong to other widgets (Basalt labels/buttons, a control bar, etc)
-- and must never be written to. Replaces any previously set exclusions.
function Matrix:setExclusions(rects)
    self.exclusions = rects or {}
end

function Matrix:isExcluded(x, y)
    for _, r in ipairs(self.exclusions) do
        if x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4] then
            return true
        end
    end
    return false
end

function Matrix:newColumn(x, randomStart)
    local h = self.h
    return {
        x = x,
        y = randomStart and math.random(1, h) or 0,
        len = math.random(2, math.max(3, math.floor(h / 4))), -- shorter trails = "smaller" look
        speed = 0.6 + math.random() * 0.9, -- rows per second
        accum = 0,
        glyphs = {},
    }
end

local function glyphAt(col, offset)
    local g = col.glyphs[offset]
    if not g then
        local idx = math.random(1, #GLYPHS)
        g = GLYPHS:sub(idx, idx)
        col.glyphs[offset] = g
    end
    return g
end

-- Writes one cell into this step's buffer (not the monitor). Excluded
-- cells are silently skipped, same as the old per-cell isExcluded check --
-- they just never get touched, so whatever Basalt drew there stays.
function Matrix:setCellBuf(x, y, ch, fgColor)
    if x < 1 or x > self.w or y < 1 or y > self.h then return end
    if self:isExcluded(x, y) then return end
    self.text[y] = splice(self.text[y], x, ch)
    self.fg[y] = splice(self.fg[y], x, colors.toBlit(fgColor))
end

function Matrix:clearColumnBuf(col, fromY, toY)
    for y = math.max(1, fromY), math.min(self.h, toY) do
        self:setCellBuf(col.x, y, " ", colors.white)
    end
end

function Matrix:updateColumnBuf(col)
    local headY = math.floor(col.y)

    for i = 0, col.len do
        local y = headY - i
        local color
        if i == 0 then
            color = colors.white
        elseif i < col.len * 0.35 then
            color = colors.lime
        else
            color = colors.green
        end
        self:setCellBuf(col.x, y, glyphAt(col, i), color)
    end

    -- erase the cell just past the tail so the trail doesn't smear
    local eraseY = headY - (col.len + 1)
    self:setCellBuf(col.x, eraseY, " ", colors.white)
end

-- Returns the list of {x1, x2} column ranges on row y that are NOT covered
-- by any exclusion rect, so flush() can blit around a box sitting in the
-- middle of a row instead of overwriting it. Assumes exclusion rects don't
-- overlap each other (true for how this project actually uses it -- one
-- box at a time).
function Matrix:rowSegments(y)
    local excludedRanges = {}
    for _, r in ipairs(self.exclusions) do
        if y >= r[2] and y <= r[4] then
            table.insert(excludedRanges, { math.max(1, r[1]), math.min(self.w, r[3]) })
        end
    end
    if #excludedRanges == 0 then
        return { { 1, self.w } }
    end
    table.sort(excludedRanges, function(a, b) return a[1] < b[1] end)
    local segments = {}
    local cursor = 1
    for _, er in ipairs(excludedRanges) do
        if er[1] > cursor then
            table.insert(segments, { cursor, er[1] - 1 })
        end
        cursor = math.max(cursor, er[2] + 1)
    end
    if cursor <= self.w then
        table.insert(segments, { cursor, self.w })
    end
    return segments
end

-- Sends this step's buffer to the monitor: one mon.blit per row that
-- actually changed since the last flush, split around any excluded region
-- on that row. Most rows change every step by design (glyphs re-roll each
-- tick for the flicker effect), but skipping untouched rows still matters
-- a lot right after a column resets or while few columns are near a
-- given row.
function Matrix:flush()
    local mon = self.mon
    for y = 1, self.h do
        if self.text[y] ~= self.prevText[y] or self.fg[y] ~= self.prevFg[y] then
            for _, seg in ipairs(self:rowSegments(y)) do
                local x1, x2 = seg[1], seg[2]
                if x2 >= x1 then
                    mon.setCursorPos(x1, y)
                    mon.blit(self.text[y]:sub(x1, x2), self.fg[y]:sub(x1, x2), self.bg[y]:sub(x1, x2))
                end
            end
            self.prevText[y] = self.text[y]
            self.prevFg[y] = self.fg[y]
        end
    end
    self.mon.setTextColor(colors.white)
end

-- Advances the whole field by `dt` seconds and redraws changed cells.
-- Call this once per animation tick from the main menu's render loop.
function Matrix:step(dt)
    for x = 1, self.w do
        local col = self.columns[x]
        col.accum = col.accum + dt * col.speed
        while col.accum >= 1 do
            col.accum = col.accum - 1
            col.y = col.y + 1
            col.glyphs = {} -- re-roll glyphs each step for the classic "flicker"
            if col.y - col.len > self.h then
                self:clearColumnBuf(col, 1, self.h)
                self.columns[x] = self:newColumn(x, false)
                col = self.columns[x]
            end
        end
        self:updateColumnBuf(col)
    end
    self:flush()
end

return Matrix
