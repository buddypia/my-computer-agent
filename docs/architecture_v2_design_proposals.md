# アーキテクチャ v2 設計案比較と選定

> **作成日**: 2026-09-08
> **対象**: `my-computer-agent` の再設計（v1 は Python + Web HUD 構成で中核機能が非動作）
> **評価軸**: レイテンシ / モジュール性 / 拡張性 / マルチプロバイダー / 効率（コスト・CPU）/ 未来性 / 実装コスト

---

## 0. 設計の前提となる3つの制約

設計案を並べる前に、選択肢を絞り込む「動かせない制約」を明示する。すべての案はこれを満たさねばならない。

### 制約1: レイテンシ予算は2桁違う階層構造を持つ

| 経路 | 予算 | 実行文脈 | 帰結 |
|---|---|---|---|
| CoreAudio I/O callback | **< 数ms**（ハードデッドライン） | リアルタイムスレッド。`malloc` / ロック / IPC / `await` すべて禁止 | ネイティブコード必須。GC・GIL 言語は物理的に不可 |
| バージイン（VAD検知→TTS停止） | < 100ms | リアルタイム隣接 | プロセス境界不可。in-process 必須 |
| STT 部分確定 | < 300ms | ANE / バックグラウンド | ローカル推論で十分達成可能 |
| LLM TTFT | 300〜800ms | ネットワーク律速 | **プロセス境界のコスト(~1ms)は誤差**。ここは速度で選ぶ必要がない |

**この非対称性が設計の骨格を決める。** 音声経路は言語選択の自由がゼロ、LLM 経路は自由度が最大。

### 制約2: TCC 権限はプロセス単位・署名バイナリ単位で付与される

`NSAudioCaptureUsageDescription`（CoreAudio tap）、Accessibility（`AXUIElement`）、Screen Recording（`ScreenCaptureKit`）はすべて**署名された単一バイナリ**に紐づく。プロセスを分割するたびに権限ダイアログと Login Item 登録が増え、ユーザー体験と配布が劣化する。→ **プロセス数は少ないほど良い**という強い圧力がある。

### 制約3: 24/7 常駐のコスト構造

常時監視をそのままクラウド LLM に投げると破綻する。実数で示す（`gemini-3.8-flash`、5秒間隔スキャン、1日8時間稼働 = 5,760 call/日、1回あたり in 2,000 / out 200 トークン想定）:

| 構成 | 月額（2026年内） | 月額（2027/1/1 値上げ後） |
|---|---|---|
| 全スキャンを Flash に投げる | **約 $389** | **約 $778** |
| オンデバイスゲートで 2% だけ通過 | **約 $7.8** | **約 $15.6** |

**50倍の差。** 「オンデバイスモデルをトリアージゲートに置く」ことは最適化ではなく前提条件。

---

## 1. 設計案（プロセス構成）

### 案A: Swift 単一プロセス・モジュラーモノリス

```
┌─ MyComputerAgent.app (Swift 6.4, 単一プロセス) ────────────┐
│  Sensing → Perception → Memory → Reasoning → Presentation │
│  すべて SwiftPM ターゲットとして分離、プロトコル境界で結合   │
└────────────────────────────────────────────────────────────┘
```

すべてを1プロセスに収める。モジュール分割は SwiftPM ターゲットと protocol で行い、プロセス境界では行わない。

- **+** TCC 権限が1つ。配布・署名・公証が単純
- **+** 音声経路もツール実行も同一メモリ空間。IPC ゼロ
- **+** Swift 6.4 の strict concurrency + actor で層間分離をコンパイル時に強制できる
- **−** AI エコシステム（Python の LangChain / LiteLLM 等）が使えない
- **−** クラッシュが全体に波及（→ 後述の緩和策あり）

### 案B: Swift ネイティブコア + Python/TS AI サイドカー

v1 の延長。Swift がセンサーと HUD、サイドカーが LLM オーケストレーション。

- **+** Python/TS の AI エコシステムをそのまま使える
- **−** ランタイム同梱が重い（py2app + 全 `.so` の署名 / Bun バイナリ）。v1 が壊れた直接原因
- **−** プロセス2つ = 起動順序、死活監視、バージョン整合の管理コストが恒常的に発生
- **−** サイドカーが提供する価値は「LLM を HTTP で叩く」だけ。Swift でも 300行程度で書ける
- **−** ツール実行がプロセスを跨ぐと、画面操作系ツールで権限の再取得が必要になる

