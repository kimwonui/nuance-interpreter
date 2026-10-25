// Static checks for the NUA site (no dependencies): JS syntax, links and assets, no network/mic/audio
// code, video rules (no sound without a click, lazy loading, size budgets), what gets published,
// the 14-language list, and copy rules (no fake download/sign-up, required honesty labels).
//   node scripts/check.mjs
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const failures = [];
const ok = (msg) => console.log("  ok  " + msg);
const fail = (msg) => { failures.push(msg); console.log("  FAIL " + msg); };

const html = readFileSync(join(root, "index.html"), "utf8");
const jsDir = join(root, "assets/js");
const jsFiles = readdirSync(jsDir).filter((f) => f.endsWith(".js")).map((f) => join(jsDir, f));
const scripts = readdirSync(join(root, "scripts")).filter((f) => f.endsWith(".mjs")).map((f) => join(root, "scripts", f));
const js = jsFiles.map((f) => readFileSync(f, "utf8")).join("\n");

// 1. JS syntax
for (const f of [...jsFiles, ...scripts]) {
  const r = spawnSync(process.execPath, ["--check", f], { encoding: "utf8" });
  if (r.status === 0) ok("syntax " + f.slice(root.length + 1));
  else fail("syntax " + f.slice(root.length + 1) + "\n" + r.stderr);
}

