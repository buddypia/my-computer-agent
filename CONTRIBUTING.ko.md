[English](CONTRIBUTING.md) • [日本語](CONTRIBUTING.ja.md) • [한국어](CONTRIBUTING.ko.md)

# MyComputerAgent에 기여하기

**MyComputerAgent (mca)**에 관심을 가져 주셔서 감사합니다! 이 문서는 개발 워크플로, 아키텍처 가이드라인, 품질 게이트 요건, 그리고 기여 절차를 설명합니다.

---

## 행동 강령

모든 기여자는 [행동 강령](CODE_OF_CONDUCT.ko.md)을 지켜 주시기 바랍니다. 용납될 수 없는 행위는 **GitHub Private Vulnerability Reporting**(저장소의 **Security** 탭 ▸ **Report a vulnerability**, 행동 강령 관련 신고임을 명시)으로 비공개 신고해 주세요.

---

## 개발 사전 요구 사항

- **macOS**: macOS 26 이상(`Package.swift` 요구 사항), **Apple Silicon**(M1/M2/M3/M4 이상)에서 실행해야 합니다.
- **Swift & Xcode**: Swift 6.2+ / Xcode 26+.
- **권한**: 데스크톱 기능을 테스트하려면 손쉬운 사용(Accessibility), 화면 기록(Screen Recording), 마이크, 오디오 캡처 권한이 필요합니다.

---

## 아키텍처와 레이어 불변 조건

`MyComputerAgent`는 [`Package.swift`](Package.swift)에서 엄격한 레이어 구조의 의존성 트리로 구성되어 있습니다. **레이어 순서를 깨뜨려서는 안 됩니다**.

```
Layer 6: MCAPresentation  ──  SwiftUI HUD, Popover, Settings, Global HotKeys, Menus
Layer 5: MCAInterop       ──  Model Context Protocol (MCP) server & client integration
Layer 4b: MCARealtime      ──  Gemini Live bidirectional voice session, WAV encoder
Layer 4: MCAReasoning     ──  ModelRouter, Executors (Gemini, Claude, OpenAI), SecretStore, ComputerTools
Layer 3: MCAMemory        ──  SQLite + FTS5 full-text search, Vector retrieval
Layer 2: MCAPerception    ──  VoiceActivityDetector, Transcriber, Vision TextRecognizer
Layer 1: MCASensing       ──  ScreenCapturer, CoreAudio Tap, AccessibilityInspector/Actuator, PrivacyFilter
Layer 0: MCACore          ──  Shared value types, AudioRingBuffer, Configuration, Localization
```

### 아키텍처 규칙
1. **단방향 의존성**: 상위 레이어는 하위 레이어를 import할 수 있지만, 하위 레이어는 상위 레이어를 절대 import해서는 안 됩니다(예: `MCACore`와 `MCASensing`은 `MCAReasoning`이나 `MCAPresentation`을 import하면 안 됩니다).
2. **실시간 오디오 안전성**: CoreAudio tap과 audio ring buffer 경로는 실시간 스레드에서 실행됩니다. 오디오 콜백 안에서는 힙 메모리 할당, mutex 락 획득, IPC를 절대 하지 마세요.
3. **외부 사이드카 금지**: 오디오 캡처, 화면 인식, 핫키는 프로덕션에서 Node.js나 Python 런타임 의존성 없이 100% 네이티브 Swift로 유지해야 합니다.

---

## 보안 및 프라이버시 불변 조건

1. **평문 시크릿 금지**:
   - API 키, 개인 토큰, 자격 증명을 git에 commit하지 마세요.
   - 모든 자격 증명은 [`SecretStore`](Sources/MCAReasoning/SecretStore.swift)(Apple의 Secure Enclave에 대해 HPKE로 봉인)를 통해 저장하거나, 환경 변수(`GEMINI_API_KEY` 등)로 일시적으로 주입해야 합니다.
2. **프라이버시 필터링**:
   - 화면 검사나 OCR을 수행하는 모든 경로는 반드시 [`PrivacyFilter`](Sources/MCASensing/PrivacyFilter.swift)를 거쳐야 합니다.
   - 비밀번호 관리자(`1Password`, `Bitwarden`, `Keychain Access`)와 `AXSecureTextField` 필드는 완전히 차단된 상태를 유지해야 합니다.
   - PII, 토큰, 결제 카드 정보는 추론 모델에 데이터를 넘기기 전에 정제(sanitize)해야 합니다.
3. **센서는 사용자 옵트인**:
   - 마이크와 화면 관찰은 애플리케이션 시작 시 엄격하게 **OFF** 상태여야 합니다.

---

## 개발 워크플로

### 1. Fork 및 Clone

외부 기여자는 fork와 일반적인 feature branch만 있으면 됩니다. `AGENTS.md`에 설명된 `git worktree` 워크플로는 선택 사항이며, 주로 메인테이너의 병렬 AI 세션에서 사용됩니다.

```bash
git clone https://github.com/<your-username>/my-computer-agent.git
cd my-computer-agent
```

### 2. 빌드 및 테스트
```bash
# Build the executable
swift build

# Run the complete test suite
swift test

# Build the native macOS application bundle
./Scripts/bundle.sh
```

### 3. 단계별 품질 게이트 실행
변경 사항을 제출하기 전에 품질 게이트를 **반드시** 통과해야 합니다.
```bash
./Scripts/gate.sh
```
게이트는 다음 단계별 검사를 실행합니다.
- **G0 (분류)**: 변경 사항이 문서뿐인지 판별합니다.
- **G1 (빌드)**: 증분 `swift build`.
- **G2 (테스트)**: 전체 테스트 실행(`swift test`).
- **G3 (번들 & Codesign)**: 번들 전체 조립(`./Scripts/gate.sh --stage 3` 또는 `./Scripts/bundle.sh`로 수동 실행).

---

## Pull Request 제출

1. **Feature Branch 만들기**:
   ```bash
   git checkout -b feature/your-feature-name
   # or fix/your-bug-fix
   ```
2. **변경 사항 commit**: [Conventional Commits](https://www.conventionalcommits.org/)를 따라 주세요.
   - `feat(...)`: 새로운 기능
   - `fix(...)`: 버그 수정
   - `docs(...)`: 문서 변경
   - `refactor(...)`: 동작 변경 없는 코드 리팩터링
   - `test(...)`: 테스트 추가 또는 수정
3. **품질 게이트 실행**:
   ```bash
   ./Scripts/gate.sh
   ```
4. **Push 후 PR 열기**:
   - [Pull Request 템플릿](.github/PULL_REQUEST_TEMPLATE.md)을 작성해 주세요.
   - 테스트 증빙과 변경 사유를 포함해 주세요.

---

## AI 코딩 에이전트 사용

이 저장소에는 AI 코딩 에이전트를 위한 harness 규약(`AGENTS.md`와 `CLAUDE.md`)이 있으며, worktree 격리나 품질 게이트를 자동으로 실행하는 hook 등이 정의되어 있습니다. 사람이 작성한 PR은 이를 따를 필요가 없습니다. 품질 게이트(`./Scripts/gate.sh`)와 PR 템플릿만 있으면 됩니다. AI 코딩 에이전트를 사용하더라도, 제출하는 모든 변경 사항을 검토하고 이해할 책임은 여러분에게 있습니다.

---

## 기여물의 라이선스

기여물을 제출하면 해당 기여물이 프로젝트의 [MIT License](LICENSE)로 라이선스된다는 데 동의한 것으로 간주합니다(inbound = outbound). "Developer Certificate of Origin"(DCO) sign-off(`Signed-off-by`)는 필요하지 **않습니다**.
