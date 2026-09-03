-- install.lua -- run this once in-game (on the Computer wired to your
-- monitor + speakers) to pull down the whole hub/ folder from GitHub,
-- Basalt included. Basalt's OWN installer (wget run
-- basalt.madefor.cc/2.5/install.lua) is NOT used here -- that domain isn't
-- on this server's http.rules allowlist (only github.com/githubusercontent
-- etc are, same restriction the original jukebox README documents), so
-- basalt.lua is vendored straight into this repo's hub/ folder and fetched
-- from raw.githubusercontent.com like everything else.
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
    "settings.lua",
    "hub.lua",
    "basalt.lua",
    "vendor/32vid-decode.lua",
}

-- Resolves the branch to the exact commit it currently points at, and
-- downloads from THAT commit's URLs rather than the branch's.
--
-- Not belt-and-braces -- it is the only thing that works. GitHub's raw CDN
-- caches for five minutes and does NOT include the query string in its cache
-- key, so the "?t=<timestamp>" below busted nothing whatsoever. Verified
-- directly: a request with a fresh random query still returned
-- "X-Cache: HIT" carrying the previous version's bytes, while the API
-- reported the new size. That is the entire explanation for a long run of
-- "I reinstalled and it is still running the old code".
--
-- A commit-pinned URL is a different path per commit, so it cannot serve a
-- stale copy. The API call that resolves it is not cached this way.
local function resolveCommit()
    local response = http.get(
        ("https://api.github.com/repos/%s/%s/commits/%s"):format(GITHUB_USER, HUB_REPO, BRANCH),
        { Accept = "application/vnd.github.sha" })
    if not response then return nil end
    local sha = response.readAll()
    response.close()
    if type(sha) ~= "string" then return nil end
    sha = sha:gsub("%s", "")
    if #sha < 7 then return nil end
    return sha
end

local COMMIT = resolveCommit()
if COMMIT then
    print("Installing from commit " .. COMMIT:sub(1, 7))
else
    -- Said out loud, because silently installing stale code is precisely the
    -- failure this exists to prevent.
    print("WARNING: could not resolve the commit -- falling back to the")
    print("branch, which may serve a copy up to 5 minutes old.")
end
local REF = COMMIT or BRANCH

local BASE_URL = ("https://raw.githubusercontent.com/%s/%s/%s/hub/"):format(GITHUB_USER, HUB_REPO, REF)

local function download(url, destPath)
    local response, err = http.get(url)
    if not response then
        error(("Failed to download %s: %s"):format(url, tostring(err)))
    end
    local body = response.readAll()
    response.close()
    if not body or #body == 0 then
        error(("Downloaded %s but it was EMPTY -- refusing to overwrite."):format(url))
    end
    -- Delete before writing rather than truncating, so nothing old can
    -- possibly survive an install whatever the cause.
    if fs.exists(destPath) then fs.delete(destPath) end
    local f = fs.open(destPath, "w")
    f.write(body)
    f.close()
    -- Report the size written. Without it there is no way to tell whether a
    -- file on disk changed at all: a stale cache, a failed write and a
    -- genuine no-op all look the same from the outside.
    return #body
end

print("Installing Komanda X hub into /hub ...")
if not fs.exists("hub") then fs.makeDir("hub") end
if not fs.exists("hub/vendor") then fs.makeDir("hub/vendor") end

for _, relPath in ipairs(FILES) do
    local size = download(BASE_URL .. relPath, "hub/" .. relPath)
    print(("  %s  %d B"):format(relPath, size))
end

local startup = fs.open("startup.lua", "w")
startup.write('shell.run("hub/hub.lua")\n')
startup.close()

print("\nDone. Run 'hub/hub.lua' now, or reboot to auto-start it.")