### 案C: Rust コア + Swift 薄シェル

既存の Rust 製デーモンに寄せる路線。Rust が収集・保存・推論、Swift は HUD のみ。

- **+** 将来の Windows / Linux 対応でコアを共有できる
- **+** メモリ効率が最良
- **−** `objc2` / `cidre` 系バインディングは新 Apple API に必ず遅れる。`AXUIElement` / `SpeechAnalyzer` / `FoundationModels` は特に痛い
- **−** **共有できるのは Memory 層だけ**。macOS の ScreenCaptureKit / CoreAudio tap / AX と Windows の WGC / WASAPI / UIA には共通抽象が存在せず、Sensing 層はどのみち全書き換え
- **−** FFI 境界の設計・保守コストが恒常的

### 案D: Swift コア + ローカル MCP サーバー群

エージェント／ツール層を MCP サーバーとして別プロセスに外出しする。

- **+** ツールの追加・更新がアプリ再ビルド不要。サードパーティ拡張が可能
- **+** 外部エージェント（Claude Code / Codex 等）からも同じツールが使える
- **−** これを**唯一の**構成にすると、音声経路とコア文脈アクセスまで IPC 越しになり制約1に抵触
- **→ 単独案としては不適。ただし「外向き API」としては極めて価値が高い**（後述）

### 評価マトリクス

| 軸 | 案A モノリス | 案B サイドカー | 案C Rust コア | 案D MCP 分散 |
|---|:---:|:---:|:---:|:---:|
| 音声レイテンシ（制約1） | ◎ | △ | ◎ | ✗ |
| 権限・配布（制約2） | ◎ | △ | ○ | ✗ |
| 新 Apple API 追従 | ◎ | ○ | ✗ | ○ |
| AI エコシステム | △ | ◎ | △ | ◎ |
| ツール拡張性 | △ | ○ | △ | ◎ |
| クロスプラットフォーム | ✗ | △ | ○ | △ |
| 実装コスト | ○ | △ | ✗ | △ |
| 保守コスト | ◎ | ✗ | △ | ○ |

### 選定: **案A をベースに、案D の MCP を「外向き境界」として併設**

```
┌─ MyComputerAgent.app (単一プロセス, 全権限を保持) ──────────┐
│  Sensing / Perception / Memory / Reasoning / Presentation  │
│                          │                                  │
│                    ┌─────┴─────┐                            │
│                    │ Interop   │                            │
│                    │  ├ MCP Server ──→ 外部エージェントへ文脈を公開 │
│                    │  └ MCP Client ←── 外部ツールを取り込む      │
└────────────────────────────────────────────────────────────┘
```

**理由:**
1. 制約1・2 を満たすのは案A と案C のみ。案C は Sensing 層が共有できない以上、Rust 化のリターンが Memory 層だけに縮む一方で、新 API 追従コストを恒久的に払う。割に合わない。
2. 案B が提供する価値（AI エコシステム）は、後述の通り **Apple の `LanguageModelExecutor` プロトコルの登場でほぼ消滅した**。プロバイダー抽象・ツール呼び出し・構造化出力・トランスクリプト管理が OS 側に入ったため、Python を持ち込む理由がなくなった。
3. 案D の「拡張性」は、**内部構造としてではなく外部インターフェースとして**採用すれば、制約を破らずに利点だけ取れる。しかもこれが最大の未来性投資になる（後述 §6）。

---

## 2. モジュール設計

SwiftPM ターゲットとして分離し、**依存は一方向のみ**（逆流はコンパイルエラーになる）。

```
App                      ← composition root / TCC / SMAppService
 ├── Presentation        ← NSPanel HUD, SwiftUI, グローバルホットキー
 ├── Interop             ← MCP Server / MCP Client
 ├── Reasoning           ← プロバイダー抽象, ルーター, Tool 実装
 ├── Memory              ← GRDB + FTS5 + sqlite-vec, 埋め込み
 ├── Perception          ← Vision OCR, VAD, STT, 話者分離
 └── Sensing             ← ScreenCaptureKit, AXUIElement, CoreAudio Tap, VPIO
```

