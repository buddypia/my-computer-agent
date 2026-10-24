# Cursor ローカル Computer Use との機能比較と MCA の対応

目的: Cursor のローカル Computer Use と同じ使い方を、`mca` でもできるようにする。
つまり「外部のコーディングエージェント（Cursor / Claude Code / Codex）が、画面を **見て**、
マウスとキーボードで **操作して**、結果を **確かめる**」ループを MCP 越しに回せること。

## 1. Cursor の Computer Use（一次情報）

出典: Cursor 公式ドキュメント（2026-10-24 時点で取得）
`cloud-agent/self-hosted/computer-use`、`cloud-agent/capabilities`、`agent/tools/browser`。

| 区分 | Cursor の挙動 |
|---|---|
| 有効化 | `agent worker --computer-use start`。**明示 opt-in**で、サーバー側から勝手に有効にはならない |
| 操作 | クリック、入力、スクリーンショット、GUI アプリ操作。Chrome/Chromium があればブラウザ操作も |
| macOS 実体 | 署名済みヘルパー `Cursor Computer Use.app`（bundle ID `co.anysphere.cursor-computer-use`）を CLI が `~/.cursor/cursor-computer-use/` に入れる。**ヘルパー自身**が Accessibility と Screen Recording を持つ |
| 事前確認 | `agent worker debug` はインストール有無だけ報告し、権限は見ない。実タスクでスクリーンショットを撮らせて確かめる |
| 成果物 | スクリーンショット・動画・ログを PR に添付（Cloud Agent） |
| 人の介入 | Cloud/Linux ではデスクトップを共有し、人が操作を引き取れる（`--share-desktop` は Linux のみ） |
| 承認 | ブラウザツールは Manual / Allow-list / Auto-run。許可・拒否リスト、企業向けの origin allowlist |
| ブラウザ | ナビゲート、クリック、入力、スクロール、スクリーンショット、コンソール、ネットワーク。状態は workspace 単位で永続 |

## 2. MCA の現状（コードで確認した事実）

| 区分 | MCA |
|---|---|
| 入口 | アプリ内チャット、`mca act`、`mca browser`、`mca mcp`（stdio MCP） |
| 操作 | `computer` ツール: move / 各種クリック / drag / scroll（PID 指定でバックグラウンド可）/ type（日本語可）/ key / cursor_position |
| 意味的操作 | `inspect_ui_elements`（AX）、`click_element`、`typesafe_act`、`autonomous_act`（System 2 計画 + System 1 グラウンディング、dry-run あり） |
| ブラウザ | `browser_*`（CDP、なければ AX）。ユーザーのタブは遷移させない |
| 安全 | MCP は既定で拒否。チャットでは承認カード、承認後の再検証、SIGINT での緊急停止、ステップ予算。パスワード管理アプリ・秘密欄は撮影・読取から除外 |
| 記憶 | `search_context` / `recent_activity`（Cursor にはない独自機能） |

## 3. ギャップと判断

Computer Use の本体は「**画面を見る → 座標で操作 → 再び見る**」。MCA は操作側は揃っていたが、
**外部エージェントの目になる手段がなく**、さらに MCP 経由の `computer` は座標操作が使えなかった。

| # | ギャップ | 実コードでの原因 | 判断 |
|---|---|---|---|
| G1 | スクリーンショットを返せない | `computer` に `screenshot` がなく、MCP の結果はテキストのみ | **実装** |
| G2 | MCP の `computer` でクリック・スクロール・ドラッグが動かない | `DesktopActionAuthorization.requireApproval` がチャット用の `ActionAuthorization.current` を要求し、MCP には無いので、`mcpAllowDangerousTools: true` でも `approval_required` になる | **実装**（呼び出し元が承認済みの時だけセッションの代わりにする。セッションがあれば従来どおり） |
| G3 | 画面を縮小して渡すと座標がずれる | モデル側が画像をリサイズすると、読み取った座標が画面座標と合わなくなる | **実装**（長辺 1568px に自分で縮小し、直近のスクリーンショットの画素空間で座標を受ける） |
| G4 | `wait` がない | Anthropic Computer Use の標準アクション | **実装** |
| G5 | opt-in が粗い | `mcpAllowDangerousTools` は AppleScript・ブラウザ操作まで全部開ける | **実装**（`mca mcp --computer-use` は `computer` だけ許可） |
| G6 | 事前確認がない | `mca doctor` に computer use の状態がない | **実装**（スクリーンショットの寸法と opt-in 状態。権限が無ければ撮らない） |
| G7 | 権限の持ち主 | stdio で起動されるため、権限は **起動元（Cursor / ターミナル）** に付く。Cursor は専用ヘルパーが持つ | **未対応**。ドキュメントで明示。解消案は §5 |
| G8 | `click_element` が MCP で使えない | チャットの観測結果（`nativeObservation`）が前提 | **未対応**。MCP では `inspect_ui_elements` + `computer` を使う（注意点は §4） |
| G9 | 成果物（動画・PR 添付） | Cloud Agent の機能 | **対象外**。ローカル利用では MCP のクライアントが画像を保持する |
| G10 | 画面共有・操作の引き取り | Linux ワーカー限定の機能 | **対象外**。macOS では Ctrl+C / 起動元クライアントの停止で止める |
| G11 | Linux / X11、ワーカープール | Cursor のクラウド運用向け | **対象外**（MCA は macOS ローカルのコパイロット） |
| G12 | `zoom`、`left_mouse_down/up`、`hold_key`、複数ディスプレイ | 標準仕様の後発アクション | **見送り**（YAGNI。`left_click_drag` と主ディスプレイで足りる） |

