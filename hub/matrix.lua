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

-- Each column reverses direction on its OWN random timer, not all at once
-- on a shared global clock -- a synchronized whole-field flip (the
-- earlier version) looked like the screen "resetting" every 9 seconds,
-- reported in-game as a visible flash/glitch. Staggering it per-column
-- reads as continuous, organic "loops back and forth" motion instead,
-- with no single moment where anything jumps.
function Matrix:newColumn(x, randomStart)
    local h = self.h
    local dir = (math.random() < 0.5) and 1 or -1
    return {
        x = x,
        dir = dir,
        y = randomStart and math.random(1, h) or (dir == 1 and 0 or h + 1),
        len = math.random(4, math.max(5, math.floor(h / 2))),
        speed = 0.6 + math.random() * 0.9, -- rows per second
        accum = 0,
        glyphs = {},
        flipIn = 4 + math.random() * 10, -- seconds until THIS column reverses
    }
end

local function glyphAt(col, offset)
    local g = col.glyphs[offset]
    if not g then
        -- BUG (found in-game): using two independent math.random() calls for
        -- sub()'s start/end produced a random-length RUN of characters, not
        -- a single glyph -- most "glyphs" were actually several characters
        -- wide, which is why they spilled clean through the exclusion
        -- zones and wiped out the title/buttons. One shared index fixes it.
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
    local dir = col.dir
    local headY = math.floor(col.y)

    for i = 0, col.len do
        local y = headY - dir * i
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
    local eraseY = headY - dir * (col.len + 1)
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

        col.flipIn = col.flipIn - dt
        if col.flipIn <= 0 then
            -- Wipe THIS column's current trail before reversing it, using
            -- its old direction -- without this, the trail drawn under the
            -- old direction is never fully erased (drawColumn only ever
            -- erases one cell past the tail per tick) and leftover glyphs
            -- sit frozen on screen right at the flip point.
            self:clearColumnCells(col, 1, self.h)
            col.dir = -col.dir
            col.flipIn = 4 + math.random() * 10
            col.glyphs = {}
        end

        col.accum = col.accum + dt * col.speed
        while col.accum >= 1 do
            col.accum = col.accum - 1
            col.y = col.y + col.dir
            col.glyphs = {} -- re-roll glyphs each step for the classic "flicker"
            local offEdge = (col.dir == 1 and col.y - col.len > self.h)
                or (col.dir == -1 and col.y + col.len < 1)
            if offEdge then
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
