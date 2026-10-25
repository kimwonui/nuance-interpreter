// 맥에서 돌리는 통역 품질·지연 측정기.
// macOS 합성 음성(say)으로 시험 문장을 만들어 실시간 속도로 흘려 보내고,
// "말 끝(마지막 음성 조각 전송) → 첫 번역 음성 조각 도착" 시간을 잰다.
//   node scripts/eval.mjs [--auth=ek|key] [--only=id1,id2] [--out=폴더]
// 주의: 합성 음성은 비꼼·망설임 같은 억양이 사람보다 약하다. 억양 보존은 실기기 사람 음성으로 따로 본다.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { WebSocket } from 'ws';
import { createClientSecret, sessionConfig, TRANSLATE_WS_URL } from '../lib/openai.mjs';

const args = Object.fromEntries(process.argv.slice(2).map((a) => a.replace(/^--/, '').split('=')));
const here = path.dirname(new URL(import.meta.url).pathname);
loadEnv(path.join(here, '..', '.env.local'));
const API_KEY = process.env.OPENAI_API_KEY;
if (!API_KEY) { console.error('OPENAI_API_KEY missing (server/.env.local)'); process.exit(1); }

const AUTH = args.auth || 'ek';
const OUT = path.resolve(args.out || path.join(here, '..', 'eval-out'));
fs.mkdirSync(OUT, { recursive: true });
const all = JSON.parse(fs.readFileSync(path.join(here, '..', '..', 'docs', 'test-sentences.json'), 'utf8'));
const only = args.only ? new Set(args.only.split(',')) : null;
const cases = all.filter((c) => !only || only.has(c.id));

const results = [];
for (const c of cases) {
  const pcm = synth(c);
  const r = await runCase(c, pcm).catch((e) => ({ error: e.message }));
  results.push({ ...c, ...r });
  console.log(`${c.id}\t${r.error ? 'FAILED ' + r.error : `end→first audio ${fmt(r.endToFirstAudio)}  end→closed ${fmt(r.endToClosed)}`}\n  source: ${r.inputText || ''}\n  translation: ${r.outputText || ''}`);
}
fs.writeFileSync(path.join(OUT, 'results.json'), JSON.stringify(results, null, 2));
const ok = results.filter((r) => r.endToFirstAudio != null);
const lat = ok.map((r) => r.endToFirstAudio).sort((a, b) => a - b);
if (lat.length) {
  const avg = lat.reduce((a, b) => a + b, 0) / lat.length;
  console.log(`\n${lat.length} samples / avg ${fmt(avg)} / median ${fmt(lat[Math.floor(lat.length / 2)])} / slowest ${fmt(lat[lat.length - 1])} (auth ${AUTH})`);
}

function synth(c) {
  const aiff = path.join(OUT, `${c.id}.aiff`);
  const wav = path.join(OUT, `${c.id}.in.wav`);
  execFileSync('say', ['-v', c.voice, '-o', aiff, c.text]);
  execFileSync('afconvert', ['-f', 'WAVE', '-d', 'LEI16@24000', '-c', '1', aiff, wav]);
  fs.rmSync(aiff);
  return readWavPcm(wav);
}

async function runCase(c, pcm) {
  let auth = API_KEY;
  if (AUTH === 'ek') auth = (await createClientSecret(API_KEY, c.target)).value;
  const ws = new WebSocket(TRANSLATE_WS_URL, { headers: { Authorization: `Bearer ${auth}` } });
  const out = { inputText: '', outputText: '', audio: [], events: {} };
  let tEnd = null, tFirstAudio = null, tFirstText = null, tClosed = null, tStart = null;

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), 60_000);
    ws.on('unexpected-response', (_req, res) => { clearTimeout(timer); reject(new Error(`connection refused HTTP ${res.statusCode}`)); });
    ws.on('error', (e) => { clearTimeout(timer); reject(e); });
    ws.on('open', () => {
      ws.send(JSON.stringify({ type: 'session.update', session: { audio: sessionConfig(c.target).audio } }));
      const chunk = 4800; // 100ms
      let off = 0;
      tStart = performance.now();
      const iv = setInterval(() => {
        if (off >= pcm.length) {
          clearInterval(iv);
          tEnd = performance.now();
          ws.send(JSON.stringify({ type: 'session.close' }));
          return;
        }
        ws.send(JSON.stringify({ type: 'session.input_audio_buffer.append', audio: pcm.subarray(off, off + chunk).toString('base64') }));
        off += chunk;
      }, 100);
    });
    ws.on('message', (data) => {
      const ev = JSON.parse(data.toString());
      out.events[ev.type] = (out.events[ev.type] || 0) + 1;
      const now = performance.now();
      if (ev.type === 'session.output_audio.delta') {
        if (tFirstAudio == null) tFirstAudio = now;
        out.audio.push(Buffer.from(ev.delta, 'base64'));
      } else if (ev.type === 'session.output_transcript.delta') {
        if (tFirstText == null) tFirstText = now;
        out.outputText += ev.delta;
      } else if (ev.type === 'session.input_transcript.delta') {
        out.inputText += ev.delta;
      } else if (ev.type === 'session.closed') {
        tClosed = now;
        clearTimeout(timer);
        ws.close();
        resolve();
      } else if (ev.type === 'error') {
        out.error = ev.error?.message || JSON.stringify(ev);
      }
    });
    ws.on('close', () => { clearTimeout(timer); resolve(); });
  });

  if (out.audio.length) writeWav(path.join(OUT, `${c.id}.out.wav`), Buffer.concat(out.audio));
  const speechMs = (pcm.length / 2 / 24000) * 1000;
  return {
    speechMs: Math.round(speechMs),
    endToFirstAudio: tFirstAudio != null && tEnd != null ? Math.round(tFirstAudio - tEnd) : null,
    startToFirstAudio: tFirstAudio != null ? Math.round(tFirstAudio - tStart) : null,
    endToFirstText: tFirstText != null && tEnd != null ? Math.round(tFirstText - tEnd) : null,
    endToClosed: tClosed != null && tEnd != null ? Math.round(tClosed - tEnd) : null,
    inputText: out.inputText.trim(),
    outputText: out.outputText.trim(),
    events: out.events,
    error: out.error,
  };
}

function readWavPcm(file) {
  const buf = fs.readFileSync(file);
  let p = 12;
  while (p < buf.length) {
    const id = buf.toString('ascii', p, p + 4);
    const size = buf.readUInt32LE(p + 4);
    if (id === 'data') return buf.subarray(p + 8, p + 8 + size);
    p += 8 + size + (size % 2);
  }
  throw new Error('no wav data');
}
function writeWav(file, pcm) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.length, 4); h.write('WAVE', 8); h.write('fmt ', 12);
  h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(24000, 24);
  h.writeUInt32LE(48000, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(pcm.length, 40);
  fs.writeFileSync(file, Buffer.concat([h, pcm]));
}
function fmt(ms) { return ms == null ? '-' : `${(ms / 1000).toFixed(2)}s`; }
function loadEnv(file) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^['"]|['"]$/g, '');
  }
}
