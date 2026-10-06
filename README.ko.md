# MyComputerAgent (mca)

<p align="center">
  <a href="README.md"><b>English</b></a> •
  <a href="README.ja.md"><b>日本語</b></a> •
  <a href="README.ko.md"><b>한국어</b></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26.0%2B-black?logo=apple" alt="macOS" />
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="SECURITY.md"><img src="https://img.shields.io/badge/Security-Zero--Trust%20Privacy-success" alt="Zero-Trust Privacy" /></a>
  <a href="https://github.com/buddypia/my-computer-agent/actions/workflows/ci.yml"><img src="https://github.com/buddypia/my-computer-agent/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
</p>

> **공식 지원 언어**: 본 애플리케이션은 UI 인터페이스, 음성 인식 엔진, AI 모델 추론 응답의 모든 레이어에서 영어(English), 일본어(日本語), 한국어를 공식적으로 네이티브 지원합니다.

macOS를 위한 로컬 우선(Local-first) 멀티모달 데스크톱 코파일럿입니다. 사용자의 화면에서 일어나는 작업을 지켜보고, 로컬 머신 내에 검색 가능한 히스토리를 보관하며, 정말 가치 있는 조언이 있을 때만 이야기합니다. 사용자가 원할 때 양방향 대화를 청취할 수도 있지만, 실행 시점에는 마이크가 꺼져 있어 프라이버시가 보호됩니다.

브라우저나 Electron 셸에서는 구현할 수 없는 네이티브 기능들 — 다른 앱의 접근성 트리(AXUIElement) 읽기, 가상 오디오 드라이버 없는 CoreAudio 프로세스 탭을 통한 시스템 오디오 직접 캡처, 하드웨어 에코 캔슬레이션(AEC), 전체 화면 앱 위에도 띄울 수 있는 클릭 관통(Click-through) 플로팅 윈도우 — 을 완벽하게 활용하기 위해 100% 네이티브 Swift로 작성되었습니다.

---

## 주요 기능

| | |
|---|---|
| **보기 (Sees)** | OS 이벤트(포커스 변경, 창 제목 변경, 타이핑 중단)를 트리거로 활성 창의 접근성 트리를 읽습니다. Canvas 기반 렌더링 앱에서는 온디바이스 Vision OCR로 자동 폴백합니다. 불필요한 프레임 레이트 감시(주기적 폴링)는 전혀 수행하지 않습니다. |
| **실행하기 (Acts)** | CoreGraphics 이벤트 합성과 접근성 API(AXUIElement)를 연동한 네이티브 GUI 제어(클릭, 타이핑, 키 조합, AppleScript 실행). TypeSafe AI(Jev System One 모델, <200ms) 기반 초저지연 UI 판정 및 API 키 미설정 시의 로컬 시맨틱 폴백 지원. 내장 코파일럿, CLI(`mca act`), 외부 MCP 클라이언트에서 안전하게 호출할 수 있습니다. |
| **듣기 (Hears)** | 하드웨어 AEC가 적용된 마이크 입력과, 가상 드라이버 없는 CoreAudio 프로세스 탭을 통한 시스템 오디오 출력을 분리 캡처합니다. 2개 독립 채널로 '나'와 '상대방'의 음성을 명확히 구분합니다. **앱 실행 시에는 아무것도 캡처하지 않습니다.** 음성 대화(⌥⌘V)를 시작할 때 마이크가 열리고 종료 시 닫힙니다. 상시 캡처는 ✨ ▸ 설정 ▸ 일반 ▸ 오디오에서 활성화할 수 있습니다. |
| **텍스트 변환 (Transcribes)** | 듀얼 인식 엔진 지원: 완전한 로컬 프라이버시를 보장하는 Apple 온디바이스 `SpeechAnalyzer`, 또는 뛰어난 다국어 정확도와 동음이의어 문맥 보정 및 불필요한 추임새 제거를 제공하는 **Gemini Flash 음성 배치 인식**. Apple 엔진 사용 시 음성 데이터는 절대 기기 밖으로 나가지 않습니다. |
| **말하기 (Talks)** | 복잡한 모드 선택 대신 2개의 직관적인 버튼을 제공합니다. 마이크 버튼은 **받아쓰기(Dictation)**: Mac에서 온디바이스/클라우드로 텍스트 변환 후 타이핑 질문과 동일한 채팅 모델로 전달됩니다. 옆의 파형 버튼은 **Live 대화**: 단일 소켓을 통해 Gemini가 음성을 직접 듣고 음성으로 답변하며, 실시간 정보가 필요할 때 웹 검색을 수행합니다. 어떤 모드든 사용자가 말한 내용은 작업 중인 화면 하단에 큼직한 자막으로 실시간 표시됩니다. |
| **기억하기 (Remembers)** | FTS5 전체 텍스트 검색을 지원하는 SQLite와 온디바이스 쿼리 확장을 탑재하여 정확한 단어가 아니더라도 문맥 의미로 검색할 수 있습니다. |
| **조언하기 (Advises)** | 온디바이스 모델이 모든 스캔을 1차 선별(트리아지)하여 기본적으로 침묵을 유지합니다. 게이트를 통과한 중요한 이벤트만 클라우드 모델로 전달됩니다. 채팅에서 '**화면 지켜보기(Watch my screen)**'를 켜면 타이머 주기로 화면 이미지 자체를 분석하여 실수, 오류, 위험, 더 빠른 방법을 발견했을 때만 조언합니다 (기본값 꺼짐, 앱 재실행 시 항상 꺼진 상태로 시작). |
| **보여주기 (Shows)** | ✨ 메뉴바 아이콘이나 ⌥Space 단축키로 즉시 열리는 채팅 창. 답변과 에이전트의 자체 관찰 내용이 단일 스레드로 정리됩니다. 메뉴바 팝오버뿐 아니라 전체 화면 앱 위에도 항상 표시되고 에디터 포커스를 뺏지 않으며 클릭 관통이 가능한 플로팅 `NSPanel` 오버레이를 제공합니다. |
| **공유하기 (Shares)** | 로컬에 기록된 컨텍스트 및 GUI 자동화 툴 세트(`computer`, `click_element`, `run_applescript`, `inspect_ui_elements`, `typesafe_act`)를 MCP(Model Context Protocol) 서버로 외부에 노출하여 Claude Code, Codex 등 다른 개발 에이전트와 연동합니다. Mac이나 브라우저를 조작하는 도구는 `config.json`에 `"mcpAllowDangerousTools": true`를 설정하지 않으면 MCP를 통해 거부됩니다. |

