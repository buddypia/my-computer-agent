# System One eval と hillclimb

Anthropic の [Automating eval design and hillclimbing](https://claude.dev/blog/automating-eval-design-and-hillclimbing/)
の手順を、このリポジトリの System One（`TypeSafeDecisionEngine`）に当てはめたもの。

## 何を測るか

ユーザーが毎回最初に通る 2 つの判断を測る。

| kind | 対象 | 出力 |
|---|---|---|
| `routing` | `triageGoal` → `RequestRoute.decide`（Copilot と同じ関数） | `loop` / `agent_action` / `agent_screen` / `agent_chat` |
| `decision` | `decideNextAction`（候補要素に対する次の一手） | action・target・completed・keys・text・scroll・escalate |

既定は **offline**（TypeSafe API 未設定時の決定論的 fallback）で測る。これがキーのない利用者が実際に受け取る挙動で、
変更コストはヒューリスティックの数行と安く、指標への帰属も明確に取れる（記事の「安い反復・帰属・狭い目的」）。

## eval の 4 条件をどう満たすか

| 条件 | この eval での扱い |
|---|---|
| 本番整合 | ケースの出典は `source` に記録する（`incident:#29` `incident:#31` = 実際に起きた不具合、`test:ScreenIntent` = 既存の仕様、`hand:*` = 本番で起きうる発話を人が書いたもの）。routing は Copilot から切り出した `RequestRoute` をそのまま採点し、再実装は採点しない |
| 能力スケール | `MCA_EVAL_ONLINE=1` で同じケースを、アプリと同じ規則で選んだモデル（`MCA_SYSTEM_ONE` で固定可）に流す。online が offline を下回るなら eval か online 経路を疑う。Cloudflare Clef での結果は下の「online 測定」 |
| headroom | 作成時点の baseline は train 72.2% / heldout 57.1%。heldout が 95% を超えたら `run` が警告を出す |
| 低分散 | 全ケースを同一プロセス内で 2 回実行し、出力が一致しないケースがあれば失敗にする（現状はノイズ 0。最小の有意な改善 = 1 ケース）。プロセスごとに変わる hash seed 由来の揺れまでは検出しない |

ケースは「今のモデルが落ちるもの」を集めたのではない（adversarial sampling の回避）。実装を走らせる前に、
期待挙動とケースを先に書いた。曖昧なケース（人が見ても正解が割れるもの）は入れていない。

## grader

すべてプログラムで採点する。`expect` に書いたフィールドだけを比較し、書いていないフィールドは問わない。
正解が複数ある場合は `alsoAccept` に並べる（例：ダイアログを閉じるのは Close クリックでも Escape でもよい）。
ケースを読めない、または report が出ないものは **harness error** として扱い、モデルの失敗には数えない。

```jsonl
{"id":"d-done-btn","kind":"decision","source":"hand:keyword-collision",
 "input":{"goal":"Click the Done button","candidates":[{"id":"btn-done","role":"AXButton","label":"Done","bounds":[100,100,120,30]}]},
 "expect":{"action":"click","target":"btn-done","completed":false}}
```

decision の `input` には `history`（`[{action, keys}]`）・`escalations`（`lowConfidence` / `actionStagnant`）・
`unchanged`（直前の diff が無変化か）も書ける。

## 過学習を防ぐ仕組み

- `Evals/system-one/train.jsonl` と `heldout.jsonl` に分ける。割り当ては id の FNV-1a ハッシュで決まり（30% が heldout）、後から動かない。
- **optimizer（人でもエージェントでも）は `heldout.jsonl` を開かない。** report には heldout の集計しか書き出さないので、
  `run` の出力を読むだけなら held-out の中身は見えない。
- 失敗したケースの文言をプロンプトやキーワード表へそのまま貼らない。根本原因のクラス（部分文字列衝突など）を直す。
- 既知の漏れ：初期の 82 件は同じ作者が書いたため、heldout の中身を作者が知っている。以後のケースは本番の不具合報告から足す。

## hillclimb の手順

```bash
node Scripts/eval/hillclimb.mjs run --note "r8: <1 つだけの変更>"   # train の失敗詳細 + 両 split のスコア + 判定
node Scripts/eval/hillclimb.mjs accept                               # KEEP のときだけ baseline を更新
```

1. `run` の train 失敗だけを読み、根本原因でまとめる。
2. **1 回に 1 つ**、原因クラスを直す変更を入れる。
3. `run` の判定に従う。
   - `KEEP`：train と heldout の**両方**が改善 → `accept` してから `swift test` 全体を通す
   - `REVERT`：どちらかが悪化、baseline で通っていた train ケースが 1 件でも落ちた、出力が非決定的、または **train だけ**が改善（過学習とみなす）→ 変更を戻す
   - `REVIEW`：heldout だけが改善 → 変更が原理的かを確かめてから判断する
4. 3 ラウンド続けて KEEP が出なければ `STALLED` と表示される。止めて、残った失敗を
   「曖昧なタスク / grader の誤り / harness の誤り / 本物の能力不足」に分類する。

`history.jsonl` は全ラウンドの台帳で、REVERT したラウンドも残す。

## ゲートとの関係

`SystemOneEvalTests` は `swift test`（G2）の一部として毎回走り、次を強制する。

- 全ケースが読めること（harness の健全性）
- 2 回の実行で出力が一致すること（低分散）
- 通過数が `baseline.json` を下回らないこと（regression floor。offline のみ）

床を上げるのは `accept` だけ。ケースや grader を変えたときは `accept --force` を使い、理由を note に残す。
床を下げる変更は採点基準の引き下げなので、人間の承認を通す。

## ケースの足し方

本番で誤った routing や操作を見つけたら、そのままケースにする（これが最も価値の高い出典）。

```bash
# 1 行 1 ケースの pool を書き、split で train / heldout に振り分ける
node Scripts/eval/hillclimb.mjs split /path/to/pool.jsonl
node Scripts/eval/hillclimb.mjs run --note "cases: +N from <出典>"
node Scripts/eval/hillclimb.mjs accept --force
```

## 実施記録（2026-10-02）

| ラウンド | 変更 | train | heldout | 判定 |
|---|---|---|---|---|
| baseline | — | 39/54 (72.2%) | 16/28 (57.1%) | — |
| r1 | アクション動詞を含む goal では完了キーワード（done/完了/success…）で完了扱いにしない | 43 | 17 | KEEP |
| r2 | triage でブラウザ名単体（chrome, twitter, "search" 内の "arc"）を操作要求とみなさない | 45 | 21 | KEEP → 既存テスト（Firefox 操作）が落ちたため r2b に差し替え |
| r2b | ブラウザ名は操作語と同時に現れたときだけ browser 扱い | 45 | 21 | KEEP |
| r3 | 文頭の英語命令形（Open / Close / Press…）を操作とみなす | 48 | 22 | KEEP |
| r4 | スクロール方向を単語単位で判定（"updates" の "up" で上に行かない）。停滞時の PageUp/PageDown も同じ判定を使う | 49 | 23 | KEEP |
| r5 | triage に韓国語の操作語（스크롤・수집・클릭・눌러…）を追加 | 50 | 25 | KEEP |
| r6 | "search for X" を入力要求とみなす | 51 | 25 | REVERT（train のみ） |
| r7 | 韓国語の画面キーワード "보고" を "보고 있" に狭める（"보고서" = 報告書） | 51 | 25 | REVERT（train のみ） |
| review | 独立レビューの指摘を修正：完了判定の動詞を単語単位・依頼形で照合（"入力が完了" は完了のまま）、スクロール方向をかなに隣接しても読めるようにし、"下から上へ" を上のままにした。verdict にケース単位の回帰検知を追加 | 50 | 25 | 変化なし（baseline に失敗 id を記録） |

結果：train 72.2% → 92.6%、heldout 57.1% → 89.3%。r6・r7 で 2 ラウンド続けて KEEP が出なかったため、ここで止めた。

### 残った train の失敗（根本原因別）

| ケース | 原因 | 分類 |
|---|---|---|
| `r-q-python-file`「Pythonでファイルを開いて…コードを書いて」 | 依頼の対象がコードであり、画面操作ではないことを見分けていない | 本物の能力不足（キーワード方式の限界） |
| `r-q-screenshot-howto`「How do I take a screenshot on Mac?」 | how-to 質問を画面についての質問と区別していない | 本物の能力不足 |
| `r-q-ko-report`「보고서 쓰는 팁 알려줘」 | 部分文字列の衝突。r7 で直せるが heldout が動かない | 単発。似たケースが集まってから再挑戦する |
| `d-search-for`「Search for swift concurrency」 | 入力語彙の不足。r6 で直せるが heldout が動かない | 単発。同上 |

前の 2 件は、キーワード方式の offline fallback で追いかけると過学習になりやすい種類の誤りである。
レビューで指摘された未対応の弱点も記録しておく。英語の命令形は文頭しか見ないため "Please open Safari" を拾わない。また、操作語と同時に現れたときの "arc" / "edge" は部分一致のままである。これらは本番で誤りが観測されたらケースとして足す。

## online 測定（2026-10-03, Cloudflare Clef）

```bash
MCA_EVAL_ONLINE=1 MCA_SYSTEM_ONE=clef MCA_EVAL_REPORT=.tmp/eval/online-clef.json swift test --filter SystemOneEval
```

1 回の実行に約 5〜7 分かかる（82 ケース × 2 回、1 回 1〜3 秒）。online の結果は baseline の床に入れない。
`hillclimb.mjs run` は offline 専用のまま。
eval はスクリーンショットを渡さないので、測っているのは**テキストのみ**の判定である。本番の「迷ったときだけ画像を足す」再判定は含まない。

| モデル | 変更 | train | heldout | 2 回で答えが変わったケース |
|---|---|---|---|---|
| offline（参考） | — | 50/54 | 25/28 | 0 |
| clef-flash（9B） | — | 45/54 | 25/28 | 6 |
| clef（27B） | — | 47/54 | 26/28 | 0 |
| clef（27B） | ループ防止の規則をモデルの判断にも適用（**取り消し済み**、下記） | 51/54 | 27/28 | 2（heldout のため中身は見ない） |

- online で落ちた判断ケース 4 件（`d-stagnant-*`, `d-graceful-recovery`）は、どれも offline fallback のループ防止の規則（停滞したら PageDown、境界に着いたら完了、低確信の escalation が 2 回で完了）を期待している。
  この規則をモデルの判断にも適用すると eval は両方改善した。しかし、coordinator の既存テスト 3 件が落ちたため、この変更は取り消した。
  モデル経路では、停滞したら coordinator が System 2 に escalate して立て直す設計で、engine 側の規則はそれを横取りしてしまう。
  **分類：grader の誤り**（期待値が offline 専用の挙動を書いている）。ケースに経路ごとの期待値を持たせるかは、ケースセットの変更として別途判断する。
- そのため、マージされたコードのテキストのみの値は 47/54・26/28 と読む。
- Clef のモデルは clef（27B）を推奨する（`MCA_SYSTEM_ONE=clef`。Clef 自体は opt-in で、既定の backend ではない）。clef-flash より正答が多く、ぶれも少なく、テキストのみなら速さもほぼ同じ（1〜3 秒）だった。
- routing で落ちる train ケースは 3 件。`r-q-ko-report` と `r-q-screenshot-howto` は offline でも落ちる。`r-l-press-save` は、確信度 0.80 未満のため loop に回らなかった。
- 2 回の実行で答えが変わるケースがある。0.80 の閾値付近の確信度が実行ごとに揺れるとみられ、online の差分は 2 件以内ならノイズとして扱う。
- heldout の集計は、この測定で 4 回（clef-flash、clef、規則適用版、取り消し判断の確認）読んだ。中身は開いていないが、変更の採否に heldout の数字を使ったのは規則適用版の 1 回だけで、その変更は最終的に取り消した。

## 完了判定の方針変更（2026-10-03）

画面操作エージェントの作業（承認付きの自動操作）を取り込む際、offline fallback の完了判定を次の方針に揃えた（ユーザー決定）。

- 目標文の言葉（「完了しました」「done」など）だけでは完了にしない。完了は画面で確かめた結果からだけ判断する。
- 低確信の escalation が 2 回続いたときも、完了扱いで諦めず System 2 に回す。

これに合わせて `d-graceful-recovery` の期待値を `completed: true, escalate: false` から `completed: false, escalate: true` に変えた。
変更後も train 50/54・heldout 25/28 で baseline と同じ（ノイズ 0）。


## 2026-10-04 evaluation checkpoint

On the refreshed current-main candidate (`5f23e868` base), the required `node Scripts/eval/hillclimb.mjs run` result was train 50/54 (baseline 50/54), heldout 25/28 (baseline 25/28), noise 0, **NO CHANGE / STALLED after 3 rounds**. The four unchanged train misses are `r-q-python-file`, `r-q-ko-report`, `r-q-screenshot-howto`, and `d-search-for`. Both-score improvement remains unmet. The heldout file was not opened; grader, floor, and baseline were not changed. Preserve this run as a no-change outcome and resume only with a principled root-class change.


## 2026-10-04 follow-up — train-only attempt reverted

A narrow routing/search attempt scored train 54/54 versus baseline 50/54, while heldout stayed 25/28 versus baseline 25/28; the harness returned REVERT for train-only gain. The changes were removed. During the same investigation, a diagnostic grep accidentally exposed part of the prohibited heldout JSONL to the agent context. No excerpt is reproduced or used, but this session's blind independence is compromised; do not use the observed aggregate as uncontaminated blind acceptance. No grader, floor, or baseline change was made.

## 2026-10-04 online retry after Cloudflare CLI authentication

`cf auth whoami` confirmed the unified Cloudflare CLI session. The current `CloudflareClefClient` obtains its runtime token through `wrangler auth token`, and the online test reached the Clef model successfully. Command:

```bash
MCA_EVAL_ONLINE=1 MCA_SYSTEM_ONE=clef MCA_EVAL_REPORT=.tmp/eval/cloudflare-cli-auth-retry.json swift test --filter SystemOneEval
```

Aggregate result: train 48/54, heldout 27/28, with 38 nondeterministic cases across the two passes; the test failed its existing determinism assertion after about 238 seconds. No heldout case contents were inspected. This remote run does not replace the frozen offline hillclimb acceptance, and its noisy result was not used to tune source or evaluation policy. The report is an ignored `.tmp` artifact.

## 2026-10-04 resumed offline attempts

Two independent source hypotheses were tested and reverted under the unchanged policy:

| Hypothesis | train | heldout | Result |
|---|---:|---:|---|
| Separate code-composition/how-to requests from screen-operation keywords; narrow the Korean screen-term boundary | 53/54 | 25/28 | REVERT (train-only gain) |
| Interpret a search request as text entry only when the current observation exposes an `AXSearchField` | 51/54 | 25/28 | REVERT (train-only gain) |

The attempts and aggregate outcomes are retained in `history.jsonl`. Neither changed the final source, grader, floor, baseline, or heldout cases. As noted above, the heldout file was accidentally exposed to this session earlier; do not treat this session's heldout score as an independent blind acceptance result.
