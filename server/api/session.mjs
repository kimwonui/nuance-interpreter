// Vercel function: POST /api/session  { "target": "en" | "ko" }
// Returns { mode: "direct", url, token, expiresAt }. The app uses the short-lived token (60 s)
// to open the OpenAI interpretation WebSocket directly; audio never passes through this server.
// Access control: X-App-Key must match APP_SHARED_SECRET. That value ships inside the app,
// so it only stops casual abuse — it is not strong authentication. Limits are best-effort per instance.
import { createClientSecret, rateLimited, SUPPORTED_TARGETS, TRANSLATE_WS_URL } from '../lib/openai.mjs';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });

  const appKey = process.env.APP_SHARED_SECRET;
  if (!appKey) return res.status(503).json({ error: 'server not configured' });
  if (req.headers['x-app-key'] !== appKey) return res.status(401).json({ error: 'unauthorized' });

  const ip = (req.headers['x-forwarded-for'] || '').split(',')[0].trim() || 'unknown';
  if (rateLimited(ip)) return res.status(429).json({ error: 'too many requests' });

  const target = String(req.body?.target || '');
  if (!SUPPORTED_TARGETS.has(target)) return res.status(400).json({ error: 'unsupported target' });

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) return res.status(503).json({ error: 'server not configured' });

  try {
    const secret = await createClientSecret(apiKey, target);
    console.log(`[session] target=${target} ok`);
    return res.status(200).json({ mode: 'direct', url: TRANSLATE_WS_URL, token: secret.value, expiresAt: secret.expiresAt });
  } catch (e) {
    // Log only status and error code, never the key or raw upstream message.
    console.log(`[session] target=${target} failed status=${e.status} code=${e.code}`);
    return res.status(502).json({ error: e.code || `upstream ${e.status}` });
  }
}
