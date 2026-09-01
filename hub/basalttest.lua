-- basalttest.lua -- one-off diagnostic, not part of the hub itself.
-- The smallest possible Basalt program: one label, one button. Prints
-- diagnostics to the COMPUTER's own terminal at every step so we can see
-- exactly where it stops working, instead of guessing from a blank
-- monitor. Ctrl+T to stop.

local config = require("config")
local basalt = require("basalt")
print("basalt loaded: " .. tostring(basalt))

local mon = peripheral.wrap(config.MONITOR_NAME)
print("mon = " .. tostring(mon))
if not mon then error("peripheral.wrap('" .. config.MONITOR_NAME .. "') returned nil") end

mon.setTextScale(config.MONITOR_TEXT_SCALE)
local w, h = mon.getSize()
print(("mon size = %dx%d"):format(w, h))

-- Root cause found by reading basalt.lua directly: createFrame(t) resolves
-- peripheral.getName(t) into the frame's "monitor" field, which is what
-- routes monitor_touch events to it at all. createFrame():setTerm(mon)
-- (the pattern shown in Basalt's own docs) never sets that field, so
-- clicks silently do nothing no matter what. Must pass mon directly.
local frame = basalt.createFrame(mon)
print("frame = " .. tostring(frame) .. "  frame.monitor = " .. tostring(rawget(frame, "monitor")))
frame:setBackground(colors.black)

frame:addLabel()
    :setText("BASALT TEST")
    :setPosition(2, 2)
    :setForeground(colors.yellow)
    :setBackground(colors.black)

local clicks = 0
frame:addButton()
    :setText("CLICK ME")
    :setPosition(2, 4)
    :setSize(12, 1)
    :setBackground(colors.gray)
    :setForeground(colors.white)
    :onClick(function(self)
        clicks = clicks + 1
        self:setText("CLICKED " .. clicks)
        print("Button clicked! count=" .. clicks)
    end)

if basalt.setActiveFrame then
    print("Calling basalt.setActiveFrame(frame)...")
    basalt.setActiveFrame(frame)
else
    print("basalt.setActiveFrame doesn't exist on this build.")
end

print("Calling basalt.run() now -- check the monitor.")
local ok, err = pcall(basalt.run)
print("basalt.run() returned. ok=" .. tostring(ok) .. "  err=" .. tostring(err))
