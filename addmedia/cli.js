#!/usr/bin/env node
/**
 * CC Media Uploader — unified music + video uploader for the Komanda X hub.
 *
 * First thing every run: pick a category, Music or Video. That choice is
 * the ONLY thing that decides which GitHub repos are touched — Music mode
 * only ever writes to your musicRepos list (songs.json + .dfpwm files),
 * Video mode only ever writes to your videoRepos list (videos.json +
 * .32vid chunk files). They never cross.
 *
 * Music mode reuses the exact addsong.js pipeline: search/paste a YouTube
 * URL -> yt-dlp -> ffmpeg -> dfpwm encode -> push to GitHub.
 *
 * Video mode takes a local video file directly (mp4 etc) and does the
 * WHOLE conversion in-process: ffmpeg splits it into fixed-length segments
 * (forcing a keyframe at each cut point, or the segment muxer silently
 * produces one giant "segment"), sanjuuni.exe converts each segment to a
 * .32vid chunk sized in *pixels* -- sanjuuni's -W/-H are pixel dimensions,
 * and each CC character cell is a 2x3 pixel block, so a 71x40 monitor
 * (minus 2 rows for the on-screen control bar) needs -W 142 -H 114 to fill
 * it -- then uploads the chunks + updates videos.json. No WSL, no manual
 * conversion step: everything here is a portable .exe fetched on first use,
 * same as yt-dlp/ffmpeg/deno already are for music.
 */

const fs = require("fs");
const path = require("path");
const os = require("os");
const readline = require("readline");
const https = require("https");
const { spawnSync } = require("child_process");
const dfpwm = require("dfpwm");
const AdmZip = require("adm-zip");
const tar = require("tar");

const BASE_DIR = process.pkg ? path.dirname(process.execPath) : __dirname;
const CONFIG_PATH = path.join(BASE_DIR, "config.json");
const TOOLS_DIR = path.join(BASE_DIR, "tools");
const YTDLP_PATH = path.join(TOOLS_DIR, "yt-dlp.exe");
const FFMPEG_PATH = path.join(TOOLS_DIR, "ffmpeg.exe");
const DENO_PATH = path.join(TOOLS_DIR, "deno.exe");
const SANJUUNI_DIR = path.join(TOOLS_DIR, "sanjuuni");
const SANJUUNI_PATH = path.join(SANJUUNI_DIR, "sanjuuni.exe");
const SANJUUNI_RELEASE_URL = "https://github.com/MCJack123/sanjuuni/releases/download/0.5/sanjuuni-Win64.zip";

// GitHub Contents API PUTs get unreliable well before GitHub's hard cap;
// warn loudly rather than silently failing on a huge video chunk.
const CHUNK_WARN_BYTES = 15 * 1024 * 1024;

// Matches hub/config.lua's MONITOR default (71x40 chars, 2 rows reserved
// for the video player's control bar) converted to sanjuuni's pixel units
// (2x3 px per CC character cell). Change these together with config.lua's
// MONITOR_TEXT_SCALE if you resize the monitor.
const DEFAULT_CHAR_WIDTH = 71;
const DEFAULT_CHAR_HEIGHT = 38; // 40 - 2 rows for the control bar
const DEFAULT_SEGMENT_SECONDS = 90;
// A CC:Tweaked monitor redraw is a full-screen mon.blit PLUS 16
// setPaletteColor calls, every single frame -- at a source video's native
// fps (30 for most YouTube content) that's an extreme render load,
// especially on a large multi-block monitor. Confirmed in-game: playing a
// 30fps video made the physical monitor go black and stay corrupted even
// across a reboot, only recoverable by breaking and replacing the block --
// a Minecraft/CC-side renderer overload, not a Lua bug. Capping the
// converted video's fps (most CC:Tweaked video projects use something in
// this range for exactly this reason) keeps the redraw rate sane.
const DEFAULT_FPS_CAP = 10;