---

## 요구 사항

- macOS 26 이상, Apple Silicon Mac
- Xcode 26.6+ / Swift 6.2+
- (선택 사항) Gemini, Anthropic, OpenAI 호환, 또는 TypeSafe AI API 키. 키가 없어도 화면 기록, 검색, 로컬 GUI 판정은 정상 동작합니다.

## 빌드 방법

```bash
./Scripts/bundle.sh
open build/MyComputerAgent.app
```

앱 번들 생성(`bundle.sh`)은 필수입니다. macOS는 서명된 번들 식별자에 권한을 부여하고 `Info.plist`에서 권한 안내 문구를 읽어오며, 서명되지 않은 바이너리에서는 `AudioHardwareCreateProcessTap`이 **안내 창도 띄우지 않고 즉시 실패**하여 앱 버그처럼 보이기 때문입니다.

배포용 빌드는 Developer ID 인증서를 지정합니다: `./Scripts/bundle.sh "Developer ID Application: …"`.

### 실행 중인 앱에 변경 사항 반영하기

```bash
./Scripts/run.sh          # 번들 재빌드 후 기존 프로세스를 종료하고 재실행
```

`swift build` 후 `open`을 실행하는 방식은 권장되지 않습니다 (다음 2가지 이유로 정상 반영되지 않습니다):

- `swift build`는 `.build/<config>/mca`만 생성합니다. 이를 `build/MyComputerAgent.app`으로 복사하는 것은 `Scripts/bundle.sh`뿐이며, 일반 빌드/테스트 단계에서는 번들을 갱신하지 않으므로 변경된 코드가 반영되지 않고 이전 번들 바이너리가 계속 실행됩니다.
- 본 앱은 `LSUIElement`(메뉴바 상주형)입니다. 상주형 앱에 `open`을 호출하면 재실행이 아니라 '다시 열기(reopen)' 이벤트로 처리되어 `applicationShouldHandleReopen`이 호출되어 설정 창만 뜨고 이전 프로세스가 그대로 유지됩니다. 반드시 기존 프로세스를 먼저 종료해야 합니다.

## 초기 설정

앱을 실행한 후, ✨ 메뉴바 아이콘 ▸ **Settings…(설정…)**에서 설정을 완료합니다. 아래 두 단계는 반드시 실행 중인 앱 UI 내부에서 수행해야 하며, 터미널에서는 정상 동작하지 않습니다:

