# サブエージェントを単一のエージェントループへ畳み込む

Anthropic の [Building agents: When to fold subagents into your main agent loop](https://claude.com/resources/articles/building-agents-when-to-fold-subagents-into-your-main-agent-loop)
を、このリポジトリに当てはめた記録。記事の主張は次の 3 点に尽きる。

1. ルーター・プランナー・領域別サブエージェントは、1 つのループ＋段階的に開示する skill と tool に畳めることが多い。
   計画を書くモデルが実行もするので、結果を見て計画を途中で変えられ、要約による情報の欠落と入れ子ループの待ち時間がなくなる。
2. サブエージェントを残してよいのは次の 3 条件のどれかが**測って**成り立つときだけ。
   (a) 文脈の肥大で単一ループの性能が落ちる、(b) 捨ててよい新しい文脈で並列に解く仕事がある、
   (c) 単一エージェントがツールを選び損ねる・指示が衝突する。
3. 移行は一度にやらない。小さな end-to-end eval を先に作り、1 つずつ畳み、畳んだ版のほうが悪いときだけ戻す。
   比較では総合点ではなく**どのタスクが反転したか**を見る。

## 結論（2026-10-25）

| 変更 | 根拠 |
|---|---|
| 回答用モデルがあるとき、`RequestRoute` は triage の推定だけでは `.autonomousLoop` に送らない（明示の `/act` `/goal` とキーなしは従来どおりループ） | `Evals/agent-loop` でループへのハンドオフ 9/20、メインループで計画 19/20 |
| `Agent.answer` の重複ガードを「ターン全体」から「直前のラウンド」に狭めた | 操作をはさんだ再観測（inspect → click → inspect）を重複とみなして打ち切っていた。修正前の計測で畳み込み版の失敗の大半がこれだった |
| ループをツール化した `run_desktop_task` は、アプリには登録しない（eval の比較対象として残す） | 17/20 でメインループ単独（19/20）より悪く、遅い（21.1s 対 14.1s） |
| キーはあるがモデルに届かない（オフライン・レート制限）とき、キーなしならループに行く依頼はループで実行する | ルーターを畳む前は offline fallback で動いていた依頼が、エラーで終わらないように（独立レビューの指摘） |

## 現状の棚卸し

ユーザーの依頼は `Copilot.ask` で次のように流れる。

```
質問 ─ triageGoal（意図分類）─ RequestRoute.decide（ルーター）
          ├─ .autonomousLoop  → TwoTierAutonomousLoopCoordinator（System 2 計画 + System 1 実行）… 回答を返さない
          └─ .agentWithComputer / .agentWithScreen / .agentChat → Agent.answer（ツールループ）
```

| 構成要素 | 記事での分類 | 判定 | 理由 |
|---|---|---|---|
| `Agent.triage`（常時監視の割り込み判定） | 安くてほぼ常に要る前処理 | **残す** | 24/7 で回る経路。オンデバイスのゲートがないとコストが 50 倍になる（`docs/architecture_v2_design_proposals.md` 制約 3）。記事も「安くてほぼ常に関係するものはコードで読み込んでよい」としている |
| `triageGoal` + `RequestRoute.decide` | 意図分類 + ルーター | **畳んだ（モデルがあるとき）** | 下の計測。キーなし利用者には `Agent.answer` が動かず、ループの offline fallback だけが操作できるので、その経路は残す |
| `TwoTierAutonomousLoopCoordinator` + `DefaultSubgoalPlanner` | プランナー + 実行サブエージェント | **キーなしと明示 `/act` の経路として残す** | ユーザーと直接話さないので、記事の基準ではモデルがある場合に全面ハンドオフする理由がない |
| `TypeSafeActTool`（System 1 の 1 手） | ツール | そのまま | メインループのツール |
| `BrowserInference`（`browser_act` / `observe` / `extract` 内のモデル呼び出し） | ツール内の入れ子モデル呼び出し | 保留 | ページ outline を本体の文脈に入れない役割（条件 a）がある。測るまで動かさない |
| `QueryExpander`（`search_context` 内） | ツール内の入れ子モデル呼び出し | 残す | オンデバイスで無料、出力は検索語だけで文脈を汚さない |

当てはめないもの（いまは必要がない）：

- **tool search / 遅延読み込み**：本体のツールは約 25 個で、記事が劣化の目安とする 30〜50 を下回る。
- **skill による手順の段階的開示**：`Prompts.assistant` は 60 行足らずで、肥大していない。ブラウザ・ファイル編集の手順が増えて衝突し始めたら skill 化する。
- **ツール呼び出しの並列実行**：GUI 操作は順序に依存する。読み取り系だけを並列にする余地はあるが、別の変更として測る。

## eval

| eval | 測るもの | 実行 |
|---|---|---|
| `Evals/system-one`（routing / decision） | キーなしでルーターが選ぶ経路と System 1 の一手 | `swift test`（G2）と `hillclimb.mjs` |
| `Evals/agent-loop`（タスク完了） | 同じタスクを 3 つの構成で解かせ、最終状態・回答・禁止操作で採点 | `MCA_AGENT_EVAL=1` のときだけ（下記）。G2 ではタスクファイルの健全性だけを確かめる |

```bash
MCA_AGENT_EVAL=1 MCA_AGENT_EVAL_RUNS=2 MCA_EVAL_REPORT=.tmp/eval/agent-loop.json \
  secret run GEMINI_API_KEY -- swift test --filter AgentLoopEval
```

`AgentLoopEvalTests` は模擬デスクトップ（画面ごとの AX 要素・状態・遷移）を `UIStateProviding` と
`EventSynthesizing` として差し込む。構成の違いは計画をどこで立てるかだけにそろえてある。

- `handoff`：今日の `.autonomousLoop`。ループを走らせ、ユーザーに見えるのは終了メッセージだけ。
- `folded`：`Agent.answer` が自分で計画し、1 手ずつのツール（`inspect_ui_elements` `click_element` `typesafe_act`）で操作する。
- `tool`：`folded` に `run_desktop_task` を足したもの。

System 1 はどの構成も決定論的な offline エンジン、回答モデルはアプリ既定の `gemini-3.8-flash`。
タスク 10 件は、本番で連続して動く連鎖ごとに 1 件（移動→クリック、クリック→入力、操作→回答、スクロール→発見、
誤った画面からの復帰、複数欄の入力）と、破ってはいけない規則ごとに 1 件（破壊的な選択肢を選ばない、
確認してから変える）を入れた。各タスクを 2 回走らせる。

既知の限界：`computer`（スクリーンショット座標）と `run_applescript` は模擬できないため `folded` から外している。
本番の `folded` はこれらも持つので、測った値は本番より道具が少ない条件での値である。

### 計測（2026-10-25、各タスク 2 回）

| 構成 | 重複ガード修正前（1 回） | 修正後（2 回） | 平均時間（修正後） |
|---|---|---|---|
| handoff | 4/10 | 9/20 | 16.0s |
| folded | 6/10 | **19/20** | **14.1s** |
| tool | 5/10 | 17/20 | 21.1s |

| タスク | handoff | folded | tool |
|---|---|---|---|
| t-dark-mode | PP | PP | PP |
| t-wifi-off | PP | PP | PP |
| t-note-create | PP | PP | FF |
| t-mail-amount | FF | PP | PP |
| t-macos-version | FF | PP | PP |
| t-save-dialog | PP | PP | PP |
| t-contact-form | FF | PP | PP |
| t-back-first | FF | PF | FP |
| t-scroll-privacy | PF | PP | PP |
| t-already-dark | FF | PP | PP |

反転したタスク：

- **handoff → folded で改善**：答えを求める 3 件（請求額・macOS のバージョン・確認してから変える）は、ハンドオフでは構造上答えが返らない
  （ループの終了メッセージは "All subgoals completed successfully."）。フォームは、ループの System 1 が値ではなく欄の名前を打ち込んだ。
- **tool が folded より悪い**：t-note-create は 2 回とも、ループの System 1 が `body` と打ち込み、本体は直せないまま「作成しました」と答えた。
  t-back-first #1 は、ループが禁止の Wi-Fi トグルを押したうえで成功と報告し、本体はそれを信じた。記事の言う「要約による欠落」がそのまま出た。
- **folded の残り 1 件**：t-back-first #2 は、Wi-Fi 画面で「外観の項目がない」と止まり、戻るを押さなかった。
  #1 は通っており、2 回に 1 回しか出ない反転だった（記事の例と同じ。1 回だけの計測では見落とす）。
- **重複ガード修正前**：folded / tool の失敗の大半は「同じツール呼び出しが重複して繰り返されたため、処理を中断しました」だった。
  クリック後に `inspect_ui_elements({})` で見直す正当な手順が、ターン内の同一呼び出しとして打ち切られていた。
  記事の `prompt-audit` が狙う「古いモデル向けに足され、いまはエージェントを硬直させる規則」の例。

この比較の読み方（独立レビューの指摘）：

- 答えを求める 3 件は handoff が構造上満たせないので、handoff の上限は 14/20。それを除いた 7 件でも
  handoff 9/14・folded 13/14・tool 11/14 で、順序は変わらない。
- 3 件の出典は「ループが答えを返さない」という既知の不具合クラスで、folded に有利な側から選んである。本番の出典で足していく。
- 2 回・1 モデル・人が書いたタスクでの差である。合否はすべて作者が書いたタスクと採点器から出ており（INC-003 / INC-007）、
  この結果だけで変更を自動マージしない。経路の変更は人間の承認を通す。
- eval は承認の門（`ActionAuthorization` のセッションとウィンドウ範囲）を通していない（`AutoApproveToolApprover` と
  `trustsCallerApproval`）。本番の `Copilot.ask` は `agent.answer` をセッションで包むので、クリックとキー入力の承認は
  `.agentWithComputer` の既存経路と同じ。

`Evals/system-one` は変わらない（キーなしの経路は変えていない）：train 50/54、heldout 25/28、ノイズ 0、`hillclimb.mjs` の判定は NO CHANGE。

## 次の一手

### 全セルを残す比較

`AgentLoopEval` の JSON は、合計だけでなく task × variant × repeat を照合する:

```bash
node Scripts/eval/summarize-agent-loop.mjs .tmp/eval/agent-loop.json --runs 2
```

既定は全タスク・3 variant。部分比較では `--variants folded,tool` を明示する。
欠けたタスク・variant・repeat、重複や矛盾する合否は exit 2（証拠不足）となる。
出力は全セルの P/F、失敗理由、合否が揺れたタスク、平均時間・ツール回数。
exit 0 は集計できたという意味だけで、変更の採用やリリースの承認ではない。

比較前に仮説・対象タスク・variant・繰り返し数・予算を PLAN に固定する。
モデル・プロンプト・道具を一度に変えず、失敗セルも記録する。パラメータを選ぶなら
事前に決めた近傍条件でも測り、孤立した最高値だけで採用しない。時間に依存する
観測には取得時点を残し、未来の情報を混ぜない。独立レビューには raw report と
比較元の commit を渡す。成功率と時間が相反する場合は trade-off として残す。
改善しない実験もこの文書またはタスク報告に残し、再試行する新しい根拠を明記する。
既存の System One heldout はそのまま保持し、探索のために開いたり変更したりしない。

- **eval を本番の出典で増やす**：模擬タスクは人が書いた 10 件。本番で誤った操作・答えが観測されたらタスクにする（`docs/evals/system-one.md` と同じ方針）。
- **プランナーの扱い**：ループはキーなしと `/act` の経路で残る。キーなしの体験を上げるなら offline の System 1（値ではなく欄の名前を打つ）を直すのが先。
- **再計測の契機**：回答モデル・System 1・ツール構成が変わったら `AgentLoopEval` を 3 構成で回し直す。`tool` が `folded` を上回ったら `run_desktop_task` の登録を検討する。

## 運用の原則

- システムプロンプトと end-to-end の品質は 1 か所が持つ。新しいツール・指示・eval は、足す前にこの文書の判定表に照らす。
- 新しい「専門エージェント」を足したくなったら、まず上の 3 条件のどれが測って成り立つかを書く。書けなければ skill か tool にする。
- 1 回に 1 つだけ変え、測り、持ちこたえたものだけを残す。
