#!/usr/bin/env node
/**
 * Music Uploader — standalone tool.
 *
 * First run: asks for your GitHub username, repo name, branch, and a
 * Personal Access Token (with "repo" or "Contents: read/write" permission).
 * Saves that into config.json next to the exe so you only enter it once.
 *
 * Every run: type a song name -> it searches YouTube, downloads audio,
 * converts + encodes to DFPWM, and uploads the file + updated songs.json
 * straight to your GitHub repo via the GitHub API (no git required).
 *
 * yt-dlp.exe and ffmpeg.exe are downloaded automatically into a local
 * "tools" folder next to the exe the first time they're needed, if not
 * already present.
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

// When run via `pkg`, process.execPath is the exe itself; keep all files
// (config, tools, temp) next to it rather than inside the packaged snapshot.
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
    console.log("You need a GitHub repo to store songs in, and a Personal Access Token.");
    console.log("Create a token at: https://github.com/settings/tokens -> Generate new token (classic)");
    console.log("Give it 'repo' scope (or fine-grained: Contents read/write on your repo(s)).\n");

    const owner = await ask("GitHub username: ");
    const token = await ask("Personal Access Token: ");

    const repos = [];
    let n = 1;
    while (true) {
        const repo = await ask(n === 1
            ? "Repo name (e.g. cc-music): "
            : `Repo name for library #${n} (blank to stop adding repos): `);
        if (!repo) {
            if (repos.length === 0) continue; // need at least one
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

// Accepts both the old single-repo config shape ({owner, repo, branch, token})
// and the newer multi-repo shape ({owner, token, repos: [{label, repo, branch}]})
// so existing config.json files (or ones hand-edited by the user) keep working.
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

async function deleteFile(config, filePath, message, sha) {
    return githubRequest(config, "DELETE", `/repos/${config.owner}/${config.repo}/contents/${filePath}`, {
        message,
        sha,
        branch: config.branch,
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

    // Accept either a direct URL (YouTube or anything yt-dlp supports) or a
    // plain search term, in which case we search YouTube for the top result.
    const target = isUrl(query) ? query : `ytsearch1:${query}`;

    const jsRuntimeArgs = fs.existsSync(DENO_PATH) ? ["--js-runtimes", `deno:${DENO_PATH}`] : [];
    // Default "web" client frequently gets HTTP 403'd by YouTube's anti-bot
    // checks. The android/ios clients usually aren't gated the same way.
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

    console.log(`\nDone! "${title}" is now live in your repo.`);
    console.log("Press F5 in-game to refresh the song list.");
}

async function deleteSongFlow(config) {
    console.log("\nFetching your library...");
    const { manifest, existing } = await loadManifest(config);

    if (manifest.length === 0) {
        console.log("Your library is empty — nothing to delete.");
        return;
    }

    console.log("\nYour library:");
    manifest.forEach((s, i) => console.log(`  ${i + 1}. ${s.name}`));

    const choice = await ask("\nNumber to delete (blank to cancel): ");
    const idx = parseInt(choice, 10) - 1;
    if (choice.trim() === "" || isNaN(idx) || idx < 0 || idx >= manifest.length) {
        console.log("Cancelled.");
        return;
    }

    const song = manifest[idx];
    const confirm = await ask(`Delete "${song.name}"? This cannot be undone. (y/N): `);
    if (confirm.trim().toLowerCase() !== "y") {
        console.log("Cancelled.");
        return;
    }

    // Work out the repo-relative file path from the song's raw URL so we
    // can delete the actual .dfpwm file, not just its manifest entry.
    const prefix = `https://raw.githubusercontent.com/${config.owner}/${config.repo}/${config.branch}/`;
    const filePath = song.url.startsWith(prefix) ? song.url.slice(prefix.length) : null;

    if (filePath) {
        const fileInfo = await getFile(config, filePath);
        if (fileInfo && fileInfo.sha) {
            console.log("Deleting song file from GitHub...");
            await deleteFile(config, filePath, `Delete song: ${song.name}`, fileInfo.sha);
        } else {
            console.log("Note: the file was already missing on GitHub, removing it from the library listing only.");
        }
    } else {
        console.log("Note: couldn't work out the file's path from its URL, removing it from the library listing only.");
    }

    manifest.splice(idx, 1);
    console.log("Updating songs.json...");
    await putFile(
        config,
        "songs.json",
        Buffer.from(JSON.stringify(manifest, null, 2)).toString("base64"),
        `Remove song: ${song.name}`,
        existing.sha
    );

    console.log(`\nDone! "${song.name}" removed from your library.`);
    console.log("Press F5 in-game to refresh the song list.");
}

async function main() {
    console.log("=== CC Music Uploader ===\n");

    let config = loadConfig();
    if (!config) {
        config = await firstTimeSetup();
    } else {
        config = normalizeConfig(config);
    }

    // Loops so you can add/delete several songs in one run instead of having
    // to re-launch run.bat every single time.
    while (true) {
        console.log("1. Add a song");
        console.log("2. Delete a song");
        const choice = (await ask("\nChoose [1]: ")).trim();

        const repoConfig = await pickRepo(config);
        // ctx merges the shared account-level fields with the chosen repo's
        // fields, in the same {owner, token, repo, branch} shape the GitHub
        // API helpers below already expect.
        const ctx = { owner: config.owner, token: config.token, repo: repoConfig.repo, branch: repoConfig.branch };

        if (choice === "2") {
            await deleteSongFlow(ctx);
        } else {
            await addSongFlow(ctx);
        }

        const again = await ask("\nDo another? (y/N): ");
        if (again.trim().toLowerCase() !== "y") break;
        console.log("");
    }

    console.log("\nAll done!");
}

main().catch((err) => {
    console.error("\nFailed:", err.message || err);
    process.exitCode = 1;
});
