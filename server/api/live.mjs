// Vercel function: POST /api/live  { "sdp": "<WebRTC offer>" }  →  { sdp: "<answer>", sessionId }
// Creates a GPT-Live session for the phone. The API key and the interpreter instructions stay here;
// after the answer, audio flows directly between the phone and OpenAI over WebRTC.
// Access control: X-App-Key (ships in the app → casual-abuse protection only) + best-effort limits.
import { rateLimited } from '../lib/openai.mjs';
import { createLiveWebRTCSession, validPair } from '../lib/live.mjs';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });

  const appKey = process.env.APP_SHARED_SECRET;
  if (!appKey) return res.status(503).json({ error: 'server not configured' });
  if (req.headers['x-app-key'] !== appKey) return res.status(401).json({ error: 'unauthorized' });

  const ip = (req.headers['x-forwarded-for'] || '').split(',')[0].trim() || 'unknown';
  // Live sessions bill by open duration, so allow fewer starts than short-lived keys.
  if (rateLimited('live:' + ip, 6, 60)) return res.status(429).json({ error: 'too many requests' });

  const sdp = req.body?.sdp;
  if (typeof sdp !== 'string' || !sdp.startsWith('v=0') || sdp.length > 100_000) return res.status(400).json({ error: 'invalid offer' });

  // Language pair chosen in the app; older app builds send none → Korean↔English.
  const pair = req.body?.languages === undefined ? ['ko', 'en'] : validPair(req.body.languages);
  if (!pair) return res.status(400).json({ error: 'unsupported languages' });

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) return res.status(503).json({ error: 'server not configured' });

  try {
    const s = await createLiveWebRTCSession(apiKey, sdp, pair);
    console.log(`[live] session created id=${s.sessionId} pair=${pair.join('-')}`);
    return res.status(200).json(s);
  } catch (e) {
    console.log(`[live] failed status=${e.status} code=${e.code}`);
    return res.status(502).json({ error: e.code || `upstream ${e.status}` });
  }
}