function ask(question) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    return new Promise((resolve) => rl.question(question, (answer) => { rl.close(); resolve(answer.trim()); }));
}

function loadConfig() {
    if (fs.existsSync(CONFIG_PATH)) {
        try { return JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8")); } catch (e) { /* fall through */ }
    }
    return null;
}

function saveConfig(config) {
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
}

async function askRepoList(kind, defaults) {
    const repos = [];
    console.log(`\n${kind} repos (blank to accept the suggested default, or type your own list):`);
    let n = 1;
    while (true) {
        const suggestion = defaults[n - 1];
        const prompt = suggestion
            ? `  Repo #${n} [${suggestion}]: `
            : `  Repo #${n} (blank to stop adding): `;
        const answer = await ask(prompt);
        const repo = answer || suggestion;
        if (!repo) {
            if (repos.length === 0) continue;
            break;
        }
        repos.push({ label: `${kind} ${n}`, repo, branch: "main" });
        n++;
        if (!suggestion && repos.length >= 1) {
            const more = await ask("  Add another? (y/N): ");
            if (more.toLowerCase() !== "y") break;
        }
    }
    return repos;
}

async function firstTimeSetup() {
    console.log("=== First-time setup ===");
    console.log("Create a token at: https://github.com/settings/tokens -> Generate new token (classic)");
    console.log("Give it 'repo' scope (or fine-grained: Contents read/write on your repos).\n");

    const owner = await ask("GitHub username: ");
    const token = await ask("Personal Access Token: ");

    const musicRepos = await askRepoList("Music", ["cctwmusics", "cctwmusics2", "cctwmusics3"]);
    const videoRepos = await askRepoList("Video", ["KCTWM0", "KCTWM1"]);

    const config = { owner, token, musicRepos, videoRepos };
    saveConfig(config);
    console.log(`\nSaved config to ${CONFIG_PATH}\n`);
    return config;
}

async function pickRepo(repos, kind) {
    if (repos.length === 0) {
        throw new Error(`No ${kind} repos configured. Delete config.json and re-run to set up again.`);
    }
    if (repos.length === 1) return repos[0];

    console.log(`\nWhich ${kind} repo should this go to?`);
    repos.forEach((r, i) => console.log(`  ${i + 1}. ${r.label || r.repo} (${r.repo})`));
    const choice = (await ask(`Choose [1]: `)).trim();
    const idx = choice === "" ? 0 : (parseInt(choice, 10) - 1);
    if (isNaN(idx) || idx < 0 || idx >= repos.length) {
        console.log("Invalid choice, defaulting to the first one.");
        return repos[0];
    }
    return repos[idx];
}

function download(url, destPath, redirectCount = 0) {
    return new Promise((resolve, reject) => {
        if (redirectCount > 5) return reject(new Error("Too many redirects"));
        const file = fs.createWriteStream(destPath);
        https.get(url, { headers: { "User-Agent": "addmedia-cli" } }, (res) => {
            if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
                file.close();
                fs.unlinkSync(destPath);
                return resolve(download(res.headers.location, destPath, redirectCount + 1));
            }
            if (res.statusCode !== 200) {
                file.close();
                return reject(new Error(`Download failed: HTTP ${res.statusCode} for ${url}`));
            }
            res.pipe(file);
            file.on("finish", () => file.close(resolve));
        }).on("error", reject);
    });
}

