-- touchtest.lua -- one-off diagnostic, not part of the hub itself.
-- Prints every event to the COMPUTER's own terminal (not the monitor) so
-- it works even if nothing ever renders. Run this, then tap the monitor a
-- few times and watch what (if anything) prints. Ctrl+T to stop.

local config = require("config")
local mon = peripheral.wrap(config.MONITOR_NAME)

if not mon then
    error("peripheral.wrap('" .. config.MONITOR_NAME .. "') returned nil -- that name/side is wrong.")
end

print("MONITOR_NAME in config.lua: " .. config.MONITOR_NAME)
print("peripheral.getName(mon):    " .. tostring(peripheral.getName(mon)))
print("Is this an Advanced Monitor? Basic monitors CANNOT send touch events at all.")
print("Advanced Monitors have the orange/gold trim around the screen.")
print("")
print("Now tap the monitor. Every event will print below. Ctrl+T to stop.")
print("--------------------------------------------------------------")

while true do
    local e = { os.pullEvent() }
    local parts = {}
    for i = 1, #e do parts[#parts + 1] = tostring(e[i]) end
    print(table.concat(parts, "  "))
end
