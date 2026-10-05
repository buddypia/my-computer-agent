# Browser Automation — SPEC

Status: **implemented**

## 目的
エージェントがブラウザ上のタスク（検索、ログイン後の情報取得、フォーム入力、構造化抽出）を、座標や OCR ではなく **ref 付きアクセシビリティアウトライン**と**決定論的 CDP 操作**で実行できるようにする。

## 要件
- R1. ページを `[ref] role: name` 形式で取得できる。ref はスナップショット単位で有効、未知 ref は `stale_ref` を返す。
- R2. ref に対して click / fill / type / press / select / scroll / hover / dblclick / drag が決定論的に実行できる。
- R3. 自然言語 1 手 (`browser_act`) は observe → 実行 → 失敗時 self-heal、twoStep 時は差分で 2 手目。
- R4. 既存の Chrome（`--remote-debugging-port`）に接続し、**ユーザーのタブは遷移させない**。最後のタブは閉じない。
- R5. DevTools が無い環境では macOS Accessibility で同じ outline 形式を提供する（機能縮退は明示エラー）。
- R6. 秘密は `%variables%` で渡し、プロンプトに乗せない。
- R7. アプリ内エージェント、`mca ask`、MCP、`mca browser` CLI の 4 経路から同じツールを使える。

## 非目標
- Playwright / Puppeteer への依存。
- ユーザーのブラウザプロファイルの複製。

## 受け入れ基準
- `swift test`: `AccessibilityOutlineTests`, `CDPClientTests`, `BrowserToolsTests` が緑。
- 実 Chrome で `mca browser navigate → snapshot → fill → press → wait → snapshot` が通る。
