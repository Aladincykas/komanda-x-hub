-- basalttest.lua -- one-off diagnostic, not part of the hub itself.
-- The smallest possible Basalt program: one label, one button, straight
-- from Basalt's own quickstart example. If this doesn't show up or
-- doesn't respond to clicks, the problem is in Basalt/this monitor, not
-- in hub.lua's more complex code. Ctrl+T to stop.

local config = require("config")
local basalt = require("basalt")

local mon = peripheral.wrap(config.MONITOR_NAME)
mon.setTextScale(config.MONITOR_TEXT_SCALE)

local frame = basalt.createFrame():setTerm(mon)
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
    end)

basalt.run()
