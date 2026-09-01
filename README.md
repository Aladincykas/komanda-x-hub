# CC:Tweaked GitHub Jukebox — how it works

## The problem this solves
CC:Tweaked's `http` API is locked down by the Minecraft server to an allowlist
of domains (`http.rules` in the server config). Most hosts — including
Firebase — aren't on it. The only realistic free option that usually *is*
allowed: `github.com`, `github.io`, `githubusercontent.com`, `gitlab.com`.

## The architecture
1. **PC-side uploader** (`cli.js`, Node.js): you type a song name or paste a
   YouTube URL. It downloads audio with `yt-dlp`, converts to raw PCM with
   `ffmpeg`, encodes to DFPWM (CC:Tweaked's native speaker format) with the
   `dfpwm` npm package, and pushes the `.dfpwm` file plus an updated
   `songs.json` manifest straight to a GitHub repo via the GitHub Contents
   API (no local git needed, just HTTPS calls with a token).
2. **GitHub repo**: just static file hosting. `songs.json` is a flat JSON
   array of `{ name, url }`, where `url` points at
   `raw.githubusercontent.com/<user>/<repo>/<branch>/songs/<file>.dfpwm`.
3. **In-game player** (`music.lua`, CC:Tweaked Lua): fetches `songs.json`
   from every configured repo, merges them into one library, and streams the
   `.dfpwm` audio straight from `raw.githubusercontent.com` into
   `cc.audio.dfpwm`'s decoder and then the speaker peripheral — nothing is
   ever written to disk in-game.

Multiple GitHub repos are supported (GitHub has per-repo size limits, so
once one fills up you just spin up another and add it to the list) and get
merged transparently into one library.

## Key technical details worth remembering for a similar project
- **DFPWM** = CC:Tweaked's native 1-bit-per-sample audio codec. Encode from
  48000Hz mono 8-bit signed PCM. Byte rate is a fixed 6000 bytes/sec, so
  `elapsed_seconds = bytesStreamed / 6000` — handy for a progress bar with
  zero extra bookkeeping.
- **`dfpwm` npm package** (by the actual CC:Tweaked audio codec author) is
  the correct PC-side encoder — verified via round-trip decode test.
  `cc.audio.dfpwm` is the built-in in-game decoder.
- **GitHub Contents API** (`api.github.com/repos/{owner}/{repo}/contents/{path}`)
  does file create/update/delete via plain PUT/DELETE with base64 content —
  no git binary needed on the uploader's machine. Recommended only for files
  under ~1MB each (a 3-4 min song lands around 1-1.3MB as DFPWM, right at
  the edge — fine in practice).
- **`raw.githubusercontent.com` CDN caching**: serves a stale copy for a few
  minutes after a file changes. Fix: append a cache-busting query string
  (`?t=<timestamp>`) to every fetch.
- **`term.blit(text, fgColors, bgColors)`**: CC:Tweaked's single-call way to
  draw a whole line of colored text. Massively faster than looping
  `setCursorPos`/`setTextColor`/`setBackgroundColor`/`write` per character —
  this was the fix for "laggy" UI complaints.
- **Fine-grained GitHub PATs** scoped to "Contents: Read and write" on one
  repo only are the safe way to hand upload access to other people, without
  giving them your whole account. Pair with a genuinely add-only client
  script (no delete function present in the code at all, not just hidden)
  if you don't trust them not to nuke the library.
- **Distributing the Node.js tool without requiring a manual Node install**:
  bundle `node_modules` directly instead of relying on `npm install` (avoids
  every possible broken-npm-on-their-PC issue), and have the `.bat` launcher
  auto-download a portable Node.js zip from nodejs.org if `node` isn't found
  on PATH at all. No compiled `.exe` needed anywhere, so the whole thing
  stays plain, readable source — good if you or your users are wary of
  running an unreadable binary.
- **yt-dlp anti-bot workarounds**: `--extractor-args "youtube:player_client=android,ios,web"`
  fixes HTTP 403s; `--js-runtimes deno:<path-to-deno.exe>` fixes the
  "no supported JavaScript runtime" warning. Both yt-dlp and a portable Deno
  can be auto-downloaded on first run so there's no manual setup at all.

## Files in this bundle
- `music.lua` — the in-game player. Edit `GITHUB_USER` and the `LIBRARIES`
  table at the top to point at your own repo(s).
- `addsong/` — the full uploader (search or paste a URL, add or delete
  songs, choose which repo). This is *your* copy.
- `addsong-friends/` — an add-only variant with zero delete capability, safe
  to hand to other people alongside a scoped-down GitHub token.
- Each uploader folder has `cli.js`, `package.json`, and `run.bat`
  (double-click to run on Windows; auto-installs Node if missing).

## Adapting this for a new project
The GitHub-as-CDN + domain-allowlist workaround is the reusable part — swap
DFPWM/speaker for whatever asset type your new CC:Tweaked project streams
(images, text, structured data, etc.), keep the same upload-to-GitHub /
fetch-raw-from-GitHub pattern, and reuse the `term.blit` UI approach for
anything that redraws often.

---

## Komanda X: the monitor media hub (hub/, addmedia/)

This extends the same GitHub-CDN pattern from a Pocket Computer jukebox into
a full monitor-based hub: a Basalt-driven main menu with a matrix-rain
background and looping menu music, a video player, and the jukebox resized
for a monitor. See the full design writeup in the plan this was built from
if you want the reasoning; this section is just setup steps.

### 1. In-game: install the hub
`hub/` is the Lua bundle that runs on the Computer wired to your monitor and
speakers. To get it in-game, push this repo's `hub/` folder to its own
public GitHub repo, edit `HUB_REPO` at the top of `hub/install.lua` to match,
then in-game:
```
wget run https://raw.githubusercontent.com/<you>/<hub-repo>/main/install.lua
```
This drops everything into `/hub`, installs Basalt 2.5 alongside it
(`wget run https://basalt.madefor.cc/2.5/install.lua minified`), and sets a
`startup.lua` that runs the hub on boot. (Alternatively, just copy the
`hub/` folder directly into the computer's save-folder from Windows
Explorer if you'd rather not host the Lua source on GitHub at all — you'd
still need to run the Basalt installer once in-game yourself in that case.)

Edit `hub/config.lua` (in-game or before uploading) for:
- `MONITOR_NAME` / `MONITOR_TEXT_SCALE` — tune the scale until
  `monitor.getSize()` reports 71 x 40.
- `MENU_MUSIC_NAME` — the exact song name (from your music library) to loop
  on the main menu, once you've picked one.
- `MUSIC_LIBRARIES` / `VIDEO_LIBRARIES` — already pointed at your existing
  3 music repos and the `KCTWM0`/`KCTWM1` video repos; add more the same way.

**Basalt:** the main menu buttons and the video-selection list are real
Basalt 2.5 elements (`basalt.createFrame():setTerm(monitor)`, `addButton`,
`addList`). The matrix background and the looping menu music run as
`basalt.schedule()` background coroutines while `basalt.run()` drives the
menu, and a button's `onClick` calls `basalt.stop()` to hand control back
to `hub.lua`'s own state machine — that's the run()/stop()/schedule()
contract straight from Basalt's docs. `musicplayer.lua` was deliberately
left on its own raw `term.blit` UI (ported near-verbatim from your working
`music.lua`) rather than rebuilt on Basalt too, since there was nothing to
gain from redoing an already-proven screen.

### 2. PC: convert + upload a video (no installs beyond addmedia itself)
sanjuuni ships a real portable Windows build (`sanjuuni.exe` + its DLLs, no
installer) — confirmed by actually running it here — so there's no WSL, no
Linux build, nothing that needs a restart. `addmedia` downloads it
automatically on first video use, the same way it already auto-downloads
yt-dlp/ffmpeg/deno for music.

Just run `addmedia/run.bat`, choose **Video** → **Add a video**, and point
it straight at a local video file (mp4, mkv, whatever). It handles the
whole pipeline itself: probes duration/fps, splits into segments with
ffmpeg (forcing a keyframe at every cut point — without that the segment
muxer silently produces one giant segment instead of several, which was
caught by testing this end-to-end before shipping it), converts each
segment with sanjuuni.exe, uploads the chunks, and updates `videos.json` in
whichever of `KCTWM0`/`KCTWM1` you pick. It never touches the music repos.

Two things worth knowing about the conversion:
- sanjuuni's `-W`/`-H` are **pixel** dimensions, not character dimensions —
  each CC character cell is a 2x3 pixel block. `addmedia` does this math
  for you from the character size you give it (default 71x38, i.e. your
  71x40 monitor minus 2 rows for the control bar) — you shouldn't need to
  touch pixel sizes directly.
- Segment length defaults to 90s; shorter segments mean more (but smaller,
  and shorter-loading-pause) chunks.

`addmedia` replaces `addsong`/`addsong-friends` for new uploads (same
underlying pipeline for music, plus the new video path); the old tools
still work if you prefer keeping them separate.

### Known limits worth knowing about
- Each `.32vid` chunk is decoded fully into memory before it starts
  playing, so there's a brief loading pause at every chunk boundary (this
  matches how the upstream sanjuuni player works, not something patched
  around here) — a shorter segment length in `addmedia` means shorter
  pauses but more of them.
- GitHub's Contents API gets unreliable well before its hard size limit;
  `addmedia` warns if a chunk is over ~15MB. If uploads start failing,
  use a shorter segment length or a smaller character size.
