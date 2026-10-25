// Local preview server for the NUA site (no dependencies).
// Serves website/ and reloads open pages when a file changes. Local use only; not a deployment.
//   node scripts/serve.mjs [port]
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { watch, createReadStream } from "node:fs";
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
  ".mp4": "video/mp4",
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
    let info = await stat(path);
    if (info.isDirectory()) { path = join(path, "index.html"); info = await stat(path); }
    const type = types[extname(path)] || "application/octet-stream";
    if (type.startsWith("text/html")) {
      const body = (await readFile(path)).toString().replace("</body>", reloadSnippet + "</body>");
      res.writeHead(200, { "Content-Type": type, "Cache-Control": "no-store" });
      return void res.end(body);
    }
    // Byte ranges, so Safari can play the videos like it would from the real host.
    const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || "");
    const headers = { "Content-Type": type, "Cache-Control": "no-store", "Accept-Ranges": "bytes" };
    if (range) {
      let start = range[1] ? Number(range[1]) : info.size - Number(range[2]);
      let end = range[1] && range[2] ? Math.min(Number(range[2]), info.size - 1) : info.size - 1;
      if (!(start >= 0) || start > end) {
        res.writeHead(416, { "Content-Range": `bytes */${info.size}` });
        return void res.end();
      }
      res.writeHead(206, { ...headers, "Content-Range": `bytes ${start}-${end}/${info.size}`, "Content-Length": end - start + 1 });
      return void createReadStream(path, { start, end }).pipe(res);
    }
    res.writeHead(200, { ...headers, "Content-Length": info.size });
    createReadStream(path).pipe(res);
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain" }).end("Not found");
  }
}).listen(port, "127.0.0.1", () => console.log(`NUA site preview: http://localhost:${port}/`));