| ターゲット | 責務 | 主要依存 | 上位に公開する契約 |
|---|---|---|---|
| **Sensing** | 生イベント・生 PCM の取得のみ。解釈しない | ScreenCaptureKit, CoreAudio, ApplicationServices | `AsyncStream<RawFrame>` / `AsyncStream<AudioChunk>` |
| **Perception** | 生データ → 構造化観測。ここまでで完全ローカル | Vision, Speech | `AsyncStream<Observation>` |
| **Memory** | 永続化・検索。時系列 + 全文 + ベクトル | GRDB, sqlite-vec, MLX | `ContextStore` protocol |
| **Reasoning** | 判断と生成。プロバイダー非依存 | FoundationModels (macOS 27+) | `Agent` protocol |
| **Presentation** | 表示のみ。ビジネスロジックを持たない | AppKit, SwiftUI | — |
| **Interop** | MCP の入出力 | swift-sdk (MCP) | — |

### 並行性設計（Swift 6.4 strict concurrency）

**最重要**: リアルタイムオーディオコールバックを `actor` に入れてはいけない。`await` はデッドラインを踏む。

```
CoreAudio IOProc (realtime thread, ロックフリー)
        │  ring buffer への書き込みのみ
        ▼
   LockFreeRingBuffer  ← 唯一の realtime/非realtime 境界
        │
        ▼
  actor AudioPipeline  ← ここから先は通常の Swift Concurrency
```

各層は `actor` で分離し、`Sendable` な値型のみを流す。`Observation` / `ContextSnapshot` はすべて `struct` + `Sendable`。

### v1 の失敗を構造的に防ぐ仕掛け

v1 の致命的問題は「13 個の緑のテストが何も証明していなかった」こと（自前でモックを注入して自前の正規表現が発火したことを assert していた）。これを設計に織り込む:

1. **契約テストの置き場所を層境界に固定する**。各プロトコルに対し「実装 A（本番）」と「実装 B（フェイク）」の両方が**同一のテストスイート**を通ることを要求する。フェイク専用のテストは書かない。
2. **各層に実機受け入れ条件を1つずつ定義**（§7）。単体テストが通っても受け入れ条件が通らなければその層は未完成とみなす。
3. **例外を握り潰して "active" と報告する経路を作らない**。状態は `enum State { case running, degraded(reason: String), failed(Error) }` とし、`degraded` / `failed` を HUD に必ず表示する。v1 は音声パイプラインが起動時例外で死んでいるのに `voice_pipeline: "active"` を返していた。

---

## 3. LLM マルチプロバイダー設計

### 3案の比較

| | L1: 自前 protocol | L2: Apple `LanguageModelExecutor` 準拠 | L3: 外部ゲートウェイ（LiteLLM 等） |
|---|---|---|---|
| 対応 OS | macOS 26+ | **macOS 27+** | 制約なし |
| 実装量 | 大（streaming / tool / 構造化出力 / transcript を全部自作） | 小（OS が提供） | 極小 |
| 構造化出力 | 自作 | `@Generable` で型付き取得 | プロバイダー依存 |
| ツール呼び出し | 自作（並列・直列の呼び出しグラフも） | `Tool` protocol、呼び出しグラフは OS が処理 | 自作 |
| オンデバイスモデル | 別扱いが必要 | **同一 API**（`SystemLanguageModel` / `PrivateCloudComputeLanguageModel` / `MLXLanguageModel` / クラウド） | 統合不可 |
| KV キャッシュ再利用 | 自作 | executor が configuration hash でキャッシュ | — |
| プロセス数 | +0 | +0 | **+1** |
| ローカルファースト | ○ | ◎ | ✗ |

### 選定: **L2 を最終形とし、現時点では L2 と同型の薄い自前プロトコル（L1'）を切る**

Apple は WWDC26 で FoundationModels をモデルプラガブルにした。`LanguageModel` + `LanguageModelExecutor` に準拠したパッケージを SwiftPM で配れば、オンデバイス 3B もクラウド Gemini も**同一の `LanguageModelSession` API** で扱える。これは自前で作るどんな抽象よりも良い。理由は「Apple が保守する」「`@Generable` / `Tool` / `Transcript` が無料で付く」「他社製プロバイダーパッケージのエコシステムが育つ」。

ただし macOS 27 は 2026-09 時点でまだ beta（Xcode 27 beta 6 / 安定版は Xcode 26.6）。GA を待たずに着手するため、**Apple のプロトコル形状をそのまま写した自前定義**を今切っておく。GA 時の移行が `import` の差し替えとほぼ機械的な置換で済む。