async function ensureMusicTools() {
    if (!fs.existsSync(TOOLS_DIR)) fs.mkdirSync(TOOLS_DIR, { recursive: true });

    if (!fs.existsSync(YTDLP_PATH)) {
        console.log("Downloading yt-dlp.exe (one-time)...");
        await download("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe", YTDLP_PATH);
        console.log("yt-dlp.exe ready.");
    }

    if (!fs.existsSync(FFMPEG_PATH)) {
        console.log("Downloading ffmpeg.exe (one-time)...");
        const tmpTarball = path.join(TOOLS_DIR, "_ffmpeg_download.tgz");
        const tmpExtractDir = path.join(TOOLS_DIR, "_ffmpeg_extract");
        await download("https://registry.npmjs.org/@ffmpeg-installer/win32-x64/-/win32-x64-4.1.0.tgz", tmpTarball);
        if (fs.existsSync(tmpExtractDir)) fs.rmSync(tmpExtractDir, { recursive: true, force: true });
        fs.mkdirSync(tmpExtractDir, { recursive: true });
        await tar.x({ file: tmpTarball, cwd: tmpExtractDir });
        const extractedExe = path.join(tmpExtractDir, "package", "ffmpeg.exe");
        if (!fs.existsSync(extractedExe)) throw new Error("ffmpeg download succeeded but ffmpeg.exe wasn't found after extracting.");
        fs.copyFileSync(extractedExe, FFMPEG_PATH);
        fs.unlinkSync(tmpTarball);
        fs.rmSync(tmpExtractDir, { recursive: true, force: true });
        console.log("ffmpeg.exe ready.");
    }

    if (!fs.existsSync(DENO_PATH)) {
        console.log("Downloading deno.exe (one-time, needed by yt-dlp for YouTube)...");
        const tmpZip = path.join(TOOLS_DIR, "_deno_download.zip");
        await download("https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip", tmpZip);
        const zip = new AdmZip(tmpZip);
        zip.extractAllTo(TOOLS_DIR, true);
        fs.unlinkSync(tmpZip);
        if (!fs.existsSync(DENO_PATH)) throw new Error("Deno download succeeded but deno.exe wasn't found after extracting.");
        console.log("deno.exe ready.");
    }
}

function run(cmd, args) {
    console.log(">", path.basename(cmd), args.join(" "));
    const result = spawnSync(cmd, args, { encoding: "utf8" });
    if (result.error) throw result.error;
    if (result.status !== 0) {
        throw new Error(`${path.basename(cmd)} exited with code ${result.status}\n${result.stderr}`);
    }
    return result.stdout;
}

// Like run(), but doesn't throw on a non-zero exit -- ffmpeg exits non-zero
// when you run it with just -i and no output (that's how its own docs say
// to probe a file), but still prints the Duration/fps info we want to
// stderr either way.
function runCapture(cmd, args) {
    const result = spawnSync(cmd, args, { encoding: "utf8" });
    if (result.error) throw result.error;
    return { stdout: result.stdout || "", stderr: result.stderr || "", status: result.status };
}

async function ensureSanjuuni() {
    if (fs.existsSync(SANJUUNI_PATH)) return;
    if (!fs.existsSync(TOOLS_DIR)) fs.mkdirSync(TOOLS_DIR, { recursive: true });
    console.log("Downloading sanjuuni.exe (one-time, ~17MB, includes its own ffmpeg-family DLLs)...");
    const tmpZip = path.join(TOOLS_DIR, "_sanjuuni_download.zip");
    await download(SANJUUNI_RELEASE_URL, tmpZip);
    fs.mkdirSync(SANJUUNI_DIR, { recursive: true });
    const zip = new AdmZip(tmpZip);
    zip.extractAllTo(SANJUUNI_DIR, true);
    fs.unlinkSync(tmpZip);
    if (!fs.existsSync(SANJUUNI_PATH)) throw new Error("sanjuuni download succeeded but sanjuuni.exe wasn't found after extracting.");
    console.log("sanjuuni.exe ready.");
}

