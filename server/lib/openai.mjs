// OpenAI 실시간 통역(gpt-realtime-translate) 서버 측 도우미.
// API 키는 이 서버 환경 변수에만 있고, 앱에는 짧게 쓰고 버리는 임시 키만 내려준다.

export const MODEL = 'gpt-realtime-translate';
export const TRANSCRIBE_MODEL = 'gpt-realtime-whisper';
export const TRANSLATE_WS_URL = `wss://api.openai.com/v1/realtime/translations?model=${MODEL}`;

// 출력 언어. 엔진은 13개 출력 언어를 지원하지만 1차는 한국어·영어만 연다.
export const SUPPORTED_TARGETS = new Set(['ko', 'en']);

export function sessionConfig(target) {
  return {
    model: MODEL,
    audio: {
      input: {
        transcription: { model: TRANSCRIBE_MODEL },
        noise_reduction: { type: 'near_field' },
      },
      output: { language: target },
    },
  };
}

export async function createClientSecret(apiKey, target, ttlSeconds = 300) {
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
    throw err;
  }
  return { value: body.value, expiresAt: body.expires_at, sessionId: body.session?.id };
}

// 아주 단순한 IP별 호출 제한(서버 인스턴스 메모리 기준).
const hits = new Map();
export function rateLimited(ip, limit = 30, windowMs = 60_000) {
  const now = Date.now();
  const arr = (hits.get(ip) || []).filter((t) => now - t < windowMs);
  arr.push(now);
  hits.set(ip, arr);
  return arr.length > limit;
}
