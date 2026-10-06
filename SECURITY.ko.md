[English](SECURITY.md) • [日本語](SECURITY.ja.md) • [한국어](SECURITY.ko.md)

# 보안 및 프라이버시 정책

## 지원 버전

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

---

## 보안 취약점 신고

저희는 **MyComputerAgent (MCA)**의 보안과 프라이버시를 매우 중요하게 생각합니다. 보안 취약점이나 프라이버시 결함을 발견했다고 생각되면 신속히 신고해 주세요.

### 신고 방법
- 취약점은 **GitHub Private Vulnerability Reporting**(저장소의 **Security** 탭 ▸ **Report a vulnerability**)으로 비공개로 신고해 주세요.
- 다음 내용을 포함해 주세요.
  - 취약점에 대한 설명과 예상되는 영향.
  - 단계별 재현 방법 또는 개념 증명(PoC).
  - 환경 정보(macOS 버전, 하드웨어 모델, 앱 버전).

검토와 조치가 끝나기 전까지는 보안 취약점을 공개 GitHub issue, discussion, pull request로 신고**하지 마세요**.

신고 접수는 48시간 이내에 회신드리며, 예상 조치 일정도 함께 안내해 드립니다.

---

## 보안 및 프라이버시 아키텍처

`MyComputerAgent`는 처음부터 **로컬 우선(local-first)이며 프라이버시를 보호하는 데스크톱 코파일럿**으로 설계되었습니다. 사용자의 프라이버시와 자격 증명을 보호하기 위해 다층 방어(defense-in-depth) 방식의 아키텍처 보호 장치를 갖추고 있습니다.