// Parses ffmpeg's stderr from a plain "ffmpeg -i <file>" probe call for the
// duration and the first video stream's frame rate. No ffprobe needed.
function probeVideo(inputPath) {
    const { stderr } = runCapture(FFMPEG_PATH, ["-i", inputPath]);
    const durationMatch = stderr.match(/Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/);
    const fpsMatch = stderr.match(/Stream #0:0[^\n]*?,\s*([\d.]+)\s*fps/) || stderr.match(/([\d.]+)\s*fps/);
    if (!durationMatch) throw new Error(`Couldn't read duration from ffmpeg output for ${inputPath}:\n${stderr}`);
    const durationSec = Math.round(
        parseInt(durationMatch[1], 10) * 3600 + parseInt(durationMatch[2], 10) * 60 + parseFloat(durationMatch[3])
    );
    const fps = fpsMatch ? Math.round(parseFloat(fpsMatch[1])) : 20;
    return { durationSec, fps: Math.max(1, Math.min(255, fps)) };
}

// Splits `inputPath` into ~segmentSeconds chunks and runs sanjuuni on each,
// producing `<workDir>/<baseName>0.32vid`, `<baseName>1.32vid`, ... Forces a
// keyframe at every intended cut point -- without that, ffmpeg's segment
// muxer can only cut at existing keyframes, which for a typical GOP length
// means it silently produces ONE giant "segment" covering the whole video
// (verified: this is not a hypothetical edge case, it's what happens by
// default). Returns { chunkCount, fps, durationSec }.
async function convertVideoLocally(inputPath, workDir, baseName, opts) {
    const { charWidth, charHeight, segmentSeconds } = opts;
    const pixelWidth = charWidth * 2;
    const pixelHeight = charHeight * 3;

    await ensureMusicTools(); // ffmpeg lives here already
    await ensureSanjuuni();

    console.log("Probing source video...");
    const { durationSec, fps: sourceFps } = probeVideo(inputPath);
    const fps = Math.min(sourceFps, DEFAULT_FPS_CAP);
    console.log(`  duration: ${durationSec}s, source fps: ${sourceFps} -> capped to ${fps}, output: ${pixelWidth}x${pixelHeight}px (${charWidth}x${charHeight} chars)`);

    fs.mkdirSync(workDir, { recursive: true });
    const segmentPattern = path.join(workDir, "seg_%04d.mp4");
    console.log(`Segmenting into ~${segmentSeconds}s parts at ${fps}fps...`);
    run(FFMPEG_PATH, [
        "-y", "-i", inputPath,
        "-r", String(fps),
        "-c:v", "libx264", "-preset", "veryfast",
        "-force_key_frames", `expr:gte(t,n_forced*${segmentSeconds})`,
        "-c:a", "aac", "-map", "0",
        "-f", "segment", "-segment_time", String(segmentSeconds), "-reset_timestamps", "1",
        segmentPattern,
    ]);

    // ffmpeg's segmenter can leave a near-empty trailing segment when the
    // video's duration doesn't divide evenly by segmentSeconds (e.g. a
    // fraction-of-a-second sliver right at the end). sanjuuni still
    // "successfully" converts that into a .32vid file with no actual video
    // stream in it, which doesn't fail here -- it fails LATER, in-game,
    // with "No video stream found" when the player tries to load that
    // chunk (confirmed: this happened with a real upload). Catch it here
    // instead, where it can just be dropped and logged.
    const MIN_SEGMENT_BYTES = 20 * 1024;
    const allSegments = fs.readdirSync(workDir).filter((f) => /^seg_\d+\.mp4$/.test(f)).sort();
    const segments = allSegments.filter((f) => {
        const size = fs.statSync(path.join(workDir, f)).size;
        if (size < MIN_SEGMENT_BYTES) {
            console.log(`  Skipping ${f} (${size} bytes) -- too small to be a real segment, likely an empty trailing sliver.`);
            fs.unlinkSync(path.join(workDir, f));
            return false;
        }
        return true;
    });
    if (segments.length === 0) throw new Error("ffmpeg produced no usable segments -- check the input file.");

    for (let i = 0; i < segments.length; i++) {
        console.log(`Converting chunk ${i + 1}/${segments.length} with sanjuuni...`);
        run(SANJUUNI_PATH, [
            "-i", path.join(workDir, segments[i]),
            "-o", path.join(workDir, `${baseName}${i}.32vid`),
            // sanjuuni.exe 0.5's -3 output is ALWAYS a single "Combined"
            // stream (Vid32Chunk::Type::Combined = 12, confirmed against
            // sanjuuni's own C++ source) with video+audio interleaved
            // frame-by-frame using an ANS entropy coder -- -S/
            // --separate-streams does NOT change this (verified: still
            // produces a Combined stream with -S), it only affects
            // splitting a -M multi-monitor image into per-monitor streams,
            // which isn't used here. The in-game decoder
            // (hub/vendor/32vid-decode.lua) is written specifically for
            // this Combined/ANS format, ported from sanjuuni's own
            // 32vid-player-mini.lua rather than the older 32vid-player.lua
            // (which expects separate Video=0/Audio=1 streams sanjuuni
            // 0.5 doesn't actually produce) -- see that file's header
            // comment for the full story.
            "-3", "-d",
            "-W", String(pixelWidth), "-H", String(pixelHeight),
        ]);
        fs.unlinkSync(path.join(workDir, segments[i]));
    }

    return { chunkCount: segments.length, fps, durationSec };
}

function isUrl(str) {
    return /^https?:\/\//i.test(str.trim());
}

function slugify(name) {
    return (name || "media")
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/(^-|-$)/g, "")
        .slice(0, 60) || "media";
}

