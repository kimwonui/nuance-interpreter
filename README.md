# NUA (누아)

아이폰 한 대로 한국어 ↔ 영어 대화를 실시간 음성 통역하는 iOS 앱. 말한 사람의 의도·감정·말투를 최대한 살려 상대 언어 음성으로 들려준다.
이름은 **NUA(누아)** — Nuance(뉘앙스)의 앞 Nua. HackPSU 출품작이며 길로그 정식 제품이 아니다. 앱 식별자는 그대로 `com.wonuik.interpreter.dev`.

- 디자인: 피그마 [NUA](https://www.figma.com/design/aNByF25oUVjYOFZn7o3i3B) — 라이트 화면 기준(다크 프레임은 보존만, 2026-10-24부터 신규·수정 안 함), 길로그 컬러스펙 v1.1 토큰 복제
- 통역 엔진: OpenAI `gpt-realtime-translate` (통역 전용 실시간 음성→음성, 분당 $0.034, 2026-10-24 공식 문서 기준)

## 구조

```
ios/      SwiftUI 앱 (xcodegen 으로 프로젝트 생성)
  Interpreter/Audio/AudioIO.swift              마이크 24kHz PCM16 100ms 조각 + 번역 음성 재생, 경로 변경·끊김 처리
  Interpreter/Realtime/TranslationSocket.swift 발화 1회 = 통역 세션 1개 (웹소켓)
  Interpreter/Realtime/TokenClient.swift       우리 서버에서 임시 키(또는 중계 입장권) 받기
  Interpreter/App/InterpreterController.swift  듣기 → 말 끝 → 재생 흐름, 끼어들기, 다시 듣기, 재시도, 지연 측정
server/   임시 키 발급 서버 (OpenAI 키는 여기에만)
  api/session.mjs        Vercel 함수
  dev-server.mjs         맥 로컬 개발 서버 (직접 / 중계 모드)
  scripts/eval.mjs       시험 문장 15개로 품질·지연 측정
docs/test-sentences.json 부정·질문·비꼼·존댓말·반말·강조·망설임·명령(실행 금지) 양방향 문장
```

## 화면 (V2 오브 중심, 기본)

첫 진입부터 가운데 오브가 주인공이다. 자막·기록은 보조 영역, 조작은 하단 화자 알약 두 개.

| 상태 | 오브 | 신호 |
|---|---|---|
| 대기 | 4초 주기 느린 호흡 | 없음(마이크 꺼짐을 문구로 명시) |
| 듣기 | 커지고 흔들림 + 반응 고리 | 실제 마이크 음량 |
| 통역 중 | 각도 그라데이션 회전 + 궤도 점 | 없음 |
| 재생 | 커지고 흔들림 + 파문 | 실제 재생 음량(재생 노드 탭) |
| 중지·오류·권한 거부 | 회색 정지 | 없음("듣고 있지 않아요") |

- 동작 줄이기 켜짐: 회전·파문·호흡 없이 크기 변화만.
- 마이크 권한은 처음 말하기 버튼을 누를 때 요청한다.
- 설정 > 화면 에서 V1 카드 중심(이전안)으로 바꿔 비교할 수 있다.
- 실행 인자 `-localTest`: 서버 없이 실제 마이크 + 기기 합성 "테스트 신호" 재생으로 오브·재생 경로만 확인(통역 안 함, 화면에 표시). `-autoDemo`: 같은 모드로 버튼을 자동으로 눌러 녹화용 시연.

## 동작 방식

1. 말할 사람이 자기 언어 버튼을 누른다 → 원문 음성을 실시간으로 통역 세션에 보낸다(직전 0.3초 포함, 첫 음절 잘림 방지).
2. 말하는 동안 들어오는 번역 음성은 **보류**한다(말하는 사람 위로 소리가 겹치지 않게).
3. 같은 버튼을 다시 누르면(말 끝) `session.close` → 보류해 둔 번역부터 바로 재생, 남은 번역도 도착하는 대로 이어서 재생.
4. 재생 중 아무 버튼이나 누르면 재생을 끊고 바로 새로 듣는다(끼어들기).

- **재인식 루프 차단**: 버튼이 눌린 동안에만 마이크 음성을 보낸다. 재생 중에는 아무것도 보내지 않는다.
- **동시 발화**: 한 번에 한 사람만 듣는다(상대 버튼은 잠김). 1차는 자동 화자 전환 대신 버튼 방식.
- **저장 안 함**: 음성·대화는 파일로 저장하지 않는다. 다시 듣기·재시도용 음성은 메모리에만 있고 앱 종료 시 사라진다. 처리를 위해 OpenAI로 실시간 전송된다.
- **API 키 비노출**: 앱은 서버에서 몇 분짜리 임시 키만 받는다.

## 서버 실행 (맥, 개발용)

```bash
cd server
npm install
cp .env.example .env.local   # OPENAI_API_KEY 입력
npm run dev                  # 임시 키로 앱이 OpenAI 에 직접 연결
npm run dev:relay            # 직접 연결이 막힐 때: 아이폰 ↔ 맥 ↔ OpenAI 중계
npm run eval                 # 시험 문장 품질·지연 측정 (결과: server/eval-out/)
```

배포용은 `server/api/session.mjs` 를 Vercel 에 올리고 환경 변수 `OPENAI_API_KEY`(필수), `APP_SHARED_SECRET`(선택)을 넣는다.

## 아이폰 설치

1. `ios/Interpreter/Config/Secrets.example.xcconfig` 를 `Secrets.xcconfig` 로 복사 → `DEVELOPMENT_TEAM`, `INTERPRETER_SERVER_URL`(맥 IP:8787) 입력
2. `cd ios && xcodegen generate`
3. 아이폰을 맥에 연결(또는 같은 와이파이 페어링) + 개발자 모드 켜기
4. ```bash
   xcodebuild -project Interpreter.xcodeproj -scheme Interpreter -configuration Debug \
     -destination 'platform=iOS,id=<기기 ID>' -derivedDataPath build -allowProvisioningUpdates build
   xcrun devicectl device install app --device <기기 ID> build/Build/Products/Debug-iphoneos/Interpreter.app
   ```
   (Xcode 에서 열어 ▶ 눌러도 된다.)

## 한계 (정직하게)

- 엔진은 말투·감정 지시를 받지 않는다. 대신 원문 화자의 말투·높낮이를 따라가도록 학습돼 있다(공식 설명). 실제 보존 정도는 사람 음성으로 따로 검증해야 한다.
- 출력 목소리는 고를 수 없고 화자에 맞춰 바뀐다. **본인 음색 복제가 아니다.**
- 같은 언어로 말하면(예: 한국어 버튼 누르고 한국어 출력 방향) 소리가 안 나올 수 있다 → 카드에 "통역할 말이 없음" 표시.
- 속도는 측정 전까지 보장하지 않는다. `eval` 과 앱 설정의 "지연 시간 표시"로 잰다.