// 2. In-page anchors and local assets
const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
for (const [, id] of html.matchAll(/href="#([^"]*)"/g)) {
  if (!ids.has(id)) fail(`anchor #${id} has no target`);
}
ok(`anchors resolve (${ids.size} ids)`);
const refs = [...html.matchAll(/\s(?:src|href|data-src-sm|data-src-lg|data-poster)="([^"#][^"]*)"/g)].map((m) => m[1]);
for (const [, set] of html.matchAll(/\ssrcset="([^"]+)"/g)) refs.push(...set.split(",").map((c) => c.trim().split(/\s+/)[0]));
for (const ref of refs) {
  if (/^https?:/.test(ref)) {
    if (!/^https:\/\/fonts\.(googleapis|gstatic)\.com/.test(ref)) fail("unexpected external URL: " + ref);
    continue;
  }
  if (!existsSync(join(root, ref))) fail("missing asset: " + ref);
}
ok(`local assets exist (${refs.length} refs); only Google Fonts is external`);

// 3. The demo never touches the network, microphone or speakers
const banned = [/\bfetch\s*\(/, /XMLHttpRequest/, /WebSocket/, /getUserMedia/, /new\s+Audio\s*\(/, /AudioContext/, /speechSynthesis/, /sendBeacon/];
for (const re of banned) if (re.test(js)) fail("site JS must not use " + re);
ok("no network, microphone or audio APIs in site JS");

// 3b. Video: nothing autoplays with sound, nothing downloads before it's needed
const videos = [...html.matchAll(/<video\b([^>]*)>/g)].map((m) => m[1]);
if (videos.length !== 2) fail(`expected 2 videos (hero loop, film), found ${videos.length}`);
for (const v of videos) {
  if (/\sautoplay\b/.test(v)) fail("video must not have autoplay: " + v.trim());
  if (/\ssrc=/.test(v)) fail("video src must be set by script, not in HTML: " + v.trim());
  if (!/preload="none"/.test(v)) fail('video needs preload="none": ' + v.trim());
}
const heroLoop = videos.find((v) => /hf-loop/.test(v)) || "";
if (!/\smuted\b/.test(heroLoop) || !/\splaysinline\b/.test(heroLoop)) fail("hero loop must be muted and playsinline");
if (!/<dialog[^>]*id="film"[\s\S]*<video\b[^>]*\scontrols\b[\s\S]*<\/dialog>/.test(html)) fail("the film (with sound) must live in the dialog, with controls");
if (/\.muted\s*=\s*false|\.autoplay\s*=|setAttribute\(\s*["'](autoplay|muted)/.test(js)) fail("site JS must not unmute or autoplay video");
const playCalls = jsFiles.filter((f) => /\.play\(/.test(readFileSync(f, "utf8"))).map((f) => f.slice(jsDir.length + 1));
if (playCalls.join() !== "film.js") fail("only film.js may start video playback, found: " + playCalls.join());
const budget = { "hero-loop-480.mp4": 400e3, "hero-loop-740.mp4": 700e3, "hero-poster-480.jpg": 80e3, "hero-poster-740.jpg": 130e3, "film-poster.jpg": 130e3, "film-720.mp4": 6.5e6, "film-1080.mp4": 9e6 };
for (const [f, max] of Object.entries(budget)) {
  const p = join(root, "assets/film", f);
  if (!existsSync(p)) { fail("missing film asset: " + f); continue; }
  const size = statSync(p).size;
  if (size > max) fail(`${f} is ${(size / 1e3).toFixed(0)} kB, budget ${(max / 1e3).toFixed(0)} kB`);
}
ok("videos: no autoplay sound, lazy sources, within size budgets");

// 3c. What gets published: everything not in .vercelignore must be a normal web file
const ignore = readFileSync(join(root, ".vercelignore"), "utf8").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
for (const must of [".env*", "scripts", "README.md", "package.json", ".vercel"]) if (!ignore.includes(must)) fail(".vercelignore must list " + must);
const ignored = (name) => ignore.some((p) => (p.endsWith("*") ? name.startsWith(p.slice(0, -1)) : name === p));
const published = [];
(function walk(dir, rel) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const r = rel ? rel + "/" + e.name : e.name;
    if (!rel && ignored(e.name)) continue;
    if (e.isDirectory()) walk(join(dir, e.name), r); else published.push(r);
  }
})(root, "");
for (const f of published) {
  if (!/\.(html|css|js|svg|jpg|png|webp|mp4)$/.test(f) || /(^|\/)\./.test(f)) fail("unexpected file would be published: " + f);
}
ok(`published files look clean (${published.length})`);

// 4. Languages match the app (ios/Interpreter/App/Models.swift)
const codes = [...js.matchAll(/\{ code: "([a-z]{2})"/g)].map((m) => m[1]);
const expected = ["en", "ko", "ja", "zh", "es", "fr", "de", "it", "pt", "ru", "hi", "id", "vi", "ar"];
if (codes.join() !== expected.join()) fail(`language list ${codes.join()} != ${expected.join()}`);
else ok("14 languages in app order");

// 5. Copy rules
const text = (html + "\n" + js).replace(/<[^>]+>/g, " ");
const forbidden = [
  [/download on the app store|get it on|app-store-badge|apps\.apple\.com/i, "App Store download link/badge"],
  [/<form\b/i, "form (no sign-up/waitlist)"],
  [/testimonial|\breviews?\b|as seen (in|on)/i, "testimonials, reviews or press"],
  [/guarantee|perfect(ly)?\b|flawless|100\s?%|zero[- ]latency|no delay|instant(ly)?\b|real[- ]time with no/i, "absolute quality or speed claim"],
  [/on-device|offline|never leaves|stays on (your|the) (phone|device)/i, "on-device / audio-never-leaves claim"],
  [/chatgpt/i, "ChatGPT comparison"],
  [/server (isn't|is not|not) deployed|coming soon/i, "outdated One-way status"],
  [/\bexperimental\b|\btried\b|not (been )?tested yet|quality not checked/i, "per-language test labels (owner: all 14 languages work)"],
];
for (const [re, label] of forbidden) {
  const m = text.match(re);
  if (m) fail(`forbidden copy (${label}): "${m[0]}"`);
}
ok("no forbidden claims");
const required = [
  "Illustrative demo",
  "Not on the App Store",
  "hasn't been tested in real conversations",
  "numeric diagnostics",
  "not stored permanently",
  "Example text",
  "Concept film",
  "made with an earlier build",
];
for (const s of required) if (!html.includes(s) && !js.includes(s)) fail("missing required label: " + s);
ok("honesty labels present");

console.log(failures.length ? `\n${failures.length} check(s) failed` : "\nAll checks passed");
process.exit(failures.length ? 1 : 0);
