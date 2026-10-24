// Vercel function: POST /api/metrics — latency numbers from development builds (no speech content).
// Logged to the function log so on-device latency can be read without Xcode.
import { cleanMetrics, rateLimited } from '../lib/openai.mjs';

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).end();
  if (!process.env.APP_SHARED_SECRET || req.headers['x-app-key'] !== process.env.APP_SHARED_SECRET) return res.status(401).end();
  const ip = (req.headers['x-forwarded-for'] || '').split(',')[0].trim() || 'unknown';
  if (rateLimited('m:' + ip, 60, 2000)) return res.status(429).end();
  console.log('[metrics] ' + JSON.stringify(cleanMetrics(req.body)));
  return res.status(204).end();
}
