# 初回実機検証 — 2026-10-25

対象は `feature/live-computer-eval`、base `bf73dfc` の変更中バイナリ。
これは実機試験の導入・初回診断の記録であり、Computer Use全体の受け入れ合格ではない。

| 実行 | 観測結果 | 判定 |
|---|---|---|
| smoke、1試行 | 本番stdio MCP接続、1333×862pxの実画面撮影成功。実クリックはAccessibility権限不足で本番実装が拒否。保存0回 | blocked、exit 2 |
| no-input、1試行 | 本番MCPから2枚撮影。入力を送らず、保存0回。全7判定項目がfalse | failed、exit 1（期待した反例） |
| agent、Gemini `gemini-3.8-flash`、1試行 | 実画像をAPIへ送り、モデルが座標クリックを選択。本番MCPでAccessibility権限不足。保存0回 | blocked、exit 2 |

agentの初回は約10.2秒、smokeは約2.1秒、no-inputは約2.0秒（終了処理を除く）。
APIのモデル一覧に対象モデルがあることを確認して指定した。モデル応答をfixtureで置き換えていない。
実画像を確認し、不透明な検証画面が主ディスプレイを覆っていることを確認した。
両blocked実行をタスク失敗率・モデル能力の測定値に読み替えない。

証拠はworktree内 `artifacts/computer-use/initial-{smoke,no-input,agent}/`。
各 `report.json` のSHA-256で、実際に使用したMCAバイナリ・runner・fixtureを特定する。
`trial-01/result.json`、JPEG、MCP stderrも保持している。これらの実画像・実行時DBはgitに含めない。
導入中にはfixtureの前面化失敗も観測し、前面化を明示して再実行した。初期実装はfixture自身の権限を
サーバーの権限と混同していたため、そのpreflightを廃止し、本番MCPの実結果で判定するよう修正した。

採点器・プロトコルの反例を含むPythonテスト14件、MCP設定隔離のSwiftテスト3件
（不正引数4ケースを含む）、G1ビルドはPASS。これらは実入力の成功を代替しない。
最終結果は各コミットのCIと、ソースハッシュの一致も参照する。

最終版の `final-no-input` も全7項目false・exit 1、`final-smoke` は要求3試行の最初の
実クリックで同じAccessibility不足となりblocked・exit 2。残り2試行を成功やskipとして数えていない。
初期reportはblockedにも `success_rate: 0` を出していた。レビュー後に、不完全なrunは
`success_rate: null` とし、採点できた試行数を別に記録するよう変更した。

次に必要なのは起動元アプリへのAccessibility許可と、smoke→agent各3試行の再実行。
このセッションの親プロセスをcomm列だけで辿り、起動元は `/Applications/cmux.app` と確認した。
許可の変更は行っていない。実入力、保存、保存後レシート読取りの成功はまだ観測していない。
Copilotの承認経路・ブラウザ・scroll/dragなどは今回の検証範囲外。