### 1. 하드웨어 기반 암호화 키 저장소 (`SecretStore`)
- **Secure Enclave 바인딩**: 설정에서 입력한 프로바이더 API 키는 Apple Silicon의 **Secure Enclave Processor (SEP)** 안에서 생성된 P-256 키에 대해 **HPKE (RFC 9180, `P256_SHA256_AES_GCM_256`)**로 봉인됩니다(Secure Enclave가 없는 Mac에서는 소프트웨어 키를 사용하며 설정 화면에 그 사실을 표시합니다).
- **보호하는 것과 보호하지 못하는 것**: 래핑 키는 내보낼 수 없고 기기에 묶여 있으므로(`ThisDeviceOnly`), 복사된 keychain 파일, 로그인 keychain 백업, 저장된 암호문을 다른 기기에서 복호화할 수 없습니다. 반면 **같은 Mac에서 같은 사용자로 실행되는 소프트웨어에 대한 방어는 아닙니다**. 에이전트가 백그라운드에서 동작할 수 있도록 키는 의도적으로 `userPresence` 없이(Touch ID 프롬프트 없이) 생성되며, keychain 항목도 앱의 코드 서명에 묶여 있지 않습니다. 사용자 세션에서 keychain 항목을 읽고 Secure Enclave 키를 사용할 수 있는 프로세스는 API 키의 봉인을 풀 수 있습니다.
- **디스크에 평문 없음**: 평문 자격 증명은 디스크, SQLite 데이터베이스, 암호화되지 않은 keychain 항목 어디에도 기록되지 않습니다.
- **프로바이더 인증 바인딩**: 벤더 이름(`gemini`, `anthropic`, `openai-compatible`, `typesafe`)이 **Authenticated Additional Data (AAD)**로 바인딩됩니다. 암호문 레코드를 다른 프로바이더로 옮길 수 없습니다.
- **휘발성 환경 변수 우선**: 개발용으로 `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `TYPESAFE_API_KEY`를 일시적인 환경 변수로 제공할 수 있습니다. 이 값은 런타임에 우선 적용되며 저장소에 영속화되지 않습니다.

### 2. 제로 트러스트 방식의 사전 캡처 및 전송 중 프라이버시 필터링 (`PrivacyFilter`)
- **자격 증명 관리자 제외**: 비밀번호 관리자(`1Password`, `Bitwarden`, `Apple Keychain Access`, `LastPass`, `KeePassXC` 포함)에 속한 윈도우는 윈도우 캡처와 접근성 검사에서 엄격하게 차단됩니다.
- **보안 텍스트 필드 제거**: `AXSecureTextField`로 표시된 UI 요소(비밀번호 및 시크릿 입력란)는 모델이 평가하기 전에 후보 트리에서 자동으로 제거됩니다.
- **PII 및 토큰 마스킹**: 전송 중인 UI 레이블과 캡처된 값은 정규식 기반 sanitizer를 거쳐 API 키, bearer 토큰, authorization 헤더, 신용카드 번호가 마스킹된 뒤에 추론 모델에 전달됩니다.
- **자기 검사 제외**: 에이전트는 자신의 프로세스 ID(PID)를 자동으로 식별하여 자기 윈도우의 검사를 거부합니다. 이를 통해 재귀 호출이나 어시스턴트 응답이 의도치 않게 반사되는 것을 방지합니다.

### 3. 로컬 우선이며 사용자가 제어하는 센싱
- **시작 시 마이크 OFF**: 마이크는 시작 시 절대 열리지 않습니다. 명시적인 음성 세션(예: ⌃⌥V) 동안에만 열리고, 세션이 끝나면 즉시 닫힙니다.
- **독립된 이중 오디오 채널**: 마이크 입력(하드웨어 AEC)과 시스템 오디오(CoreAudio process tap)는 서드파티 가상 오디오 드라이버 없이 분리된 오디오 파이프라인에서 처리됩니다.
- **온디바이스 음성 및 비전**: 온디바이스 음성 인식(`SpeechAnalyzer`)과 Vision OCR 덕분에, Apple 엔진을 사용하는 동안 음성과 화면 텍스트는 Mac 안에만 머뭅니다.
- **Gemini 엔진 사용 시 음성은 Google로 전송됩니다**: 기본 전사 엔진은 Gemini(클라우드)입니다. 이 엔진을 사용할 때와 라이브 음성 세션(`GeminiLiveSession`)에서는 캡처된 마이크/시스템 오디오가 전사를 위해 Google Gemini로 스트리밍됩니다. 오디오를 Mac 밖으로 내보내지 않으려면 설정에서 Apple 엔진을 선택하세요. 화면에 대해 질문하면 스크린샷과 인식된 화면 텍스트도 설정한 모델 프로바이더로 전송됩니다.
- **시작 시 화면 감시 OFF**: 백그라운드 화면 관찰은 애플리케이션 시작 시 비활성 상태이며, 세션마다 명시적으로 활성화해야 합니다.

### 4. IPC 및 네트워크 경계
- **stdio 전용 MCP 서버**: Model Context Protocol (MCP) 서버는 로컬 에이전트(Claude Code, Codex CLI 등)와의 통신에 표준 입출력(stdio)만 사용합니다. 로컬 네트워크에서 인증 없는 수신 대기 TCP 포트나 web socket을 열지 않습니다.
- **매개변수화된 데이터베이스 쿼리**: 컨텍스트 메모리는 WAL 모드의 온디바이스 SQLite 데이터베이스(`~/Library/Application Support/MyComputerAgent/context.sqlite3`)에 저장됩니다. 전문 검색(FTS5)과 벡터 메타데이터 쿼리는 모두 엄격한 매개변수 바인딩(`sqlite3_bind_*`)을 사용하여 인젝션 공격을 방지합니다.
- **암호화된 모델 통신**: 클라우드 모델과의 모든 상호작용은 TLS/HTTPS와 인증된 WebSocket(WSS)을 엄격하게 강제합니다.

### 5. 위험한 작업 전 확인 (`ToolApproving`)
- **신뢰할 수 없는 내용은 데이터**: 화면, OCR, 접근성 레이블, 웹 페이지, 도구 결과의 텍스트는 간접 프롬프트 인젝션을 담을 수 있으므로 시스템 프롬프트에서 지시가 아닌 신뢰할 수 없는 데이터로 취급합니다.
- **승인 게이트**: `run_applescript`, `write_file`, `open_file`, `browser_evaluate`, 그리고 `path`를 지정한 `browser_read`(모델이 고른 위치에 스크린샷을 저장)는 실제 스크립트·JavaScript·경로·내용을 보여 주는 `ToolApproving` 게이트를 거칩니다. 앱은 모달 알림(기본 버튼은 '허용 안 함')으로 묻고, `mca ask`는 터미널에서 y/N을 묻되 터미널이 없으면 거부합니다. 승인자가 연결되지 않은 도구는 거부합니다.
- **키 입력**: 앞에 있는 앱에 입력하는 것이 주입된 텍스트가 명령이 되는 경로입니다(터미널에서 `curl … | sh`와 Return). 어떤 앱이 터미널인지는 확실히 나열할 수 없으므로 앱 단위가 아니라 키 입력마다 확인합니다. `computer`(`type`), `typesafe_act`, `mca act`, 앱 내 자율 루프가 입력하는 텍스트와, 수정 키 없는 Escape·Tab·좌우 화살표·Home/End·Page Up/Down을 제외한 모든 키 입력은 내용을 그대로 보여 주고 승인 후 실행합니다. 줄바꿈은 하나마다 Return이 눌리므로 확인 창에 그 개수를 표시합니다. 위아래 화살표도 확인합니다. 터미널에서는 기록을 불러오고 이후의 Return이 그것을 실행하기 때문입니다. 자율 루프에서 거부하면 그 실행은 종료됩니다. 확인 창에는 앞에 있는 앱 이름도 표시하고 알림을 닫으면 그 앱으로 포커스를 돌려주지만, 둘 다 최선의 노력입니다. 키를 보내기 전에 포커스가 움직일 가능성은 남으며, 사용자가 승인하는 것은 텍스트 자체입니다. 확인하지 않는 것: 포인터 조작(`click_element`, 클릭, 드래그, 스크롤. 텍스트는 입력할 수 없지만 화면의 버튼은 누를 수 있습니다)과 DevTools를 통해 에이전트 전용 탭에 보내는 브라우저 도구의 키 입력. 브라우저 도구가 Accessibility로 폴백하면 실제 브라우저 창에 입력하므로 `browser_act`의 `type`·`fill`·`press`는 실행 전에 확인합니다.
- **파일 쓰기 정책**: `write_file`은 셸 시작 파일, 홈 폴더의 점 파일, LaunchAgents/LaunchDaemons, 시스템 디렉터리, `.git` 폴더 안의 모든 경로, 앱 자체의 설정·데이터 디렉터리(`config.json`, 컨텍스트 데이터베이스)에 대한 쓰기를(심볼릭 링크 해석 후) 무조건 거부하고, 홈 밖의 경로는 확인 창에 표시합니다.
- **MCP 기본 거부**: stdio MCP 서버에는 물어볼 UI가 없으므로 `run_applescript`, `computer`, `click_element`, `typesafe_act`, 실행 모드의 `autonomous_act`, 페이지를 조작하는 브라우저 도구(`browser_navigate`, `browser_element`, `browser_act`, 그리고 탭을 열거나 전환하거나 닫는 `browser_tabs`), `path`를 지정한 `browser_read`, JavaScript를 평가하는 브라우저 도구는 `config.json`에 `"mcpAllowDangerousTools": true`를 설정하지 않으면 거부됩니다.
- **조언 카드**: 카드의 원클릭 작업은 입력될 내용을 보여 주고 확인을 받으며, Return은 사용자가 선택한 경우에만 누릅니다. 앱 이름과 입력 내용은 AppleScript에 전달하기 전에 이스케이프됩니다.
