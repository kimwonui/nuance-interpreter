// OpenAI 실시간 통역(gpt-realtime-translate) 서버 측 도우미.
// API 키는 이 서버 환경 변수에만 있고, 앱에는 짧게 쓰고 버리는 임시 키만 내려준다.

export const MODEL = 'gpt-realtime-translate';
export const TRANSCRIBE_MODEL = 'gpt-realtime-whisper';
export const TRANSLATE_WS_URL = `wss://api.openai.com/v1/realtime/translations?model=${MODEL}`;

// 출력 언어. 엔진은 13개 출력 언어를 지원하지만 1차는 한국어·영어만 연다.
export const SUPPORTED_TARGETS = new Set(['ko', 'en']);

// Source-language captions (gpt-realtime-whisper) are off by default: on low usage tiers they
// trigger tokens/rate_limit_exceeded and block the next sessions. Set TRANSCRIBE=1 to enable.
export function sessionConfig(target, transcribe = process.env.TRANSCRIBE === '1') {
  return {
    model: MODEL,
    audio: {
      input: {
        transcription: transcribe ? { model: TRANSCRIBE_MODEL } : null,
        noise_reduction: { type: 'near_field' },
      },
      output: { language: target },
    },
  };
}

export async function createClientSecret(apiKey, target, ttlSeconds = 60) {
  const res = await fetch('https://api.openai.com/v1/realtime/translations/client_secrets', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      expires_after: { anchor: 'created_at', seconds: ttlSeconds },
      session: sessionConfig(target),
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const message = body?.error?.message || `OpenAI ${res.status}`;
    const err = new Error(message);
    err.status = res.status;
    err.code = body?.error?.code || body?.error?.type || null;
    throw err;
  }
  return { value: body.value, expiresAt: body.expires_at, sessionId: body.session?.id };
}

// Best-effort issuance limits, kept in this server instance's memory only.
// Serverless instances don't share memory, so this is not a hard global cap.
const hits = new Map();
export function rateLimited(ip, perMinute = 20, perDay = 300) {
  const now = Date.now();
  const arr = (hits.get(ip) || []).filter((t) => now - t < 86_400_000);
  arr.push(now);
  hits.set(ip, arr);
  const lastMinute = arr.filter((t) => now - t < 60_000).length;
  return lastMinute > perMinute || arr.length > perDay;
}

// Accept only known numeric/short fields from the app's latency report. No speech content.
const METRIC_NUMBERS = ['speechSec', 'prepMs', 'endToFirstSound', 'endToFirstVoicedArrival', 'endToClosed', 'trimmedLeadSec', 'trimmedTailSec'];
export function cleanMetrics(body) {
  const out = {};
  for (const k of METRIC_NUMBERS) if (typeof body?.[k] === 'number' && Number.isFinite(body[k])) out[k] = Math.round(body[k] * 1000) / 1000;
  if (/^(KO|EN)→(KO|EN)$/.test(body?.direction || '')) out.direction = body.direction;
  if (typeof body?.prewarmed === 'boolean') out.prewarmed = body.prewarmed;
  if (typeof body?.route === 'string') out.route = body.route.slice(0, 40);
  if (typeof body?.mode === 'string') out.mode = body.mode.slice(0, 20);
  return out;
}
