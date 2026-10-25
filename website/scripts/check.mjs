// Static checks for the NUA site (no dependencies): JS syntax, links and assets, no network/mic/audio
// code, the 14-language list, and copy rules (no fake download/sign-up, required honesty labels).
//   node scripts/check.mjs
import { readFileSync, existsSync, readdirSync } from "node:fs";
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
for (const [, ref] of html.matchAll(/(?:src|href)="([^"#][^"]*)"/g)) {
  if (/^https?:/.test(ref)) {
    if (!/^https:\/\/fonts\.(googleapis|gstatic)\.com/.test(ref)) fail("unexpected external URL: " + ref);
    continue;
  }
  if (!existsSync(join(root, ref))) fail("missing asset: " + ref);
}
ok("local assets exist; only Google Fonts is external");

// 3. The demo never touches the network, microphone or speakers
const banned = [/\bfetch\s*\(/, /XMLHttpRequest/, /WebSocket/, /getUserMedia/, /new\s+Audio\s*\(/, /AudioContext/, /speechSynthesis/, /sendBeacon/];
for (const re of banned) if (re.test(js)) fail("site JS must not use " + re);
ok("no network, microphone or audio APIs in site JS");

// 4. Languages match the app (ios/Interpreter/App/Models.swift)
const codes = [...js.matchAll(/\{ code: "([a-z]{2})"/g)].map((m) => m[1]);
const expected = ["en", "ko", "ja", "zh", "es", "fr", "de", "it", "pt", "ru", "hi", "id", "vi", "ar"];
if (codes.join() !== expected.join()) fail(`language list ${codes.join()} != ${expected.join()}`);
else ok("14 languages in app order");
const tried = [...js.matchAll(/\{ code: "([a-z]{2})"[^}]*tried: true/g)].map((m) => m[1]);
if (tried.join() !== "en,ko") fail("only English and Korean may be marked tried, got " + tried.join());
else ok("only English and Korean marked tried");

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
];
for (const [re, label] of forbidden) {
  const m = text.match(re);
  if (m) fail(`forbidden copy (${label}): "${m[0]}"`);
}
ok("no forbidden claims");
const required = [
  "Illustrative demo",
  "Not on the App Store",
  "Experimental",
  "GPT-Live only",
  "hasn't been tested in real conversations",
  "numeric diagnostics",
  "not stored permanently",
];
for (const s of required) if (!html.includes(s) && !js.includes(s)) fail("missing required label: " + s);
ok("honesty labels present");

console.log(failures.length ? `\n${failures.length} check(s) failed` : "\nAll checks passed");
process.exit(failures.length ? 1 : 0);
