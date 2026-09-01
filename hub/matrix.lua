-- matrix.lua -- decorative "digital rain" background for the main menu.
-- Drawn directly with per-cell writes (not term.blit) since only a handful
-- of cells change per frame; a full-screen blit every tick would be
-- wasteful here in a way it isn't for the video/music screens.
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

local GLYPHS = "01ABCDEFGHIJKLMNOPQRSTUVWXYZ#$%&*+-/<>=?"

local Matrix = {}
Matrix.__index = Matrix

function Matrix.new(mon)
    local w, h = mon.getSize()
    local self = setmetatable({
        mon = mon, w = w, h = h,
        columns = {},
        exclusions = {},
    }, Matrix)

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

function Matrix:clearColumnCells(col, fromY, toY)
    local mon = self.mon
    for y = math.max(1, fromY), math.min(self.h, toY) do
        if not self:isExcluded(col.x, y) then
            mon.setCursorPos(col.x, y)
            mon.write(" ")
        end
    end
end

function Matrix:drawColumn(col)
    local mon = self.mon
    local headY = math.floor(col.y)

    for i = 0, col.len do
        local y = headY - i
        if y >= 1 and y <= self.h and not self:isExcluded(col.x, y) then
            mon.setCursorPos(col.x, y)
            if i == 0 then
                mon.setTextColor(colors.white)
            elseif i < col.len * 0.35 then
                mon.setTextColor(colors.lime)
            else
                mon.setTextColor(colors.green)
            end
            mon.write(glyphAt(col, i))
        end
    end

    -- erase the cell just past the tail so the trail doesn't smear
    local eraseY = headY - (col.len + 1)
    if eraseY >= 1 and eraseY <= self.h and not self:isExcluded(col.x, eraseY) then
        mon.setCursorPos(col.x, eraseY)
        mon.write(" ")
    end
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
                self:clearColumnCells(col, 1, self.h)
                self.columns[x] = self:newColumn(x, false)
                col = self.columns[x]
            end
        end
        self:drawColumn(col)
    end
    self.mon.setTextColor(colors.white)
end

return Matrix