1. **권한 승인** — 손쉬운 사용(Accessibility), 화면 기록(Screen Recording), 마이크(Microphone), 오디오 캡처(Audio Capture).
   macOS는 권한 요청 창을 띄운 주체 프로세스에 권한을 부여합니다. 터미널에서 `mca doctor` 등으로 승인하면 권한이 Terminal.app에 부여되어 실제 에이전트 앱에는 권한이 남지 않습니다. 또한 macOS는 앱 식별자당 한 번만 창을 띄우므로, 이후에는 '시스템 설정 ▸ 개인정보 보호 및 보안'에서 설정해야 합니다. 설정 창의 권한 탭에서 해당 설정 페이지로 즉시 이동하는 딥링크를 제공하며 스위치 상태가 실시간 반영됩니다.
2. **모델 및 API 키** — Gemini API 키를 붙여넣습니다. 키는 후술할 Secure Enclave 기반 HPKE 암호화로 안전하게 저장되며, 앱 자체가 키체인 항목을 소유하므로 '접근을 허용하겠습니까?' 대화상자 없이 즉시 읽어옵니다. 키 추가는 앱 재실행 없이 즉시 적용됩니다.

`mca auth set gemini` CLI 명령어 또한 동작하지만, 이 경우 키체인 소유권이 CLI 바이너리에 귀속되어 앱에서 처음 읽을 때 macOS 권한 확인 창이 뜨게 됩니다 (백그라운드 에이전트에서는 놓치기 쉽고 키가 없는 것처럼 보일 수 있습니다).

### API 키 저장 방식

키체인에 평문(Plaintext)으로 저장하지 않습니다. 각 API 키는 **이 Mac의 Secure Enclave 내부에서 생성된 P-256 키**를 사용하여 **HPKE**(RFC 9180, `P256_SHA256_AES_GCM_256`)로 암호화(봉인)된 후, 암호문만 로그인 키체인에 저장됩니다.

키체인 자체도 사용자 로그인 비밀번호로 암호화되지만, `login.keychain-db` 파일과 비밀번호가 탈취되면 복호화될 수 있습니다. 반면 Secure Enclave의 개인키는 칩 밖으로 절대 반출되지 않고, 비밀번호에서 파생된 것도 아니며, 내보내기도 불가능하므로 공격자가 암호문과 로그인 비밀번호를 모두 가졌더라도 다른 Mac에서는 복호화가 불가능합니다. 또한 프로바이더 이름을 AAD(추가 인증 데이터)로 묶어 두어 한 프로바이더의 암호문을 다른 프로바이더 슬롯으로 조작 이동할 수 없습니다.

알아두어야 할 두 가지 동작:

- **이전 빌드에서 평문으로 작성된 키는 자동 마이그레이션됩니다**: 처음 읽을 때 값을 가져온 후 Secure Enclave를 통해 제자리에서 재암호화하여 저장합니다. 별도 조치가 필요 없습니다.
- **Mac을 초기화하거나 Secure Enclave를 리셋하면 저장된 키를 읽을 수 없게 됩니다**: 보안 설계상 기기에 영구 바인딩되어 있기 때문입니다. 설정 창에서 키를 다시 입력해야 하며, 앱은 '키 없음' 대신 재입력 안내를 표시합니다.

Apple의 최신 데이터 보호 키체인(`kSecUseDataProtectionKeychain`)은 의도적으로 사용하지 않습니다. 프로비저닝 프로파일이 필요한 `com.apple.application-identifier` / `keychain-access-groups` 엔타이틀먼트에 묶여 있기 때문입니다. 본 앱은 샌드박스를 해제하고 프로파일 없이 배포되므로 `SecItemAdd` 호출 시 `-34018 errSecMissingEntitlement` 오류가 발생합니다. CryptoKit의 Secure Enclave 키는 키체인 내부에 키 자체를 보관하지 않고 앱이 불투명한 래핑 블롭을 직접 영속화하므로 이러한 제약이 없습니다.

Secure Enclave가 없는 Mac(Intel Mac 등)에서는 소프트웨어 래핑 키로 자동 폴백하며, 설정 화면에 주황색 경고를 표시하여 지원하지 않는 하드웨어 보안을 허위로 표시하지 않습니다.

앱을 재서명하면 바이너리 ID가 변경되어 macOS가 새 앱으로 인식하고 권한을 다시 요청합니다. 임시(ad-hoc) 서명 대신 정식 개발자 인증서로 서명하면 이를 방지할 수 있습니다 (`Scripts/bundle.sh`가 인증서를 자동 감지합니다).

```bash
build/MyComputerAgent.app/Contents/MacOS/mca doctor   # 읽기 전용 상태 진단
```

## CLI 명령어