// ==== GitHub Contents API helpers ====
function githubRequest(ctx, method, apiPath, body) {
    return new Promise((resolve, reject) => {
        const data = body ? JSON.stringify(body) : null;
        const req = https.request({
            hostname: "api.github.com",
            path: apiPath,
            method,
            headers: {
                "User-Agent": "addmedia-cli",
                "Authorization": `Bearer ${ctx.token}`,
                "Accept": "application/vnd.github+json",
                ...(data ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) } : {}),
            },
        }, (res) => {
            let chunks = [];
            res.on("data", (c) => chunks.push(c));
            res.on("end", () => {
                const raw = Buffer.concat(chunks).toString("utf8");
                let parsed = null;
                try { parsed = raw ? JSON.parse(raw) : null; } catch (e) { /* ignore */ }
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    resolve(parsed);
                } else if (res.statusCode === 404) {
                    resolve(null);
                } else {
                    reject(new Error(`GitHub API ${method} ${apiPath} -> HTTP ${res.statusCode}: ${raw}`));
                }
            });
        });
        req.on("error", reject);
        if (data) req.write(data);
        req.end();
    });
}

async function getFile(ctx, filePath) {
    return githubRequest(ctx, "GET", `/repos/${ctx.owner}/${ctx.repo}/contents/${filePath}?ref=${ctx.branch}`);
}

async function putFile(ctx, filePath, base64Content, message, sha) {
    return githubRequest(ctx, "PUT", `/repos/${ctx.owner}/${ctx.repo}/contents/${filePath}`, {
        message,
        content: base64Content,
        branch: ctx.branch,
        ...(sha ? { sha } : {}),
    });
}

async function deleteFile(ctx, filePath, message, sha) {
    return githubRequest(ctx, "DELETE", `/repos/${ctx.owner}/${ctx.repo}/contents/${filePath}`, {
        message,
        sha,
        branch: ctx.branch,
    });
}

async function loadManifest(ctx, manifestName) {
    const existing = await getFile(ctx, manifestName);
    let manifest = [];
    if (existing && existing.content) {
        try { manifest = JSON.parse(Buffer.from(existing.content, "base64").toString("utf8")); }
        catch (e) { manifest = []; }
    }
    return { manifest, existing };
}

