# NUA

NUA is an iOS app for face-to-face, real-time voice interpretation between Korean and English on a single iPhone. It tries to carry each speaker's intent, emotion, and tone into speech in the other language. The name comes from the "Nua" in *Nuance*.

- Built for HackPSU. Not a Gillog product. Bundle ID stays `com.wonuik.interpreter.dev`.
- UI language: English only. Korean is supported as an interpretation language (Korean speech in, Korean speech out).
- Design: [Figma — NUA](https://www.figma.com/design/aNByF25oUVjYOFZn7o3i3B). Light frames are the source of truth; dark frames are preserved but no longer updated (since 2026-10-24). Visual tokens are copied from the Gillog color spec v1.1.
- Engine: OpenAI `gpt-realtime-translate` (dedicated real-time speech-to-speech interpretation, $0.034 per minute per the official docs on 2026-10-24).

## Layout

```
ios/      SwiftUI app (project generated with xcodegen)
  Interpreter/Audio/AudioIO.swift              24 kHz PCM16 mic chunks (100 ms) + playback, route/interruption handling, output level tap
  Interpreter/Audio/TestSignal.swift           on-device speech used only by the labeled test-signal mode
  Interpreter/Realtime/TranslationSocket.swift one utterance = one interpretation session (WebSocket)
  Interpreter/Realtime/TokenClient.swift       fetches a short-lived key (or relay ticket) from our server
  Interpreter/App/InterpreterController.swift  listen → done → play flow, cut-in, replay, retry, latency metrics
  Interpreter/Views/OrbView.swift              center orb (motion spec in Figma)
server/   token server (the OpenAI key lives only here)
  api/session.mjs        Vercel function
  dev-server.mjs         local dev server for the Mac (direct / relay modes)
  scripts/eval.mjs       quality and latency check with 15 test sentences
docs/test-sentences.json negation, questions, sarcasm, honorifics, casual speech, emphasis, hesitation, commands (must not be executed), both directions
```

## Testing policy (owner decision, 2026-10-24)

- All testing is done by the owner on the owner's iPhone with the installed build.
- No simulator runs, no scripted runs (`-autoDemo`, `-autoTurns`, `-autoStart`, `-localTest`), no synthetic-voice interpretation tests, and no one speaks into the device on the owner's behalf.
- Engineering stops at: build → sign → install on the owner's iPhone → confirm the token server is reachable.
- Function, quality, and speed are judged only from the owner's own tests and the technical logs they produce (numbers-only `/api/metrics` entries in the Vercel function log).
- A successful build or install is never reported as "interpretation verified".

## Hands-free mode (default)

### Hands-free engines

- **GPT-Live (default)** — `gpt-live-1`, OpenAI's full-duplex voice model for natural conversation with built-in turn-taking and interruptions ($0.05 per minute of open session, billed per second). There are no client secrets for Live, so the phone sends its WebRTC offer to `POST /api/live`; the server creates the session with the API key and **fixed interpreter instructions** (adapted from OpenAI's translation-only Live prompt, extended to Korean↔English) and returns the answer. Audio then flows directly between the phone and OpenAI; WebRTC provides echo cancellation. Uses Google WebRTC via the `stasel/WebRTC` Swift package (154.0.0). The API model is `gpt-live-1`; it is not claimed to be identical to the ChatGPT Live app.
- **Interpreter model** — the two-session `gpt-realtime-translate` design below. Used automatically if a Live session can't start.


