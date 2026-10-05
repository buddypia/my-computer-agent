[English](CONTRIBUTING.md) • [日本語](CONTRIBUTING.ja.md) • [한국어](CONTRIBUTING.ko.md)

# Contributing to MyComputerAgent

Thank you for your interest in contributing to **MyComputerAgent (mca)**! This document outlines the development workflow, architectural guidelines, quality gate requirements, and contribution process.

---

## Code of Conduct

All contributors are expected to uphold our [Code of Conduct](CODE_OF_CONDUCT.md). Please report unacceptable behavior privately via **GitHub Private Vulnerability Reporting** (repository **Security** tab ▸ **Report a vulnerability**; state that it is a Code of Conduct report).

---

## Development Prerequisites

- **macOS**: macOS 26 or later (as required by `Package.swift`), running on **Apple Silicon** (M1/M2/M3/M4 or later).
- **Swift & Xcode**: Swift 6.2+ / Xcode 26+.
- **Permissions**: Accessibility, Screen Recording, Microphone, and Audio Capture permissions are required to test desktop features.

---

## Architecture and Layer Invariants

`MyComputerAgent` is strictly structured as a layered dependency tree in [`Package.swift`](Package.swift). **You must not break the layer order**:

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

### Architectural Rules
1. **Unidirectional Dependencies**: Upper layers may import lower layers. Lower layers must **never** import upper layers (e.g. `MCACore` and `MCASensing` must never import `MCAReasoning` or `MCAPresentation`).
2. **Realtime Audio Safety**: The CoreAudio tap and audio ring buffer paths run on realtime threads. Never allocate heap memory, acquire mutex locks, or perform IPC inside audio callbacks.
3. **No External Sidecars**: Audio capture, screen perception, and hotkeys must remain 100% native Swift without Node.js or Python runtime dependencies in production.

---

## Security and Privacy Invariants

1. **Zero Plaintext Secrets**:
   - Never commit API keys, personal tokens, or credentials to git.
   - All credentials must be stored via [`SecretStore`](Sources/MCAReasoning/SecretStore.swift) (sealed with HPKE to Apple's Secure Enclave) or injected ephemerally via environment variables (`GEMINI_API_KEY`, etc.).
2. **Privacy Filtering**:
   - Any screen inspection or OCR path must run through [`PrivacyFilter`](Sources/MCASensing/PrivacyFilter.swift).
   - Password managers (`1Password`, `Bitwarden`, `Keychain Access`) and `AXSecureTextField` fields must remain completely blocked.
   - PII, tokens, and payment cards must be sanitized before passing data to reasoning models.
3. **User Opt-in for Sensors**:
   - The microphone and screen observation must remain strictly **OFF** by default on application startup.

---

## Development Workflow

### 1. Fork and Clone

External contributors only need a fork and a regular feature branch. The `git worktree` workflow described in `AGENTS.md` is optional and is mainly used by the maintainers' parallel AI sessions.

```bash
git clone https://github.com/<your-username>/my-computer-agent.git
cd my-computer-agent
```

### 2. Build and Test
```bash
# Build the executable
swift build

# Run the complete test suite
swift test

# Build the native macOS application bundle
./Scripts/bundle.sh
```

### 3. Run the Staged Quality Gate
Before submitting any changes, you **must** pass the quality gate:
```bash
./Scripts/gate.sh
```
The gate runs staged checks:
- **G0 (Classification)**: Identifies if changes are doc-only.
- **G1 (Build)**: Incremental `swift build`.
- **G2 (Test)**: Full test execution (`swift test`).
- **G3 (Bundle & Codesign)**: Full bundle assembly (run manually via `./Scripts/gate.sh --stage 3` or `./Scripts/bundle.sh`).

---

## Submitting Pull Requests

1. **Create a Feature Branch**:
   ```bash
   git checkout -b feature/your-feature-name
   # or fix/your-bug-fix
   ```
2. **Commit Changes**: Follow [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat(...)`: New feature or capability
   - `fix(...)`: Bug fix
   - `docs(...)`: Documentation changes
   - `refactor(...)`: Code refactoring without behavioral alterations
   - `test(...)`: Adding or updating tests
3. **Run the Quality Gate**:
   ```bash
   ./Scripts/gate.sh
   ```
4. **Push and Open a PR**:
   - Fill out the [Pull Request Template](.github/PULL_REQUEST_TEMPLATE.md).
   - Include test evidence and rationale for the change.

---

## Using AI coding agents

This repository contains harness conventions for AI coding agents (`AGENTS.md` and `CLAUDE.md`), such as worktree isolation and the automated quality-gate hook. Human-authored PRs do not need to follow them; the quality gate (`./Scripts/gate.sh`) and the PR template are all you need. If you do use an AI coding agent, you remain responsible for reviewing and understanding every change you submit.

---

## License of Contributions

By submitting a contribution, you agree that it is licensed under the project's [MIT License](LICENSE) (inbound = outbound). A "Developer Certificate of Origin" (DCO) sign-off (`Signed-off-by`) is **not** required.
