-- settings.lua -- tiny persisted key/value store (currently just volume
-- levels) so the video/music players don't reset to the default volume
-- every time they're opened, which was loud/annoying on a public
-- installation. One flat JSON file, read/written whole each time --
-- infrequent enough (only on a volume button press) that this doesn't
-- need to be smarter than that.

local M = {}
local PATH = "komandax_settings.json"

function M.load()
    if not fs.exists(PATH) then return {} end
    local f = fs.open(PATH, "r")
    if not f then return {} end
    local content = f.readAll()
    f.close()
    local ok, parsed = pcall(textutils.unserialiseJSON, content)
    if ok and type(parsed) == "table" then return parsed end
    return {}
end

function M.save(t)
    local f = fs.open(PATH, "w")
    if not f then return end
    f.write(textutils.serialiseJSON(t))
    f.close()
end

return M