```swift
// 今書くもの。Apple の形状をそのまま写す
public protocol LanguageModelExecuting: Sendable {
    init(configuration: Configuration) throws
    func prewarm(model: Model, transcript: Transcript)
    func respond(to request: GenerationRequest,
                 model: Model,
                 streamingInto channel: GenerationChannel) async throws
}

public struct ModelCapabilities: OptionSet, Sendable {
    static let toolCalling, guidedGeneration, reasoning, vision, audio: Self
}

// Apple と同じ6種。移行時にそのまま対応する
public enum TranscriptEntry: Sendable {
    case instructions(...), prompt(...), toolCalls(...)
    case toolOutput(...), response(...), reasoning(...)
}
```

ストリーミングも Apple と同じ「メタデータ → 使用量 → テキストデルタ」の順序で channel に流す。

### アダプタ構成（4つで市場をほぼ覆う）

| アダプタ | カバー範囲 | 実装方式 | 備考 |
|---|---|---|---|
| **Gemini** | `gemini-3.8-flash` / `gemini-3.1-pro` / `gemini-3.1-flash-lite` | REST + SSE を直接実装 | 主軸。`thinkingLevel` / context caching / computer use に対応 |
| **Anthropic** | Claude 各種 | Messages API 直接 | tool use / thinking / prompt caching の意味論が独自なのでネイティブ実装の価値あり |
| **OpenAI 互換** | OpenAI / Ollama / LM Studio / vLLM / Groq / OpenRouter / DeepSeek | 1実装で全部 | ローカル LLM もここに乗る |
| **Apple on-device** | `SystemLanguageModel`（3B）/ `MLXLanguageModel` | FoundationModels そのもの | トリアージゲート用 |

**Gemini は Firebase AI Logic SDK ではなく REST/WebSocket を直接叩く。** 旧 `generative-ai-swift` は非推奨アーカイブ済みで公式導線は Firebase AI Logic だが、これは (a) Firebase 依存を丸ごと持ち込む (b) 2026年7月以降 App Check が強制される (c) モバイルアプリ向け設計でデスクトップ常駐アプリと相性が悪い。API は素直な REST + SSE なので直接実装したほうが軽く、`LanguageModelExecutor` への適合も自然。

### ルーティング: フェイルオーバーではなくタスク別

マルチプロバイダーの実利は冗長化ではなく**タスクに応じた階層化**にある。

```swift
enum Task { case triage, classify, summarize, answer, vision, hardReasoning, liveVoice }

// 設定ファイルで差し替え可能にする（モデル ID と価格を埋め込まない）
struct RoutingPolicy: Codable {
    var routes: [Task: ModelRef]
    var fallbacks: [Task: [ModelRef]]
    var budgets: [Task: TokenBudget]
}
```

| Tier | タスク | モデル | 単価 (in/out per M) | 想定頻度 |
|:---:|---|---|---|---|
| 0 | 差分検出・エラー正規表現 | ルール + Vision OCR | $0 | 常時 |
| **1** | **割り込み判定ゲート** | `SystemLanguageModel`（オンデバイス 3B） | **$0** | 常時 |
| 2 | 分類・短文要約 | `gemini-3.1-flash-lite` | $0.25 / $1.50 | ゲート通過時 |
| 3 | 主力・ビジョン・ツール実行 | `gemini-3.8-flash` | $0.75 / $3.75 ※ | ユーザー要求時 |
| 4 | 難問・長文推論 | `gemini-3.1-pro` / Claude / GPT | $2 / $12 (>200K: $4/$18) | 明示要求時のみ |
| V | 音声対話セッション | `gemini-3.1-flash-live-preview` | 音声トークン課金 | 対話モード中のみ |

※ **2027-01-01 に $1.50 / $7.50 へ倍額**。モデル ID・単価・ルーティングを設定として外部化しておくべき具体的理由がこれ。ハードコードすると値上げ時にコード変更が必要になる。

**Context caching** は $0.075/M（1/10）だが別途ストレージ $0.50/M/hour がかかる。→ 常時キャッシュは損。**対話セッション中のシステムプロンプト＋画面文脈のみ**キャッシュする。

---

## 4. 音声パイプライン設計

### 3案の比較