// ==== Music (same as addsong.js) ====
async function addSongFlow(ctx) {
    const query = await ask("Song name or a direct video URL: ");
    if (!query) { console.log("Nothing entered, exiting."); return; }

    await ensureMusicTools();

    const tmpWav = path.join(os.tmpdir(), `addsong_${Date.now()}.wav`);
    const tmpRaw = path.join(os.tmpdir(), `addsong_${Date.now()}.raw`);
    const target = isUrl(query) ? query : `ytsearch1:${query}`;

    const jsRuntimeArgs = fs.existsSync(DENO_PATH) ? ["--js-runtimes", `deno:${DENO_PATH}`] : [];
    const clientArgs = ["--extractor-args", "youtube:player_client=android,ios,web"];

    console.log(`\nFetching: "${query}" ...`);
    run(YTDLP_PATH, ["-x", "--audio-format", "wav", "-o", tmpWav, "--no-simulate", ...jsRuntimeArgs, ...clientArgs, target]);
    const titleOut = run(YTDLP_PATH, ["--print", "title", ...jsRuntimeArgs, ...clientArgs, target]).trim();
    const detectedTitle = titleOut || query;

    if (!fs.existsSync(tmpWav)) throw new Error("Download failed: no output file produced.");

    const customName = await ask(`Name for your library [${detectedTitle}]: `);
    const title = customName || detectedTitle;

    console.log("Converting to raw PCM (48000Hz mono 8-bit signed)...");
    run(FFMPEG_PATH, ["-y", "-i", tmpWav, "-ar", "48000", "-ac", "1", "-f", "s8", tmpRaw]);

    console.log("Encoding to DFPWM...");
    const pcm = fs.readFileSync(tmpRaw);
    const encoded = dfpwm.quickEncode(pcm);

    const slug = slugify(title);
    const filename = `${slug}-${Date.now().toString(36)}.dfpwm`;
    const repoFilePath = `songs/${filename}`;

    console.log("Uploading song file to GitHub...");
    await putFile(ctx, repoFilePath, encoded.toString("base64"), `Add song: ${title}`);

    console.log("Updating songs.json...");
    const { manifest, existing } = await loadManifest(ctx, "songs.json");
    const rawUrl = `https://raw.githubusercontent.com/${ctx.owner}/${ctx.repo}/${ctx.branch}/${repoFilePath}`;
    manifest.push({ name: title, url: rawUrl });
    await putFile(ctx, "songs.json", Buffer.from(JSON.stringify(manifest, null, 2)).toString("base64"),
        `Update songs.json: add ${title}`, existing ? existing.sha : undefined);

    for (const f of [tmpWav, tmpRaw]) { if (fs.existsSync(f)) fs.unlinkSync(f); }

    console.log(`\nDone! "${title}" is now live in your repo.`);
    console.log("Press F5 in-game to refresh the song list.");
}

async function deleteSongFlow(ctx) {
    console.log("\nFetching your library...");
    const { manifest, existing } = await loadManifest(ctx, "songs.json");
    if (manifest.length === 0) { console.log("Your library is empty — nothing to delete."); return; }

    console.log("\nYour library:");
    manifest.forEach((s, i) => console.log(`  ${i + 1}. ${s.name}`));

    const choice = await ask("\nNumber to delete (blank to cancel): ");
    const idx = parseInt(choice, 10) - 1;
    if (choice.trim() === "" || isNaN(idx) || idx < 0 || idx >= manifest.length) { console.log("Cancelled."); return; }

    const song = manifest[idx];
    const confirm = await ask(`Delete "${song.name}"? This cannot be undone. (y/N): `);
    if (confirm.toLowerCase() !== "y") { console.log("Cancelled."); return; }

    const prefix = `https://raw.githubusercontent.com/${ctx.owner}/${ctx.repo}/${ctx.branch}/`;
    const filePath = song.url.startsWith(prefix) ? song.url.slice(prefix.length) : null;

    if (filePath) {
        const fileInfo = await getFile(ctx, filePath);
        if (fileInfo && fileInfo.sha) {
            console.log("Deleting song file from GitHub...");
            await deleteFile(ctx, filePath, `Delete song: ${song.name}`, fileInfo.sha);
        }
    }

    manifest.splice(idx, 1);
    console.log("Updating songs.json...");
    await putFile(ctx, "songs.json", Buffer.from(JSON.stringify(manifest, null, 2)).toString("base64"),
        `Remove song: ${song.name}`, existing.sha);

    console.log(`\nDone! "${song.name}" removed from your library.`);
}