```
mca run       코파일럿 및 플로팅 오버레이 실행 (기본값)
mca doctor    권한, 모델, 저장소, 라우팅 상태 진단
mca listen    지정 시간 동안 양방향 오디오를 캡처 및 전사하여 출력
mca capture   현재 포커스된 창의 접근성 텍스트를 1회 읽어 출력
mca ask       현재 데스크톱 컨텍스트를 포함하여 단발성 질문 실행
mca act       TypeSafe Jev / 로컬 그라운딩을 이용해 화면 조작 자동 실행
mca search    기록된 히스토리 검색
mca mcp       표준 입출력(stdio)을 통해 MCP 서버 실행 (컨텍스트 및 GUI 조작 도구 제공)
mca auth      프로바이더 API 키(gemini, anthropic, openai-compatible, typesafe)를 키체인에 안전하게 저장
mca setup     권한 설정 마법사 열기 (✨ ▸ Permissions 권장)
mca reset-permissions
              앱의 TCC 권한을 초기화하여 macOS 권한 대화상자 재표시
```

## 채팅 창

`⌥Space`, 패널/팝오버의 **Chat** 버튼 또는 ✨ ▸ **Open the Chat…**으로 실행합니다. 화면 중앙 최상단에 나타나며 텍스트 필드에 즉시 캐럿이 위치합니다.

의도적으로 모달 창(`NSApp.runModal`)으로 구현하지 않았습니다. 모달 창은 화면을 어둡게 만들어 강제적인 압박감을 줄 뿐만 아니라, 메인 액터에서 동작하는 선제적 스캔, 화면 지켜보기, 메뉴바, 전역 단축키 이벤트 루프를 모두 멈추게 만들고 질문하려는 작업 창 접근까지 차단하기 때문입니다. Escape 키로 즉시 닫을 수 있으며 배경 작업은 방해받지 않습니다.

- **화면 지켜보기 (Watch my screen)** — 기본값 꺼짐. 활성화하면 지정 주기(15초 / 45초 / 2분)마다 포커스된 창을 살펴보고 실수, 에러, 위험, 더 효율적인 작업 방법을 발견했을 때만 말을 겁니다. 스레드 하단 상태 줄에 마지막 실행 결과가 표시되므로 조용히 지켜보는 중인지 문제가 발생했는지 쉽게 구분할 수 있습니다.
- **지켜볼 대상 선택 (📌)** — 화면 선택기를 엽니다: 활성 창 자동 추적, 특정 창 고정(Pin), 또는 모니터 화면 전체 고정. 고정된 대상은 윈도우 스택 순서와 무관하게 백그라운드에서도 지속적으로 감시되므로, 다른 작업을 하면서 백그라운드 빌드가 끝나는 순간을 지켜볼 수 있습니다. 또한 질문을 위해 채팅 창을 열어도 포커스 추적이 풀리지 않습니다. `⌥⌘W`를 누르면 선택기를 열지 않고도 현재 작업 창을 즉시 고정할 수 있으며, 다시 누르면 해제됩니다.
  
  창 고정과 모니터 화면 고정은 동작 방식이 다릅니다. '창 고정'은 창을 어디로 드래그하든 해당 창의 내용물을 따라다니며, '디스플레이 고정'은 책상의 특정 모니터 영역을 고정하여 그 위에 나타나는 모든 창을 감시합니다 (타이핑하지 않는 서브 모니터를 감시할 때 유용합니다).
- **설명하기 (Explain)** — 동일한 메커니즘의 단발성 실행입니다. 현재 선택된 대상을 캡처하여 즉시 설명합니다. 고정된 대상이 없으면 마우스 커서가 위치한 모니터를, 창이 고정되어 있으면 해당 창을 분석합니다. 이미지 기반으로 분석하므로 접근성 트리가 제공되지 않는 Canvas 렌더링 앱(다이어그램 도구, PDF, 화상 회의 등)에서도 완벽하게 작동합니다.

이전 스캔 이후 변경이 없는 화면, 제외 목록에 등록된 앱, 본 에이전트 자신의 창, 또는 답변이 스트리밍 중일 때는 불필요한 요청을 보내지 않습니다. 3회 연속 실패 시 감시를 중단하고 이유를 안내합니다.

고정된 대상은 텍스트가 아닌 이미지로 변경 여부를 비교합니다 (비활성 창에는 읽을 수 있는 접근성 트리가 없기 때문입니다). 따라서 내용이 변경되지 않았을 때는 스크린샷과 해시 연산만 수행되며 OCR 및 모델 호출 비용이 전혀 들지 않습니다. 비교 알고리즘은 32×32 그레이스케일 축소 및 8단계 양자화로 정밀하게 튜닝되어, 깜빡이는 텍스트 커서는 무시하고 빌드 완료와 같은 실제 의미 있는 변화만 정확하게 감지합니다.