| | V1: フルローカル | V2: Gemini Live 丸投げ | V3: ハイブリッド |
|---|---|---|---|
| 常時録音のコスト | $0 | 音声トークン課金（青天井） | $0 |
| プライバシー（REQ-10） | ◎ | ✗ 音声が常時クラウドへ | ◎ |
| バージイン遅延 | < 50ms（完全ローカル制御） | サーバー VAD、標準搭載 | 両方 |
| オフライン動作 | ◎ | ✗ | ○（常時録りは動く） |
| 対話品質 | STT→LLM→TTS の積み上げ | ネイティブ音声、感情適応 | 対話時は V2 品質 |
| 実装量 | 最大 | 最小 | 中〜大 |

### 選定: **V3 ハイブリッド**

```
[常時モード]  CATap ──┐
              VPIO ──┤→ VAD → SpeechAnalyzer / オンデバイス ASR → 話者分離
              (AEC)  ┘                                      │
                                                    テキストのみ → Memory
                                                    （音声は端末外に出ない）

[対話モード]  ユーザーがホットキー / ウェイクワードで明示的に起動
              PCM ──→ gemini-3.1-flash-live-preview (WebSocket)
              VAD / バージイン / STT / TTS をサーバー側が担当
              セッション終了で常時モードに復帰
```

24時間ループバック音声を Live API に流すのはコスト面でもプライバシー面でも成立しない。一方「今ちょっと話しかけたい」瞬間だけなら Live API の品質（ネイティブ音声出力、バージイン標準動作、感情適応）が圧勝する。**モードを分けることで両取りできる。**

### Sensing 層の実装上の地雷（検証済み）

CoreAudio process tap（macOS 14.2+）には文書化されていない罠がある:

1. **`AVAudioEngine` は CATap ベースの aggregate device に向けられない。** `kAudioOutputUnitProperty_CurrentDevice` の設定は `noErr` を返すが、エンジンは黙ってデフォルト入力を読み続ける。→ **`AudioDeviceCreateIOProcIDWithBlock` を aggregate device に直接使う**こと。
2. aggregate device には実在の出力デバイスを main sub-device として持たせ、tap を sub-tap として付け、`kAudioAggregateDeviceTapAutoStartKey: true` を指定する。
3. TCC プロンプト（`NSAudioCaptureUsageDescription`）は**署名済みバイナリでの最初の `AudioHardwareCreateProcessTap` 呼び出し**でのみ出る。未署名だと出ずに失敗する。
4. `CATapDescription(stereoGlobalTapButExcludeProcesses:)` は `exclusive = true` を自動設定する。「これら以外を全部 tap」の意味であり、排他ロックの指定ではない。

---

## 5. 効率設計

### CPU / メモリ

| 層 | 手法 | 想定コスト |
|---|---|---|
| 画面 | 30fps 動画をやめ、**OS イベント駆動**（フォーカス変更 / クリック / スクロール停止 / タイピング停止）でのみキャプチャ | 常時 < 3% |
| 画面理解 | a11y ツリー優先。取れない時だけ差分領域を Vision OCR | OCR は数十ms / frame |
| 音声 | オンデバイス ASR（CoreML / **ANE 実行**） | ANE なので CPU をほぼ食わない |
| 推論ゲート | オンデバイス 3B | ANE |

**Apple Silicon 専用にする。** オンデバイス ASR が ANE 前提であること、macOS 27 の deployment target では `ARCHS_STANDARD` から x86_64 が外れることから、Intel 対応を捨てるのが合理的。

### 検索（Memory 層）

FTS5（語彙一致）と sqlite-vec（意味一致）を **Reciprocal Rank Fusion で統合**する。片方だけでは「同義語で検索できない」「固有名詞が拾えない」のどちらかに必ず落ちる。

- 埋め込み: **EmbeddingGemma 300M**（1024次元、MLX 経由、L2 正規化して保存）
- 規模: 数千〜数万チャンクなら `vec0` のブルートフォース走査で十分。ANN インデックスは不要
- GRDB で拡張をロードするには custom SQLite ビルドが要る。これを避けたい場合は sqlite-vec の standalone Swift パッケージを使う

### 保存量

イベント駆動 + a11y 優先により、画面フレームの保存は差分時のみ。音声はテキスト転写のみ保存し、PCM は保持しない（プライバシーと容量の両方に効く）。

---

## 6. 拡張性・未来性

投資対効果の順に3つ。

### 1位: MCP サーバーを生やす（最重要）