1. Tap **Start conversation** — this is the only thing that turns the mic on (nothing records at launch). The iOS mic indicator shows the real state; **Mute** turns the mic engine off, **Stop** ends everything.
2. NUA keeps two interpretation sessions open (→English and →Korean) and listens with a local voice detector. Audio is sent only while someone speaks (0.5 s pre-roll so the first syllable isn't lost, 1.5 s tail), never during silence.
3. The →English session also returns the source transcript (`gpt-4o-mini-transcribe`, enabled from the client). Hangul vs. Latin letters decides the direction; the matching session's audio plays, the other is dropped. Fallback without a transcript: which session produced speech.
4. While NUA talks, the mic isn't streamed (no feedback loop). Echo cancellation is on; speaking loudly over NUA for 0.4 s cuts it off. If a new transcript matches what NUA just said, it's treated as echo and ignored.
5. Push to talk remains in Settings → Conversation.

Known limits: the model has one output language per session and no detected-language event (hence two sessions, ~2× audio minutes while someone speaks); very short replies (e.g. "네, 좋아요.") may get no translation because the model waits for more context; pauses longer than 0.7 s end an utterance (a resumed sentence within 2 s before any output is merged back).

## Screen (V2, orb-centered)

The orb is the hero from first launch. Captions and history are secondary; the only controls are two speaker pills.

| State | Orb | Driven by |
|---|---|---|
| Ready | slow 4 s breathing | nothing (text says "Mic off") |
| Listening | grows and wobbles, response rings | real microphone level |
| Interpreting | rotating angular gradient + orbit dots | nothing |
| Playing | grows and wobbles, ripples | real playback level (player-node tap) |
| Stopped / error / no permission | static grey | nothing ("Not listening") |

- Reduce Motion: no rotation, ripples, or breathing; level is shown by size only.
- Microphone permission is requested the first time someone taps a speaker pill.
- Settings → Screen switches to the previous card layout (V1) for comparison.
- Launch argument `-localTest`: no server; real microphone input plus an on-device "TEST SIGNAL" voice played through the real playback path, to check the orb and audio path. It does **not** interpret, and the screen says so. `-autoDemo`: same mode with scripted taps, for recording.

## How it works

1. The speaker taps their language → mic audio streams to the interpretation session (including the previous 0.3 s so the first syllable isn't lost).
2. Translated audio that arrives while they are still talking is **held** so it doesn't play over them.
3. Tapping Done sends `session.close` → held audio plays immediately, the rest plays as it arrives.
4. Tapping any pill during playback stops it and starts listening right away (cut-in).

- **No feedback loop**: mic audio is only sent while a pill is active; nothing is sent during playback.
- **One speaker at a time**: the other pill is locked while someone is talking. v1 uses buttons, not automatic speaker detection.
- **Nothing saved**: audio and conversations are never written to disk. Audio kept for Replay/Retry lives in memory and disappears when the app closes. Audio is streamed to OpenAI for processing.
- **No API key in the app**: the app only receives a key that expires in a few minutes.

## Run the server (Mac, development)

```bash
cd server
npm install
cp .env.example .env.local   # add OPENAI_API_KEY
npm run dev                  # app connects to OpenAI directly with a short-lived key
npm run dev:relay            # fallback if direct WebSocket auth is rejected: iPhone ↔ Mac ↔ OpenAI
npm run eval                 # quality + latency on the test sentences (results in server/eval-out/)
```

Production token server: `https://nua-token.vercel.app` (Vercel project `nua-token`, functions `api/session` and `api/metrics`). Env vars: `OPENAI_API_KEY` and `APP_SHARED_SECRET` (both required, server-only). GitHub auto-deploy is disconnected; deploys are manual and owner-approved.

## Install on an iPhone (development)

1. Copy `ios/Interpreter/Config/Secrets.example.xcconfig` to `Secrets.xcconfig` and set `DEVELOPMENT_TEAM` and `INTERPRETER_SERVER_URL` (Mac IP:8787).
2. `cd ios && xcodegen generate`
3. Connect the iPhone (USB or paired Wi-Fi) with Developer Mode on. Xcode must be signed in to the Apple ID (Xcode → Settings → Accounts) and the team's agreements must be accepted.
4. ```bash
   xcodebuild -project Interpreter.xcodeproj -scheme Interpreter -configuration Debug \
     -destination 'platform=iOS,id=<device UDID>' -derivedDataPath build -allowProvisioningUpdates build
   xcrun devicectl device install app --device <device id> build/Build/Products/Debug-iphoneos/Interpreter.app
   ```

## Known limits

- The engine takes no tone or style instructions. Per OpenAI, it is trained to follow the source speaker's tone and pitch. How well nuance survives must be checked with real human speech.
- The output voice can't be chosen and adapts to the speaker. **It is not a clone of the user's voice.**
- Speaking the output language (e.g. English into the Korean→English direction) may produce silence; the UI shows "Nothing to interpret".
- Speed is not guaranteed until measured. Use `npm run eval` and Settings → Show latency.