// ==== Video ====
async function addVideoFlow(ctx) {
    // Same source as addSongFlow -- a search term or a direct URL, fetched
    // with yt-dlp -- not a local file. Video mode never touches the music
    // repos regardless of where the source came from; that separation is
    // enforced by which repo `ctx` points at (chosen in videoCategory()
    // below), not by the download source.
    const query = await ask("Video name or a direct video URL: ");
    if (!query) { console.log("Nothing entered, exiting."); return; }

    await ensureMusicTools(); // yt-dlp/ffmpeg/deno live here already

    const target = isUrl(query) ? query : `ytsearch1:${query}`;
    const jsRuntimeArgs = fs.existsSync(DENO_PATH) ? ["--js-runtimes", `deno:${DENO_PATH}`] : [];
    const clientArgs = ["--extractor-args", "youtube:player_client=android,ios,web"];

    const tmpVideo = path.join(os.tmpdir(), `addmedia_video_${Date.now()}.mp4`);

    console.log(`\nFetching: "${query}" ...`);
    run(YTDLP_PATH, [
        "-f", "bv*+ba/b", "--merge-output-format", "mp4",
        "-o", tmpVideo, "--no-simulate",
        ...jsRuntimeArgs, ...clientArgs, target,
    ]);
    const titleOut = run(YTDLP_PATH, ["--print", "title", ...jsRuntimeArgs, ...clientArgs, target]).trim();
    const detectedTitle = titleOut || query;

    if (!fs.existsSync(tmpVideo)) throw new Error("Download failed: no output file produced.");

    // Only the name is still asked -- size and segment length always use
    // the fixed defaults now (DEFAULT_CHAR_WIDTH/HEIGHT,
    // DEFAULT_SEGMENT_SECONDS at the top of this file). Chunking for a
    // long video is still fully automatic regardless -- convertVideoLocally
    // just produces however many segments the video needs at that segment
    // length, whether that's 1 or 20.
    const customName = await ask(`Name for your library [${detectedTitle}]: `);
    const title = customName || detectedTitle;
    const slug = slugify(title);
    const charWidth = DEFAULT_CHAR_WIDTH, charHeight = DEFAULT_CHAR_HEIGHT;
    const segmentSeconds = DEFAULT_SEGMENT_SECONDS;
    console.log(`Name: ${title}  |  Size: ${charWidth}x${charHeight}  |  Segment: ${segmentSeconds}s`);

    const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "addmedia_video_"));
    let chunkCount, fps, durationSec;
    try {
        ({ chunkCount, fps, durationSec } = await convertVideoLocally(tmpVideo, workDir, slug, { charWidth, charHeight, segmentSeconds }));

        const chunkUrls = [];
        for (let i = 0; i < chunkCount; i++) {
            const chunkFile = path.join(workDir, `${slug}${i}.32vid`);
            const buf = fs.readFileSync(chunkFile);
            if (buf.length > CHUNK_WARN_BYTES) {
                console.log(`  WARNING: chunk ${i} is ${(buf.length / 1024 / 1024).toFixed(1)}MB — GitHub's Contents API can be ` +
                    `flaky above ~15-20MB per file. Consider a shorter segment length if this upload fails.`);
            }

            const repoFilePath = `videos/${slug}/${slug}${i}.32vid`;
            console.log(`Uploading chunk ${i + 1}/${chunkCount} (${(buf.length / 1024).toFixed(0)}KB)...`);
            await putFile(ctx, repoFilePath, buf.toString("base64"), `Add video: ${title} (part ${i})`);
            chunkUrls.push(`https://raw.githubusercontent.com/${ctx.owner}/${ctx.repo}/${ctx.branch}/${repoFilePath}`);
        }

        console.log("Updating videos.json...");
        const { manifest, existing } = await loadManifest(ctx, "videos.json");
        manifest.push({
            name: title,
            chunks: chunkUrls,
            width: charWidth,
            height: charHeight,
            fps,
            durationSec,
        });
        await putFile(ctx, "videos.json", Buffer.from(JSON.stringify(manifest, null, 2)).toString("base64"),
            `Update videos.json: add ${title}`, existing ? existing.sha : undefined);

        console.log(`\nDone! "${title}" (${chunkCount} chunk(s), ${durationSec}s) is now live in your repo.`);
    } finally {
        fs.rmSync(workDir, { recursive: true, force: true });
        if (fs.existsSync(tmpVideo)) fs.unlinkSync(tmpVideo);
    }
}