**閉じたエージェントではなく「コンテキストプロバイダー」を作る。** 蓄積した画面・音声・タイムラインを MCP サーバーとして公開すれば、Claude Code / Codex / 将来登場するクライアントがすべて同じ文脈を使える。自作の HUD やエージェントが陳腐化しても、**データと収集基盤という資産が残る**。

公式 [Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk)（v0.12.1、spec 2025-11-25、Swift 6.0+、クライアント／サーバー両対応）を使う。

### 2位: `LanguageModelExecutor` 準拠

新プロバイダーの追加が SwiftPM パッケージの追加だけになる。Apple がエコシステムを育てる意図を明示しているので、自分で書かずに済むアダプタが増えていく。

### 3位: ルーティングポリシーの外部設定化

モデル ID・単価・タスク割り当てを JSON/TOML に出す。Gemini の値上げ（2027-01-01）、新モデル登場、オンデバイスモデルの性能向上に、コード変更なしで追随できる。

### 採用しない拡張

- **Windows 対応の先取り**: Sensing 層はどのみち全書き換えになるため、共通化の価値がない。必要になった時点で Memory / Reasoning を Swift パッケージとして切り出せば足りる（Swift は Windows / Linux で動く）。
- **プラグイン SDK の自作**: MCP がその役割を果たすので不要。

---

## 7. 技術選定表

| 領域 | 選定 | バージョン / 備考 |
|---|---|---|
| 言語 | **Swift 6.4** | strict concurrency 有効。Swift 6.x 互換で破壊的変更なし |
| ツールチェイン | Xcode 27（GA 後）/ 26.6（現行安定） | deployment target **macOS 26.0**、`#available(macOS 27)` で FoundationModels provider 経路 |
| 対象 | **Apple Silicon 専用** | ANE 前提。Intel 切り捨て |
| 画面 | ScreenCaptureKit (`SCStream`) | |
| a11y | `AXUIElement` + `AXObserver` | Accessibility 権限 |
| システム音声 | `AudioHardwareCreateProcessTap` + `CATapDescription` + `AudioDeviceCreateIOProcIDWithBlock` | macOS 14.2+。仮想ドライバ不要 |
| AEC | AudioUnit `kAudioUnitSubType_VoiceProcessingIO` | ハードウェア支援 |
| OCR | Vision `VNRecognizeTextRequest` | オンデバイス、無料 |
| VAD / ASR | オンデバイス VAD / ASR（CoreML + ANE） | SPM、完全ローカル |
| ASR 代替 | `SpeechAnalyzer` / `SpeechTranscriber` | macOS 26+、完全オンデバイス、`AssetInventory` でロケール管理 |
| 保存 | GRDB + SQLite FTS5 + sqlite-vec | RRF で統合 |
| 埋め込み | EmbeddingGemma 300M（MLX） | 1024次元 |
| オンデバイス LLM | FoundationModels `SystemLanguageModel` | ~3B、macOS 26+。トリアージゲート |
| クラウド LLM | `gemini-3.8-flash` / `gemini-3.1-pro` / `gemini-3.1-flash-lite` | REST + SSE を直接実装 |
| 音声対話 | `gemini-3.1-flash-live-preview` | WebSocket、128k ctx、`thinkingLevel` 対応 |
| プロバイダー抽象 | 自前 `LanguageModelExecuting`（Apple 形状）→ macOS 27 で FoundationModels へ移行 | |
| 相互運用 | MCP Swift SDK v0.12.x | サーバー + クライアント |
| HUD | `NSPanel` + SwiftUI | 下記の設定必須 |
| 常駐 | `SMAppService` | macOS 13+ |

### HUD の必須設定（v1 の `desktop.py` に欠けていた点）

```swift
// NSWindow ではなく NSPanel。.nonactivatingPanel が IDE からフォーカスを奪わせない
let panel = NSPanel(contentRect: rect,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces,
                            .stationary,
                            .fullScreenAuxiliary]  // ← v1 に欠落。全画面アプリ上に出るために必須
panel.isOpaque = false
panel.backgroundColor = .clear
panel.ignoresMouseEvents = true   // ホットキーでトグル。v1 は呼び出し口が無かった

NSApp.setActivationPolicy(.accessory)  // Dock アイコンを出さない
```

