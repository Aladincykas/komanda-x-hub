#!/usr/bin/env node
/**
 * Music Uploader — ADD-ONLY variant for friends.
 * (Full version with delete is cli.js — this one has no delete capability
 * at all, not even hidden behind a menu, so it's safe to hand out.)
 *
 * First run: asks for the GitHub username, repo name, branch, and a shared
 * Personal Access Token (with "Contents: read/write" permission on that one
 * repo only). Saves that into config.json next to this file.
 *
 * Every run: type a song name or URL -> it searches YouTube, downloads
 * audio, converts + encodes to DFPWM, and uploads the file + updated
 * songs.json straight to the shared GitHub repo via the GitHub API.
 *
 * yt-dlp.exe, ffmpeg.exe, and deno.exe are downloaded automatically into a
 * local "tools" folder next to this file the first time they're needed.
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

async function firstTimeSetup() {
    console.log("=== First-time setup ===");
    console.log("Enter the repo owner's info and the shared token they gave you.");
    console.log("If they gave you more than one repo (multiple libraries), add them all here.\n");

    const owner = await ask("GitHub username (the repo owner): ");
    const token = await ask("Shared Personal Access Token: ");

    const repos = [];
    let n = 1;
    while (true) {
        const repo = await ask(n === 1
            ? "Repo name: "
            : `Repo name for library #${n} (blank to stop adding repos): `);
        if (!repo) {
            if (repos.length === 0) continue;
            break;
        }
        const branch = (await ask("Branch [main]: ")) || "main";
        repos.push({ label: `Library ${n}`, repo, branch });
        n++;
        const more = await ask("Add another repo? (y/N): ");
        if (more.trim().toLowerCase() !== "y") break;
    }

    const config = { owner, token, repos };
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
    console.log(`Saved config to ${CONFIG_PATH}\n`);
    return config;
}

// Accepts both the old single-repo config shape and the newer multi-repo
// shape, so an existing config.json keeps working.
function normalizeConfig(config) {
    if (Array.isArray(config.repos) && config.repos.length > 0) {
        return config;
    }
    if (config.repo) {
        return {
            owner: config.owner,
            token: config.token,
            repos: [{ label: "Library 1", repo: config.repo, branch: config.branch || "main" }],
        };
    }
    return config;
}

async function pickRepo(config) {
    const repos = config.repos || [];
    if (repos.length === 0) {
        throw new Error("No repos configured in config.json. Delete config.json and re-run to set up again.");
    }
    if (repos.length === 1) {
        return repos[0];
    }

    console.log("\nWhich library (repo) should this go to?");
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
        https.get(url, { headers: { "User-Agent": "addsong-cli" } }, (res) => {
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

async function ensureTools() {
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

function isUrl(str) {
    return /^https?:\/\//i.test(str.trim());
}

function slugify(name) {
    return (name || "song")
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/(^-|-$)/g, "")
        .slice(0, 60) || "song";
}

// ==== GitHub Contents API helpers ====
// Note: intentionally no deleteFile() here — this variant can only add.
function githubRequest(config, method, apiPath, body) {
    return new Promise((resolve, reject) => {
        const data = body ? JSON.stringify(body) : null;
        const req = https.request({
            hostname: "api.github.com",
            path: apiPath,
            method,
            headers: {
                "User-Agent": "addsong-cli",
                "Authorization": `Bearer ${config.token}`,
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
                    resolve(null); // file doesn't exist yet
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

async function getFile(config, filePath) {
    return githubRequest(config, "GET", `/repos/${config.owner}/${config.repo}/contents/${filePath}?ref=${config.branch}`);
}

async function putFile(config, filePath, base64Content, message, sha) {
    return githubRequest(config, "PUT", `/repos/${config.owner}/${config.repo}/contents/${filePath}`, {
        message,
        content: base64Content,
        branch: config.branch,
        ...(sha ? { sha } : {}),
    });
}

async function loadManifest(config) {
    const existing = await getFile(config, "songs.json");
    let manifest = [];
    if (existing && existing.content) {
        try { manifest = JSON.parse(Buffer.from(existing.content, "base64").toString("utf8")); }
        catch (e) { manifest = []; }
    }
    return { manifest, existing };
}

async function addSongFlow(config) {
    const query = process.argv.slice(2).join(" ").trim() || await ask("Song name or a direct video URL: ");
    if (!query) {
        console.log("Nothing entered, exiting.");
        return;
    }

    await ensureTools();

    const tmpWav = path.join(os.tmpdir(), `addsong_${Date.now()}.wav`);
    const tmpRaw = path.join(os.tmpdir(), `addsong_${Date.now()}.raw`);

    const target = isUrl(query) ? query : `ytsearch1:${query}`;

    const jsRuntimeArgs = fs.existsSync(DENO_PATH) ? ["--js-runtimes", `deno:${DENO_PATH}`] : [];
    const clientArgs = ["--extractor-args", "youtube:player_client=android,ios,web"];

    console.log(`\nFetching: "${query}" ...`);
    run(YTDLP_PATH, [
        "-x", "--audio-format", "wav",
        "-o", tmpWav,
        "--no-simulate",
        ...jsRuntimeArgs,
        ...clientArgs,
        target,
    ]);
    const titleOut = run(YTDLP_PATH, ["--print", "title", ...jsRuntimeArgs, ...clientArgs, target]).trim();
    const detectedTitle = titleOut || query;

    if (!fs.existsSync(tmpWav)) throw new Error("Download failed: no output file produced.");

    const customName = await ask(`Name for the library [${detectedTitle}]: `);
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
    await putFile(config, repoFilePath, encoded.toString("base64"), `Add song: ${title}`);

    console.log("Updating songs.json...");
    const { manifest, existing } = await loadManifest(config);
    const rawUrl = `https://raw.githubusercontent.com/${config.owner}/${config.repo}/${config.branch}/${repoFilePath}`;
    manifest.push({ name: title, url: rawUrl });
    await putFile(
        config,
        "songs.json",
        Buffer.from(JSON.stringify(manifest, null, 2)).toString("base64"),
        `Update songs.json: add ${title}`,
        existing ? existing.sha : undefined
    );

    for (const f of [tmpWav, tmpRaw]) { if (fs.existsSync(f)) fs.unlinkSync(f); }

    console.log(`\nDone! "${title}" is now live in the library.`);
    console.log("Press F5 in-game to refresh the song list.");
}

async function main() {
    console.log("=== Music Uploader (add-only) ===\n");

    let config = loadConfig();
    if (!config) {
        config = await firstTimeSetup();
    } else {
        config = normalizeConfig(config);
    }

    // Loops so you can add several songs in one run instead of having to
    // re-launch run.bat every single time.
    while (true) {
        const repoConfig = await pickRepo(config);
        const ctx = { owner: config.owner, token: config.token, repo: repoConfig.repo, branch: repoConfig.branch };

        await addSongFlow(ctx);

        const again = await ask("\nAdd another song? (y/N): ");
        if (again.trim().toLowerCase() !== "y") break;
        console.log("");
    }

    console.log("\nAll done!");
}

main().catch((err) => {
    console.error("\nFailed:", err.message || err);
    process.exitCode = 1;
});
