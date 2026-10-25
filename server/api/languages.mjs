// Vercel function: GET /api/languages → languages NUA can offer, and which have actually been tried.
// The app shows only what this returns, so it never offers a pair the deployed server can't handle.
import { LANGUAGES, TRIED_LANGUAGES } from '../lib/live.mjs';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'GET') return res.status(405).json({ error: 'GET only' });
  if (!process.env.APP_SHARED_SECRET || req.headers['x-app-key'] !== process.env.APP_SHARED_SECRET) return res.status(401).json({ error: 'unauthorized' });
  return res.status(200).json({
    languages: Object.entries(LANGUAGES).map(([code, name]) => ({ code, name, tried: TRIED_LANGUAGES.includes(code) })),
    note: 'OpenAI publishes no language list for gpt-live-1. Only Korean and English have been tried; other languages are experimental.',
  });
}