**`WKWebView` は使わない。** 常時最前面ウィンドウの描画経路に Chromium 級エンジンを挟むのは、メモリ・透過処理・ヒットテスト・アニメーションのすべてで損。SwiftUI で直接描く。

### ライセンス

sqlite-vec: MIT / GRDB: MIT / MCP Swift SDK: MIT。**すべて商用可でクリーン。** 商用ライセンスが必要な依存を持たないことで、この一貫性が得られる。

---

## 8. 実装計画（依存順・各段階に実機受け入れ条件）

v1 の失敗はリスクの高い層を後回しにしてガワから作ったこと。**リスク順に潰す。**

| # | 内容 | 受け入れ条件（これが通るまで次に進まない） |
|:---:|---|---|
| **1** | CoreAudio tap + VPIO + オンデバイス VAD/ASR の CLI | Zoom 通話で「自分の声」と「相手の声」が別チャンネルに分離転写され、エコー二重転写が起きない |
| **2** | `NSPanel` HUD 単体 | 全画面の Xcode と Zoom の上に浮き、クリックが背後の IDE に透過し、フォーカスを奪わない |
| **3** | Sensing（SCStream + AX）→ Memory（FTS5 + vec） | 「10分前に見ていた Slack のあの話」が自然文で引ける |
| **4** | `LanguageModelExecuting` + Gemini アダプタ | `gemini-3.8-flash` でストリーミング・ツール呼び出し・画像入力が動く。別アダプタに差し替えても呼び出し側が無変更 |
| **5** | オンデバイストリアージゲート → プロアクティブ提案 | 8時間稼働でクラウド呼び出しが想定の 2% 前後に収まる（実測） |
| **6** | MCP サーバー公開 | Claude Code から自分の画面履歴を検索できる |
| **7** | Live API 対話モード | ホットキーで対話開始、発話でバージインが効き、終了後に常時モードへ復帰 |
| **8** | 署名・公証・`SMAppService` | クリーンな Mac で全 TCC ダイアログが正しく出て、再起動後も動く |

段階1と2が通れば、この製品が成立するかはほぼ確定する。

---

## 9. 未確定事項・リスク

| リスク | 影響 | 対応 |
|---|---|---|
| macOS 27 GA 時期 | FoundationModels provider API が使えない期間がある | 自前 `LanguageModelExecuting` を Apple 形状で先行実装。移行を機械的にする |
| Gemini 3.8 Flash の値上げ（2027-01-01、倍額） | 運用費が2倍 | ルーティングを設定外部化。Flash-Lite / オンデバイス比率を上げて吸収 |
| `gemini-3.1-flash-live-preview` が preview 版 | 破壊的変更・廃止の可能性（2.5 系は既に shutdown 済み） | 対話モードを機能フラグ化。常時モードは Live API に依存させない |
| CoreAudio tap API の文書化不足 | 実装が試行錯誤になる | 段階1で先に潰す |
| Live API の非同期 function calling 未対応 | 対話中のツール実行が同期のみ | 重いツールは対話モードで使わず、ターン型 API 側に回す |
| FoundationModels の適性外用途 | Apple はコード生成・数学・事実 QA に使うなと明示 | ゲート判定（分類タスク）に限定する。生成はクラウドへ |

---

## 付録: 参照

- [Gemini API release notes](https://ai.google.dev/gemini-api/docs/changelog) / [What's new in Gemini 3.8 Flash](https://ai.google.dev/gemini-api/docs/latest-model) / [Gemini API pricing](https://benchlm.ai/google/api-pricing)
- [Live API overview](https://ai.google.dev/gemini-api/docs/live-api) / [Live API capabilities](https://ai.google.dev/gemini-api/docs/live-api/capabilities) / [WebSockets reference](https://ai.google.dev/api/live)
- [Bring an LLM provider to the Foundation Models framework (WWDC26 #339)](https://developer.apple.com/videos/play/wwdc2026/339/)
- [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) / [Swift 6.4](https://byteiota.com/swift-64-wwdc-2026-upgrade/)
- [Core Audio Taps deep-dive (Recall.ai)](https://www.recall.ai/blog/core-audio-taps) / [Capturing System Audio on macOS in 2026 (DGR Labs)](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html)
- [SpeechAnalyzer API](https://blog.addpipe.com/apple-speechanalyzer-api/)
- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
- [Building a RAG on SQLite (RRF pattern)](https://blog.sqlite.ai/building-a-rag-on-sqlite)
