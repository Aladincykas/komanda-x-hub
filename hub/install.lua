-- install.lua -- run this once in-game (on the Computer wired to your
-- monitor + speakers) to pull down the whole hub/ folder from GitHub.
--
-- Setup: push this project's hub/ folder to its own GitHub repo (public),
-- then edit HUB_REPO below to match. Then in-game:
--   wget run https://raw.githubusercontent.com/<you>/<repo>/main/install.lua
-- (or copy this one file in via a disk/floppy and run it locally.)

local GITHUB_USER = "Aladincykas"
local HUB_REPO = "komanda-x-hub"
local BRANCH = "main"

local FILES = {
    "config.lua",
    "matrix.lua",
    "videoplayer.lua",
    "musicplayer.lua",
    "hub.lua",
    "vendor/32vid-decode.lua",
}

local BASE_URL = ("https://raw.githubusercontent.com/%s/%s/%s/hub/"):format(GITHUB_USER, HUB_REPO, BRANCH)

local function download(url, destPath)
    local response, err = http.get(url .. "?t=" .. tostring(os.epoch("utc")))
    if not response then
        error(("Failed to download %s: %s"):format(url, tostring(err)))
    end
    local body = response.readAll()
    response.close()
    local f = fs.open(destPath, "w")
    f.write(body)
    f.close()
end

print("Installing Komanda X hub into /hub ...")
if not fs.exists("hub") then fs.makeDir("hub") end
if not fs.exists("hub/vendor") then fs.makeDir("hub/vendor") end

for _, relPath in ipairs(FILES) do
    print("  " .. relPath)
    download(BASE_URL .. relPath, "hub/" .. relPath)
end

print("\nInstalling Basalt 2.5 into /hub ...")
shell.setDir("hub")
shell.run("wget run https://basalt.madefor.cc/2.5/install.lua minified")
shell.setDir("/")
if not fs.exists("hub/basalt.lua") then
    print("WARNING: hub/basalt.lua wasn't found after running the Basalt installer.")
    print("Run this manually: cd hub, then wget run https://basalt.madefor.cc/2.5/install.lua minified")
end

local startup = fs.open("startup.lua", "w")
startup.write('shell.run("hub/hub.lua")\n')
startup.close()

print("\nDone. Run 'hub/hub.lua' now, or reboot to auto-start it.")