## 4. 設計

```
Cursor / Claude Code / Codex ──stdio MCP──▶ mca mcp [--computer-use]
        ▲   image/jpeg + 寸法メモ                │ gate: AllowListToolApprover(["computer"]) / mcpAllowDangerousTools
        │                                        ▼
        └──── computer(screenshot) ◀── DisplayScreenshotProvider ──▶ ScreenCaptureKit（主ディスプレイ）
              computer(left_click …) ──▶ ComputerScreenSpace で画素→画面座標 ──▶ CGEvent
```

- `ComputerScreenshot`（`MCAReasoning/ComputerScreenshot.swift`）: JPEG、画素寸法、ディスプレイのポイント寸法。`pixelsPerPoint` を持つ。
- `ComputerScreenSpace`: 直近のスクリーンショットの `pixelsPerPoint` を保持。`computer` が受け取る全座標（`coordinate` / `start_coordinate`）を画面ポイントへ戻し、`cursor_position` は画素で返す。スクリーンショット前は恒等変換なので既存の呼び出しは変わらない。
- `ComputerActionTool.trustsCallerApproval`: MCP サーバーが `approver` の承認後にだけ立てる。`ActionAuthorization` セッションが存在する時は一切上書きしない（テストで固定）。既定は `false`。
- `AllowListToolApprover`: 名前を挙げたツールだけ承認し、残りは fallback（既定の拒否）に渡す。後から足したツールは自動的に拒否側に残る。
- `computer` のアプリ内定義（`definition`）は変えない。アプリ内エージェントは別経路で画面を受け取り、テキスト結果では画像を運べないため。MCP 用スキーマだけが `screenshot` / `wait` / `duration` を公開する。
- スクリーンショットは全画面を相手に渡すので、`computer` の操作と同じ opt-in を要求する（読み取り専用でも既定拒否）。
- 撮影は既存の `ScreenCapturer` を通すので、パスワード管理アプリとユーザー設定の除外ウィンドウは写らない。

注意（G8 の裏返し）: スクリーンショットが縮小されているとき、`inspect_ui_elements` の座標は **画面ポイント** のままで、
`computer` が読む画素座標とは一致しない。縮小率はスクリーンショットに添える文面（`px per point`）に書いてある。
長辺 1568px 以下のディスプレイ（多くの MacBook）では 1.000 で、そのまま使える。

## 5. 残る課題と次の一手

1. **権限の持ち主（G7）**: Cursor は LaunchServices から起動した専用ヘルパーが TCC の持ち主になる。
   MCA の stdio サーバーは Cursor の子プロセスなので、権限は Cursor（または Claude Code を動かすターミナル）に付く。
   解消するには、常駐する `MyComputerAgent.app`（署名済み、`getppid() == 1`）に Unix ソケットで接続する薄い stdio プロキシ
   （`mca mcp --proxy`）を足す。サーバーの認証と接続元の検証が要るので、別の仕様として切り出す。
2. **`click_element` の MCP 対応（G8）**: 呼び出し時に AX を取り直して一意に特定できるときだけ実行する。
3. **実機の受け入れ**: 下記「検証」の実機項目は、この変更の自動テストでは証明していない。

## 6. 検証

自動（実画面・実入力に触れない）:

- `ComputerScreenshotTests`（寸法・座標写像・オーバーフロー拒否・失敗時の維持）
- `ComputerCallerApprovalTests`（既定は拒否のまま／呼び出し元承認で通る／セッションが勝つ）
- `ComputerWaitTests`（承認不要・検証・上限）、`AllowListToolApproverTests`
- `ContextMCPServerComputerUseTests`（画像コンテンツ、既定拒否、`--computer-use` で通るのは `computer` だけ、スキーマ）
- 既存の `KeystrokeApprovalTests` / `ComputerToolsTests` / `ContextMCPServer*` / 数値境界テストは無変更で通る

実機（未実施なら未実施と書く）: `mca mcp --computer-use` を Cursor に接続し、スクリーンショット → クリック → スクリーンショットの往復を確認する。
手順は `docs/manual/MANUAL.md` 第7章。
