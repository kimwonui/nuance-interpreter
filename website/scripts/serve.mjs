// Local preview server for the NUA site (no dependencies).
// Serves website/ and reloads open pages when a file changes. Local use only; not a deployment.
//   node scripts/serve.mjs [port]
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { watch } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const port = Number(process.argv[2] || process.env.PORT || 4173);
const types = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
};
const reloadSnippet = `<script>(()=>{const s=new EventSource("/__reload");s.onmessage=()=>location.reload();})();</script>`;
const clients = new Set();

let timer;
watch(root, { recursive: true }, (_, file) => {
  if (!file || file.includes("node_modules") || file.startsWith(".")) return;
  clearTimeout(timer);
  timer = setTimeout(() => clients.forEach((res) => res.write("data: reload\n\n")), 120);
});

createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (url.pathname === "/__reload") {
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
    res.write(": connected\n\n");
    clients.add(res);
    req.on("close", () => clients.delete(res));
    return;
  }
  let path = normalize(join(root, decodeURIComponent(url.pathname)));
  if (!path.startsWith(root)) return void res.writeHead(403).end();
  try {
    if ((await stat(path)).isDirectory()) path = join(path, "index.html");
    let body = await readFile(path);
    const type = types[extname(path)] || "application/octet-stream";
    if (type.startsWith("text/html")) body = body.toString().replace("</body>", reloadSnippet + "</body>");
    res.writeHead(200, { "Content-Type": type, "Cache-Control": "no-store" });
    res.end(body);
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain" }).end("Not found");
  }
}).listen(port, "127.0.0.1", () => console.log(`NUA site preview: http://localhost:${port}/`));