디스플레이 전체를 고정 감시할 때는 특정 앱 단위 스킵이 불가능하므로, 캡처 내부에서 `SCContentFilter`를 사용하여 제외된 앱의 창을 프레임 합성 단계에서 완전히 배제합니다. 패스워드 관리자 등이 고정된 모니터에 떠 있더라도 캡처 이미지 자체에 포함되지 않습니다.

## 화면 선택기 (Screen Picker)

화면 공유 대화상자와 유사한 실시간 썸네일 그리드(창 목록 및 디스플레이 목록)를 제공합니다. 패널/팝오버의 **Screen** 버튼, 채팅 툴바의 📌 버튼, 또는 ✨ ▸ **Choose a Screen to Watch…**에서 엽니다. 타일을 클릭하여 선택하고, 더블 클릭하거나 **Watch this**를 눌러 적용합니다. 감시가 꺼져 있었다면 선택과 동시에 자동으로 감시가 시작됩니다.

텍스트 제목만 나열하던 기존 방식과 달리, 썸네일을 통해 여러 개의 Chrome 창이나 제목이 잘린 터미널 창도 시각적으로 즉시 식별할 수 있습니다.

썸네일은 선택기 창이 열려 있는 동안에만 3초마다 갱신되며, 창을 닫으면 완전히 중단됩니다. 썸네일은 식별 목적이므로 본 캡처보다 훨씬 작은 저해상도로 가볍게 캡처됩니다. 모든 프리뷰 역시 개인정보 필터를 거치며, 선택기 창 자체도 `sharingType = .none`으로 설정되어 거울 효과(무한 캡처 루프)를 방지합니다.

## 메뉴바 아이콘

Dock 아이콘 없이 상단 메뉴바의 ✨ 아이콘이 앱의 기본 인터페이스 역할을 합니다.

- **좌클릭**: 상태 아이콘 바로 아래에 코파일럿 패널 팝오버를 엽니다. 조언 카드, 질문 입력 필드, 현재 상태를 확인합니다. 다른 곳을 클릭하면 즉시 닫혀 작업 공간을 침범하지 않습니다. 카드에 마우스를 올리면 ✕ 버튼이 나타나 개별 카드를 숨길 수 있습니다 (채팅 스레드에는 영구 보관됩니다).
- **우클릭**(또는 ⌃+클릭): 기능 메뉴를 엽니다.

패널이 닫혀 있을 때 새 조언 카드가 도착하면 미확인 배지가 표시되며, 장애가 발생한 서브시스템은 메뉴 최상단에 붉은색으로 안내됩니다.

- **Keep Overlay On Screen (화면에 항상 오버레이 유지)** — 기본값 꺼짐. 켜면 팝오버 대신 화면 모서리의 플로팅 윈도우로 전환됩니다.
- **Float Above Other Windows (최상단 고정)** — 끄면 일반 윈도우처럼 활성 창 뒤로 내려갑니다.
- **Collapse to Pill (알약 모양 최소화)** — 얇은 타이틀바로 축소합니다.
- **Click-Through (클릭 관통)** — 기본값 꺼짐. 켜면 윈도우 레벨에서 `ignoresMouseEvents`가 활성화되어 오버레이 상의 모든 클릭이 배경 앱으로 관통합니다. 모니터링용 읽기 전용 HUD로 사용할 때 적합합니다.
- **Position (위치)** — 상/하, 좌/우 모서리 배치 및 자유로운 드래그 이동 지원 (이동된 위치 기억).
- **Settings… / Permissions… / Quit Copilot**

## 언어 및 음성 인식 설정

본 앱은 **영어, 일본어, 한국어** 3개 언어를 공식적으로 완전 지원합니다. **Settings ▸ General ▸ Language**(설정 ▸ 일반 ▸ 언어)에서 설정할 수 있습니다.

**Interface (인터페이스 언어)** — English, 日本語, 한국어, 또는 *Match macOS*(macOS 기본 언어 설정 따르기, 기본값). 한 번의 설정으로 두 가지가 동기화됩니다:

- UI 전체 언어 — 메뉴바, 설정 창, 오버레이, 권한 안내 창.
- 에이전트가 답변과 조언 카드를 작성하는 언어 — 별도 번역 단계를 거치는 대신 시스템 프롬프트에 응답 언어 지침을 직접 주입하므로, 코드 블록이 깨지지 않고 추가 토큰 비용도 발생하지 않습니다.

**Engine (음성 전사 엔진)** — 음성 입력 및 텍스트 변환 백엔드를 선택합니다:

- **Gemini Flash (Cloud / High Accuracy)**: Google Gemini Flash 멀티모달 AI를 활용한 고속 배치 전사. 매우 높은 인식률을 자랑하며 한국어/일본어의 동음이의어 오인식을 문맥에 맞게 정확히 교정하고 불필요한 추임새("어...", "음...")를 자동으로 정제합니다.
- **macOS (On-Device / Private)**: Apple 기본 온디바이스 `SpeechAnalyzer`. 음성 데이터가 기기 밖으로 일절 전송되지 않아 완전한 오프라인 프라이버시가 보장됩니다.

**Speech (말하는 언어)** — 마이크 입력을 전사할 언어를 지정합니다: *Automatic*(기본값), English, 日本語, 한국어. 앱 UI는 영어로 보면서 음성 질문은 한국어로 하는 일반적인 사용 패턴을 지원하기 위해 UI 언어와 독립적으로 분리되어 있습니다.

*Automatic*은 '현재 인터페이스 언어를 따른다'는 의미이며, '말하는 언어를 실시간 자동 판별한다'는 뜻이 **아닙니다**. `SpeechTranscriber`는 단일 로케일로 초기화되며 자체 언어 식별 기능이 없기 때문에, 실시간 언어 감지를 하려면 여러 언어 모델을 동시 실행해야 하여 배터리 소모가 극심해집니다. 따라서 실제 적용된 언어는 선택기 아래(예: `Automatic → 한국어 (ko-KR)`), 화면 하단 대형 자막, 채팅 음성 바 등에 명확히 표시됩니다. 또한 설정 창에는 해당 언어 모델이 설치되었는지, 다운로드 가능한지 실시간 안내됩니다.

둘 다 Automatic으로 설정하면 음성 로케일은 `Locale.current`를 유지합니다. 모든 변경 사항은 재실행 없이 즉시 적용됩니다.

macOS 시스템 오류 메시지와 `mca` CLI 명령어 체계는 검색과 표준화를 위해 영문으로 유지됩니다.

## 단축키 (Shortcuts)

기본 단축키: `⌥Space` 질문하기 · `⌥⌘H` 오버레이 켜기/끄기 · `⌥⌘J` 최소화/확장 · `⌥⌘X` 클릭 관통 전환 · `⌥⌘V` 음성 세션 시작/종료 · `⌥⌘W` 현재 창 고정 감시.

- `⌥Space`: 오버레이 상태와 무관하게 화면 중앙에 채팅 창을 열고 입력 필드에 포커스를 줍니다.
- `⌥⌘W`: 현재 작업 중인 창을 즉시 고정 감시 대상으로 등록하며, 감시가 꺼져 있었다면 함께 시작합니다. 창 닫기 단축키 `⌘W`와 충돌하지 않도록 Option 키 조합으로 안전하게 처리됩니다.
- 음성 모드는 두 개의 버튼으로 나뉩니다: **받아쓰기 (마이크)** 및 **Live 대화 (파형)**. 한 번 누르면 시작, 다시 누르면 종료되며 중간에 다른 버튼을 눌러 전환할 수 있습니다.
- `⌥⌘V`: 가장 최근에 사용한 음성 모드를 즉시 시작/종료합니다.

모든 단축키는 **Settings ▸ Shortcuts**에서 변경할 수 있습니다. 다른 앱과의 단축키 충돌 감지 및 중복 방지 기능이 내장되어 있습니다.

## 발화 내용 실시간 시각화

음성은 키보드 입력과 달리 눈으로 확인하기 어려우므로, 인식된 발화 내용은 다음 3곳에 동시에 표시됩니다:

1. 작업 중인 화면 하단에 큼직하게 표시되는 실시간 자막
2. 채팅 창 상단 음성 바
3. 발화 종료 후 채팅 스레드 내 사용자 메시지로 자동 등록

확정된 텍스트와 현재 엔진이 추측 중인 미확정 텍스트는 불투명도(100% vs 50%)를 다르게 하여 렌더링됩니다. 받아쓰기 모드에서는 인식 언어 태그가 함께 표시되어 잘못된 언어 설정으로 인한 오인식을 즉시 파악할 수 있습니다. 대형 자막은 **Settings ▸ General ▸ Voice**에서 비활성화할 수 있습니다.

---

## 아키텍처

엄격한 단방향 의존성을 가진 7개 SwiftPM 타깃으로 구성됩니다:

```
mca (composition root)
 ├── MCAPresentation   NSPanel HUD, SwiftUI, 전역 단축키
 ├── MCAInterop        MCP 서버 / 클라이언트
 ├── MCARealtime       Gemini Live 음성 세션, GeminiTranscriber (배치 전사), WAVEncoder
 ├── MCAReasoning      프로바이더 추상화, 라우팅, 도구 실행, 에이전트
 ├── MCAMemory         SQLite + FTS5 전체 텍스트 검색, 하이브리드 검색
 ├── MCAPerception     VAD (음성 활동 감지), 온디바이스 STT, Vision OCR
 ├── MCASensing        ScreenCaptureKit, AXUIElement, CoreAudio 탭, VPIO
 └── MCACore           값 타입, 헬스 레지스트리, 링 버퍼, 다국어 로컬라이제이션
```

