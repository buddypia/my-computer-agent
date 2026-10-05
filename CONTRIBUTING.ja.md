[English](CONTRIBUTING.md) • [日本語](CONTRIBUTING.ja.md) • [한국어](CONTRIBUTING.ko.md)

# MyComputerAgent へのコントリビュート

**MyComputerAgent (mca)** にご関心をお寄せいただきありがとうございます。このドキュメントでは、開発ワークフロー、アーキテクチャ上のガイドライン、品質ゲートの要件、そしてコントリビュートの手順を説明します。

---

## 行動規範

すべてのコントリビューターには、[行動規範](CODE_OF_CONDUCT.ja.md)を守っていただくようお願いします。容認できない行為は **GitHub Private Vulnerability Reporting**（リポジトリの **Security** タブ ▸ **Report a vulnerability**。行動規範に関する報告である旨を明記してください）から非公開でご報告ください。

---

## 開発の前提条件

- **macOS**: macOS 26 以降（`Package.swift` の要件）。**Apple Silicon**（M1/M2/M3/M4 以降）上で動作させてください。
- **Swift & Xcode**: Swift 6.2+ / Xcode 26+。
- **権限**: デスクトップ機能をテストするには、アクセシビリティ、画面収録、マイク、オーディオキャプチャの各権限が必要です。

---

## アーキテクチャとレイヤの不変条件

`MyComputerAgent` は、[`Package.swift`](Package.swift) で厳密なレイヤ構造の依存ツリーとして構成されています。**レイヤの順序を崩してはいけません**。

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

### アーキテクチャルール
1. **単方向の依存**: 上位レイヤは下位レイヤを import できますが、下位レイヤが上位レイヤを import してはいけません（例: `MCACore` や `MCASensing` は `MCAReasoning` や `MCAPresentation` を import してはいけません）。
2. **リアルタイムオーディオの安全性**: CoreAudio tap と audio ring buffer のパスはリアルタイムスレッド上で動作します。オーディオコールバック内では、ヒープメモリの確保、mutex ロックの取得、IPC を行わないでください。
3. **外部サイドカーを使わない**: 音声キャプチャ、画面認識、ホットキーは、プロダクションにおいて Node.js や Python のランタイム依存を持たない 100% ネイティブ Swift のままにしてください。

---

## セキュリティとプライバシーの不変条件

1. **平文シークレットゼロ**:
   - API キー、個人トークン、認証情報を git に commit しないでください。
   - すべての認証情報は [`SecretStore`](Sources/MCAReasoning/SecretStore.swift)（Apple の Secure Enclave に対して HPKE で封印）経由で保存するか、環境変数（`GEMINI_API_KEY` など）で一時的に注入してください。
2. **プライバシーフィルタリング**:
   - 画面の検査や OCR を行うパスは、必ず [`PrivacyFilter`](Sources/MCASensing/PrivacyFilter.swift) を通してください。
   - パスワードマネージャー（`1Password`、`Bitwarden`、`Keychain Access`）と `AXSecureTextField` フィールドは、完全にブロックされた状態を維持してください。
   - PII、トークン、決済カード情報は、推論モデルにデータを渡す前にサニタイズしてください。
3. **センサーはユーザーのオプトイン**:
   - マイクと画面観察は、アプリケーション起動時に厳密に **OFF** のままにしてください。

---

## 開発ワークフロー

### 1. Fork と Clone

外部のコントリビューターに必要なのは、fork と通常の feature branch だけです。`AGENTS.md` に記載されている `git worktree` ワークフローは任意であり、主にメンテナーの並列 AI セッションで使われています。

```bash
git clone https://github.com/<your-username>/my-computer-agent.git
cd my-computer-agent
```

### 2. ビルドとテスト
```bash
# Build the executable
swift build

# Run the complete test suite
swift test

# Build the native macOS application bundle
./Scripts/bundle.sh
```

### 3. 段階的な品質ゲートの実行
変更を提出する前に、品質ゲートを**必ず**通してください。
```bash
./Scripts/gate.sh
```
ゲートは次の段階的なチェックを実行します。
- **G0 (分類)**: 変更がドキュメントのみかどうかを判定します。
- **G1 (ビルド)**: インクリメンタルな `swift build`。
- **G2 (テスト)**: テストの全件実行（`swift test`）。
- **G3 (バンドル & Codesign)**: バンドル一式の組み立て（`./Scripts/gate.sh --stage 3` または `./Scripts/bundle.sh` で手動実行）。

---

## Pull Request の提出

1. **Feature Branch を作成する**:
   ```bash
   git checkout -b feature/your-feature-name
   # or fix/your-bug-fix
   ```
2. **変更を commit する**: [Conventional Commits](https://www.conventionalcommits.org/) に従ってください。
   - `feat(...)`: 新機能・新しい能力
   - `fix(...)`: バグ修正
   - `docs(...)`: ドキュメントの変更
   - `refactor(...)`: 振る舞いを変えないコードのリファクタリング
   - `test(...)`: テストの追加・更新
3. **品質ゲートを実行する**:
   ```bash
   ./Scripts/gate.sh
   ```
4. **Push して PR を開く**:
   - [Pull Request テンプレート](.github/PULL_REQUEST_TEMPLATE.md)に記入してください。
   - テストの証跡と、変更の理由を含めてください。

---

## AI コーディングエージェントの利用

このリポジトリには、AI コーディングエージェント向けの harness 規約（`AGENTS.md` と `CLAUDE.md`）があり、worktree による分離や、品質ゲートを自動で実行する hook などが定められています。人間が書いた PR はこれらに従う必要はありません。必要なのは品質ゲート（`./Scripts/gate.sh`）と PR テンプレートだけです。AI コーディングエージェントを使う場合でも、提出する変更のすべてをレビューし、理解する責任はあなたにあります。

---

## コントリビューションのライセンス

コントリビューションを提出することで、それがプロジェクトの [MIT License](LICENSE) でライセンスされることに同意したものとみなします（inbound = outbound）。"Developer Certificate of Origin" (DCO) の sign-off（`Signed-off-by`）は必要**ありません**。