async function deleteVideoFlow(ctx) {
    console.log("\nFetching your library...");
    const { manifest, existing } = await loadManifest(ctx, "videos.json");
    if (manifest.length === 0) { console.log("Your library is empty — nothing to delete."); return; }

    console.log("\nYour library:");
    manifest.forEach((v, i) => console.log(`  ${i + 1}. ${v.name} (${v.chunks.length} chunk(s))`));

    const choice = await ask("\nNumber to delete (blank to cancel): ");
    const idx = parseInt(choice, 10) - 1;
    if (choice.trim() === "" || isNaN(idx) || idx < 0 || idx >= manifest.length) { console.log("Cancelled."); return; }

    const video = manifest[idx];
    const confirm = await ask(`Delete "${video.name}" and all ${video.chunks.length} chunk file(s)? (y/N): `);
    if (confirm.toLowerCase() !== "y") { console.log("Cancelled."); return; }

    const prefix = `https://raw.githubusercontent.com/${ctx.owner}/${ctx.repo}/${ctx.branch}/`;
    for (const url of video.chunks) {
        const filePath = url.startsWith(prefix) ? url.slice(prefix.length) : null;
        if (filePath) {
            const fileInfo = await getFile(ctx, filePath);
            if (fileInfo && fileInfo.sha) {
                console.log(`Deleting ${filePath}...`);
                await deleteFile(ctx, filePath, `Delete video: ${video.name}`, fileInfo.sha);
            }
        }
    }

    manifest.splice(idx, 1);
    console.log("Updating videos.json...");
    await putFile(ctx, "videos.json", Buffer.from(JSON.stringify(manifest, null, 2)).toString("base64"),
        `Remove video: ${video.name}`, existing.sha);

    console.log(`\nDone! "${video.name}" removed from your library.`);
}

async function musicCategory(config) {
    const repoConfig = await pickRepo(config.musicRepos, "music");
    const ctx = { owner: config.owner, token: config.token, repo: repoConfig.repo, branch: repoConfig.branch };
    console.log("\n1. Add a song\n2. Delete a song");
    const choice = (await ask("Choose [1]: ")).trim();
    if (choice === "2") await deleteSongFlow(ctx);
    else await addSongFlow(ctx);
}

async function videoCategory(config) {
    const repoConfig = await pickRepo(config.videoRepos, "video");
    const ctx = { owner: config.owner, token: config.token, repo: repoConfig.repo, branch: repoConfig.branch };
    console.log("\n1. Add a video\n2. Delete a video");
    const choice = (await ask("Choose [1]: ")).trim();
    if (choice === "2") await deleteVideoFlow(ctx);
    else await addVideoFlow(ctx);
}

async function main() {
    console.log("=== CC Media Uploader (Komanda X) ===\n");

    let config = loadConfig();
    if (!config) config = await firstTimeSetup();

    while (true) {
        console.log("\nCategory:\n  1. Music\n  2. Video");
        const category = (await ask("Choose [1]: ")).trim();

        if (category === "2") await videoCategory(config);
        else await musicCategory(config);

        const again = await ask("\nDo another? (y/N): ");
        if (again.toLowerCase() !== "y") break;
    }

    console.log("\nAll done!");
}

main().catch((err) => {
    console.error("\nFailed:", err.message || err);
    process.exitCode = 1;
});