### 3대 핵심 설계 제약

1. **오디오 경로는 프로세스 경계를 넘지 않는다**: CoreAudio의 I/O 콜백은 메모리 할당, 락, IPC가 금지된 실시간 스레드에서 실행됩니다. 따라서 Python이나 Node 사이드카를 배제하고, 음성 중간 인터럽트(< 100ms 버지인)를 포함한 모든 처리를 프로세스 내에서 직접 수행합니다.
2. **LLM 경로는 네트워크 병목을 기본 전제로 한다**: 최초 토큰 생성까지 300~800ms가 소요되므로, 과도한 저수준 최적화보다는 확장성과 유연성을 최우선으로 설계했습니다.
3. **상시 감시는 비용이 거의 들지 않아야 한다**: 5초마다의 전체 스캔을 클라우드 모델로 보내면 막대한 비용이 발생합니다. 온디바이스 모델의 1차 트리아지 게이트를 통해 약 2%의 유의미한 변화만 클라우드로 전달하여 실행 비용을 획기적으로 절감합니다.

### 멀티 프로바이더 라우팅

Gemini, Anthropic, OpenAI 호환(Ollama, LM Studio, vLLM, Groq, OpenRouter 등), Apple 온디바이스 모델이 모두 단일 `LanguageModelExecuting` 프로토콜을 구현합니다.

| 작업 | 모델 | 비고 |
|---|---|---|
| `triage` (1차 선별) | Apple 온디바이스 | 완전 무료, 상시 로컬 실행 |
| `classify` (분류) | `gemini-3.8-flash` | `thinkingLevel: minimal` |
| `answer` / `vision` (답변 및 이미지 분석) | `gemini-3.8-flash` | 기본 추론 |
| `hardReasoning` (고난도 추론) | `gemini-3.8-flash` | 명시적 요청 시, `thinkingLevel: high` |

모델 ID와 토큰 예산은 `~/Library/Application Support/MyComputerAgent/config.json`에 저장되어 재컴파일 없이 변경할 수 있습니다.

### 보안 및 개인정보 보호 (Security & Privacy)

MyComputerAgent는 철저한 **제로 트러스트, 로컬 우선(Zero-Trust, Local-First)** 보안 및 프라이버시 아키텍처를 기반으로 설계되었습니다. 상세 보안 정책 및 취약점 제보 절차는 [SECURITY.ko.md](SECURITY.ko.md) 문서를 참고해 주세요.

- **하드웨어 기반 비밀정보 암호화**: 설정 화면에서 입력된 API 키는 Apple Silicon의 **Secure Enclave(SEP)** 내에서 생성된 P-256 키에 **HPKE (RFC 9180, `P256_SHA256_AES_GCM_256`)** 방식으로 암호화(밀봉)되어 저장됩니다. 평문 키는 디스크나 평문 키체인에 절대 저장되지 않습니다.
- **패스워드 관리자 윈도우 사전 차단**: 1Password, Bitwarden, Keychain Access, LastPass, KeePassXC 등 주요 비밀번호 관리 프로그램 창은 화면 캡처 및 접근성 검사 대상에서 원천 배제되어 메모리나 디스크에 남지 않습니다.
- **보안 텍스트 보호**: `AXSecureTextField`(비밀번호 입력 필드)의 내용은 일절 읽지 않습니다.
- **실시간 개인정보 및 토큰 마스킹**: 모델로 전송되는 모든 UI 요소 텍스트는 정규식 새니타이저를 거쳐 API 키, 베어러 토큰, 카드 번호 등이 자동으로 마스킹 처리됩니다.
- **자가 감시 루프 방지**: 코파일럿 자체의 PID 및 윈도우(HUD, 채팅 창)는 `sharingType = .none`으로 보호되어 화면 제어 및 OCR 과정에서 자기 자신을 재귀 인식하거나 응답을 환각하는 루프를 차단합니다.
- **앱 시작 시 마이크 완전 차단**: 앱 실행 시점에는 마이크가 완전히 꺼져 있습니다. 사용자가 명시적으로 음성 대화(⌥⌘V)를 시작할 때만 열리며 세션 종료 즉시 닫힙니다.
- **표준 입출력(stdio) 기반 MCP 서버**: 외부 AI 에이전트(Claude Code, Codex 등) 연동용 MCP 서버는 로컬 표준 입출력 파이프로만 통신하며 로컬 네트워크 포트를 외부에 노출하지 않습니다.

