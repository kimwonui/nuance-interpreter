// 개발용 로컬 서버(맥에서 실행, 같은 와이파이의 아이폰이 접속).
//   node dev-server.mjs            → 임시 키 직접 연결 모드(direct)
//   RELAY=1 node dev-server.mjs    → 중계 모드(relay): 아이폰 ↔ 이 서버 ↔ OpenAI
// 중계 모드는 임시 키로 웹소켓 직접 연결이 막힐 때를 대비한 대체 경로다.
// 음성·대화 내용은 저장하거나 로그로 남기지 않는다(이벤트 종류 개수만 센다).
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import crypto from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { createClientSecret, rateLimited, sessionConfig, SUPPORTED_TARGETS, TRANSLATE_WS_URL } from './lib/openai.mjs';

loadEnvFile(new URL('./.env.local', import.meta.url));
const PORT = Number(process.env.PORT || 8787);
const RELAY = process.env.RELAY === '1';
const API_KEY = process.env.OPENAI_API_KEY;
const APP_KEY = process.env.APP_SHARED_SECRET;
const tickets = new Map(); // 중계 모드 1회용 입장권 → { target, exp }

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (req.method === 'GET' && url.pathname === '/health') {
    return json(res, 200, { ok: true, mode: RELAY ? 'relay' : 'direct', hasKey: Boolean(API_KEY) });
  }
  if (req.method === 'POST' && url.pathname === '/api/session') {
    if (APP_KEY && req.headers['x-app-key'] !== APP_KEY) return json(res, 401, { error: 'unauthorized' });
    if (rateLimited(req.socket.remoteAddress || 'local')) return json(res, 429, { error: 'too many requests' });
    const body = await readJson(req);
    const target = String(body.target || '');
    if (!SUPPORTED_TARGETS.has(target)) return json(res, 400, { error: 'unsupported target' });
    if (!API_KEY) return json(res, 500, { error: 'server missing OPENAI_API_KEY' });

    if (RELAY) {
      const ticket = crypto.randomBytes(16).toString('hex');
      tickets.set(ticket, { target, exp: Date.now() + 120_000 });
      return json(res, 200, { mode: 'relay', url: `ws://${req.headers.host}/relay?ticket=${ticket}`, token: ticket, expiresAt: Math.floor(Date.now() / 1000) + 120 });
    }
    try {
      const s = await createClientSecret(API_KEY, target);
      return json(res, 200, { mode: 'direct', url: TRANSLATE_WS_URL, token: s.value, expiresAt: s.expiresAt });
    } catch (e) {
      return json(res, 502, { error: e.message });
    }
  }
  json(res, 404, { error: 'not found' });
});

const wss = new WebSocketServer({ noServer: true });
server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const t = tickets.get(url.searchParams.get('ticket') || '');
  if (url.pathname !== '/relay' || !t || t.exp < Date.now()) return socket.destroy();
  tickets.delete(url.searchParams.get('ticket'));
  wss.handleUpgrade(req, socket, head, (client) => relay(client, t.target));
});

function relay(client, target) {
  const counts = {};
  const upstream = new WebSocket(TRANSLATE_WS_URL, { headers: { Authorization: `Bearer ${API_KEY}` } });
  const pending = [];
  upstream.on('open', () => {
    upstream.send(JSON.stringify({ type: 'session.update', session: { audio: sessionConfig(target).audio } }));
    for (const m of pending.splice(0)) upstream.send(m);
  });
  upstream.on('message', (data) => {
    const text = data.toString();
    const type = /"type"\s*:\s*"([^"]+)"/.exec(text)?.[1] || '?';
    counts[type] = (counts[type] || 0) + 1;
    if (client.readyState === WebSocket.OPEN) client.send(text);
  });
  client.on('message', (data) => {
    const text = data.toString();
    if (upstream.readyState === WebSocket.OPEN) upstream.send(text);
    else pending.push(text);
  });
  const end = () => {
    if (client.readyState === WebSocket.OPEN) client.close();
    if (upstream.readyState === WebSocket.OPEN) upstream.close();
  };
  upstream.on('close', () => { console.log(`[relay ${target}] 종료`, JSON.stringify(counts)); end(); });
  upstream.on('error', (e) => { console.log(`[relay ${target}] 오류`, e.message); end(); });
  client.on('close', end);
}

server.listen(PORT, '0.0.0.0', () => {
  const ips = Object.values(os.networkInterfaces()).flat().filter((i) => i && i.family === 'IPv4' && !i.internal).map((i) => i.address);
  console.log(`통역 개발 서버 :${PORT} (${RELAY ? '중계' : '직접'} 모드, 키 ${API_KEY ? '있음' : '없음'})`);
  for (const ip of ips) console.log(`  아이폰에서: http://${ip}:${PORT}`);
});

function json(res, status, obj) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(obj));
}
function readJson(req) {
  return new Promise((resolve) => {
    let raw = '';
    req.on('data', (c) => { raw += c; if (raw.length > 10_000) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(raw || '{}')); } catch { resolve({}); } });
  });
}
function loadEnvFile(fileUrl) {
  if (!fs.existsSync(fileUrl)) return;
  for (const line of fs.readFileSync(fileUrl, 'utf8').split('\n')) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^['"]|['"]$/g, '');
  }
}
