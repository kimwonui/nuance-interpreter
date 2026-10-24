// Vercel 서버리스 함수: POST /api/session  { "target": "en" | "ko" }
// 응답: { mode: "direct", url, token, expiresAt }
// 앱은 token(임시 키)으로 OpenAI 통역 웹소켓에 직접 붙는다. 음성은 이 서버를 지나지 않는다.
import { createClientSecret, rateLimited, SUPPORTED_TARGETS, TRANSLATE_WS_URL } from '../lib/openai.mjs';

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });

  const appKey = process.env.APP_SHARED_SECRET;
  if (appKey && req.headers['x-app-key'] !== appKey) return res.status(401).json({ error: 'unauthorized' });

  const ip = (req.headers['x-forwarded-for'] || '').split(',')[0].trim() || 'unknown';
  if (rateLimited(ip)) return res.status(429).json({ error: 'too many requests' });

  const target = String(req.body?.target || '');
  if (!SUPPORTED_TARGETS.has(target)) return res.status(400).json({ error: 'unsupported target' });

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) return res.status(500).json({ error: 'server missing OPENAI_API_KEY' });

  try {
    const secret = await createClientSecret(apiKey, target);
    res.setHeader('Cache-Control', 'no-store');
    return res.status(200).json({ mode: 'direct', url: TRANSLATE_WS_URL, token: secret.value, expiresAt: secret.expiresAt });
  } catch (e) {
    return res.status(502).json({ error: e.message });
  }
}