---

## 테스트

```bash
swift test
```

**총 48개 스위트, 354개**의 단위 및 통합 테스트 포함:

- **Executor 계약 테스트**: 모의 객체(Mock)와 실제 프로바이더(Gemini, Anthropic, Apple)가 동일한 규격을 준수하는지 검증.
- **와이어 포맷 검증**: 각 프로바이더의 요청 인코딩(Gemini의 thinkingLevel, Anthropic의 tool_use, OpenAI 파라미터 등)을 네트워크 없이 검증.
- **실제 SQLite 검증**: 인메모리가 아닌 실제 파일과 FTS5 트리거를 대상으로 데이터베이스 무결성 테스트.
- **동시성 검증**: 링 버퍼에서 10만 프레임 규모의 동시 생산자/소비자 스트레스 테스트.
- **발화 경계 테스트**: 받아쓰기 질문의 시작과 끝을 판단하는 `DictationBuffer` 경계 조건 검증.
- **데스크톱 자동화 및 UI 판정 검증**: AccessibilityInspector의 자가 프로세스 배제, TypeSafe Jev 추론 엔진 및 로컬 시맨틱 매칭 폴백 검증.

---

## 알려진 제한 사항

- 로컬 1차 트리아지 게이트를 사용하려면 Apple Intelligence가 활성화되어 있어야 합니다. 미지원 환경에서는 클라우드 모델로 폴백되어 실행 비용이 증가합니다 (`mca doctor`로 확인 가능).
- 화자 분리는 채널 단위(사용자 vs 상대방)로 이루어집니다. 상대방 측 여러 화자를 구분하려면 별도의 다이어라이제이션 모델이 필요합니다.
- Live 음성 세션의 음성 출력 디코딩은 완료되었으며, 오디오 출력 장치로의 다이렉트 라우팅은 순차 업데이트될 예정입니다.

---

## 문서

- [사용자 매뉴얼](docs/manual/MANUAL.ko.md) ([English](docs/manual/MANUAL.md) • [日本語](docs/manual/MANUAL.ja.md))
- [기여 가이드라인](CONTRIBUTING.ko.md) ([English](CONTRIBUTING.md) • [日本語](CONTRIBUTING.ja.md))
- [보안 정책](SECURITY.ko.md) ([English](SECURITY.md) • [日本語](SECURITY.ja.md))
- [행동 강령](CODE_OF_CONDUCT.ko.md) ([English](CODE_OF_CONDUCT.md) • [日本語](CODE_OF_CONDUCT.ja.md))

---

## 기여하기 (Contributing)

버그 제보, 기능 개선 제안, 풀 리퀘스트를 환영합니다! 기여하기 전에 [기여 가이드라인](CONTRIBUTING.ko.md) 및 [행동 강령](CODE_OF_CONDUCT.ko.md)을 확인해 주세요.

1. 저장소를 포크하고 작업 브랜치를 생성합니다 (`git checkout -b feature/my-feature`).
2. 프로젝트 아키텍처 규약을 준수하며 기능을 구현합니다:
   - 레이어 의존성 순서 준수 (`Core` → `Sensing` → `Perception` → `Memory` → `Reasoning` → `Realtime` → `Interop` → `Presentation`).
   - 평문 비밀정보 하드코딩 금지 (`SecretStore` 활용).
   - 신규 기능에 대한 유닛 테스트 추가.
3. PR 제출 전 반드시 품질 게이트를 통과해야 합니다:
   ```bash
   ./Scripts/gate.sh
   ```
4. [Pull Request 템플릿](.github/PULL_REQUEST_TEMPLATE.md)에 맞추어 변경 사항과 테스트 검증 결과를 상세히 기술하여 PR을 제출합니다.

---

## 라이선스 (License)

- **프로젝트 라이선스**: 본 프로젝트는 **MIT 라이선스**에 따라 배포됩니다. 자세한 내용은 [LICENSE](LICENSE) 파일을 참조하세요.
- **서드파티 고지**: 사용하는 오픈소스 라이브러리(`swift-sdk`, `eventsource`, Apple Swift 패키지)의 라이선스 및 저작권 고지는 [NOTICES.md](NOTICES.md)를 참조하세요. `Scripts/bundle.sh`는 `LICENSE`와 `NOTICES.md`를 `MyComputerAgent.app/Contents/Resources/`에 복사합니다.
- **보안 정책**: 취약점 제보 및 보안 정책은 [SECURITY.md](SECURITY.md)를 참조하세요.

Copyright (c) 2026 buddypia / MyComputerAgent Contributors.
