# AI 成果物の自動マージ（致命的リスク基準）

AI が作った変更のマージ可否を、**「その判断が覆ったとき（誤っていたと後で分かったとき）、
損害が致命的か」**で決める。致命的でなく、誤りを証拠で検知でき、`git revert` で元に戻せる変更は、
AI が人間に聞かずにマージする。致命的になりうる変更だけを人間が承認する。

```
 変更 ──▶ 致命的リスク分類 ──▶ breaker ──▶ 証拠 ──▶ auto_merge / human
          │                     │            └─ gate 緑 / テスト基準の引き下げなし / 実行比較 / 独立レビュー go
          │                     └─ 自動マージの判断が覆った（escape）カテゴリは凍結、2 件で全停止
          └─ 評価系・不可逆・影響範囲・方向性・露出・検知困難のどれかに当たれば人間
                                             │
 欠陥発見 ──▶ incident 登録（根本原因クラス + guard）──▶ gate が guard を毎回検査
          └─▶ escape 記録 ──▶ 該当カテゴリの自動マージを凍結
```

## 1. 判定の順序（`Scripts/trust/lib/decide.mjs`）

| # | 条件 | 判定 |
|---|---|---|
| 1 | ポリシーが不正（空・理由のない規則・自身を守る規則がない） | `human` — 空の規則を「全部通す」と読まない |
| 2 | `mode` が `auto_merge` でない | `human`（停止スイッチ） |
| 3 | 致命的リスク規則に該当 | `human` — 証拠がいくら揃っても変わらない |
| 4 | breaker が作動中、または触れたカテゴリが凍結中 | `human` |
| 5 | 必須の証拠（`clean`・`gate`・`executed_tests`・`bar_move`・`review`・`stable`）が 1 つでも無い、または失敗 | `human`（欠落も失敗と同じ。INC-015） |
| 6 | それ以外 | `auto_merge` |

判定は環境変数を一切読まない（INC-007）。

### 致命的リスク規則（`data/trust/policy.json` の `fatal_risk`）

各規則は、**なぜ revert では足りないか**を軸（axis）で示し、誤ったときに何が起きるかを `if_wrong` に書く。
`if_wrong` のない規則はポリシー不正として扱う。

| 軸 | id | 対象 | 誤ったとき |
|---|---|---|---|
| `self_reference` | `governance` | ゲート・フック・ポリシー・エージェント規約・`.gitattributes` | 以後の自動判定がすべて誤ったまま通る |
| `irreversible` | `persistence` | `Sources/**` のうち、変更前後のどちらかにスキーマ文（`CREATE [VIRTUAL] TABLE`・`ALTER/DROP TABLE`・`CREATE [UNIQUE] INDEX`・`DROP INDEX`・`CREATE/DROP TRIGGER`・`CREATE/DROP VIEW`・`user_version`）を含むファイルへの変更（どの行でも。INC-016） | 移行済みのデータは revert で戻らない |
| `irreversible` | `destructive` | `Sources/**`・`Scripts/**` のうち、変更前後のどちらかに削除操作（`removeItem(`・`SecItemDelete`・`DELETE FROM`・`rm -rf` など）を含むファイルへの変更（どの行でも。削除対象を別の行で変えられるため。INC-017） | 消えたファイル・Keychain・行は戻らない |
| `blast_radius` | `security` | SecretStore・SafetyGuardrails・権限・署名・entitlements | 気づく前に悪用・漏えいが起きうる |
| `blast_radius` | `dependency` | `Package.swift` / `Package.resolved` | 供給網の問題はテストで見つからない |
| `direction` | `pivot` | PROJECT.md・アーキテクチャ文書・SPEC.md・要件定義 | 以後の作業の前提が崩れる |
| `exposure` | `ui_major` | Presentation 層で 150 行以上 | 利用者に直接見え、テストでは良し悪しを判定できない |
| `undetectable` | `scale` | 10 ファイル以上 または 300 行以上 | 誤りが紛れても見つけにくい |
| `undetectable` | `unmeasurable` | パッチ本文を取得できない、または承認者に見せる diff で `Binary files differ` と表示されるファイル | 中身を誰も確認していない |

`scale` の上限は、ship パイプラインが「大規模」として人間向けのレビュー資料を必須にする線
（10 ファイル以上 または 300 行以上）の手前に合わせてある。自動マージされる変更は、必ずその線の内側に収まる。

base は常に `main` で、指定する手段はない。判定に使うポリシーは **trunk 側のもの**。ブランチ内で `policy.json` を緩めても、
その緩めたポリシーでは判定されない（そもそも `governance` で人間に回る）。

### 証拠

| id | 内容 | 自己申告を受け付けない理由 |
|---|---|---|
| `clean` | 未コミットの変更なし | diff_id に含まれないものはレビューされていない |
| `gate` | `Scripts/gate.sh --force` を assess 自身が**キャッシュなし**（`MCA_GATE_NO_CACHE=1`）で実行して緑。`--ci` では CI run が同じことをする | pass キャッシュはただのファイルで、誰でも書ける |
| `bar_move` | テスト削除・有効な assertion / `@Test` の純減・`.disabled` / `.enabled(if:)` / `withKnownIssue` の追加・独自フラグの `#if` 追加・閾値引き下げがない。**ファイル全体の変更前後**を、コメント・文字列（raw string 含む）を除き、`#if` を macOS の debug ビルドとして評価したうえで数える。新規ファイルも空ファイルとの比較で測る（独自 `ConditionTrait` の定義を捕まえる）。空の `arguments` も検知する | 「テストは緑だが、テストを弱めて緑にした」を弾く |
| `review` | 作者ではないレビュアーの記録が **現在の diff_id に束縛**され、未解決の CRITICAL/HIGH が 0 | 古い版へのレビューは今の diff について何も言っていない |
| `executed_tests` | trunk と branch の両方で `swift test` を**実際に実行**し、trunk で pass したテストが branch でも全件 pass し、パラメータ化テストのケース数が減っていない | テストの止め方は書き方を列挙しても閉じない（INC-009）。実行結果は書き方に依存しない |
| `regression_test` | `fix/*` `hotfix/*` なら Tests/ の有効な assertion が純増している | 直したことを示す証拠が必要 |
| `stable` | 証拠を集めている間に HEAD・tree・diff_id が変わっていない | 証拠は、それを集めた tree についてしか語れない |

### `--ci`：実行系の証拠を CI から取る

`gate` と `executed_tests` は `swift test` を 3 回走らせる、評価の中で最も重い部分。`assess` / `approve` に
`--ci` を付けると、これをローカルで実行せず、push 済みの HEAD に対する `ci.yml` の run（push イベント）が
`trust.mjs evidence` で集めた `trust-evidence` artifact を使う。

- artifact の `head`・`diff_id`・`merge_base` がローカルの値と 1 つでも違えば、両方の証拠を失敗とする
- HEAD が `origin/<branch>` に push されていなければ失敗。run が見つからない・artifact がない場合も失敗
- run は `ci.yml` の push イベントで、HEAD sha・branch が一致し、完了しているものに限る
- CI が何を実行するかは `.github/**` と `Scripts/**` が決め、どちらも `governance` なので、ブランチが
  CI の中身を変えた PR は証拠に関係なく人間に回る
- ブランチ自身のテスト（`Tests/**`）も同じ job で走る。trunk 側の実行はそれより**前に**済ませ、
  trunk の結果は CI ではキャッシュしない（ブランチのテストが比較の基準を書き換えられないように）
- `bar_move`・`review`・`clean`・`stable` は従来どおりローカルで判定する（静的で安い）
- main は branch protection で `Build & Test (macOS)` を必須チェックにしている

実行結果は Swift Testing のイベントストリーム（`--event-stream-output-path`、JSON Lines）から読む。
テスト ID（行・桁を除く）ごとに状態とケース数を比較するため、名前のないテストや同名の表示名でも
取り違えない（INC-011）。コンソール表示や xUnit は、表示名をキーにしていたり、ケース単位の情報を
持たなかったりするため使わない。

trunk 側は `git archive` で `<main>/.tmp/trust/base-src/` に展開して実行し、merge-base の sha と
toolchain ごとに `<main>/.tmp/trust/runs/` にキャッシュする（初回は数分、以降は即時）。共有のビルド
ディレクトリはロックで直列化し、実際にビルドしたコミットを確かめてからキャッシュする。
`bar_move`（静的）は速い一次信号、`executed_tests`（実行）が構造的な判定。

diff の解析は git の設定と属性から切り離している（`core.quotepath` / `diff.noprefix` / textconv /
`.gitattributes -diff` / NUL バイトの影響を受けない）。行数は numstat ではなく `--text` のパッチから数える。

## 2. 判断が覆ったとき（`Scripts/trust/lib/ledger.mjs`）

台帳は `<main>/.harness/trust/ledger.jsonl`（worktree をまたいで残る。git には入れない）。

- **escape**：自動マージした変更に、後から欠陥が見つかった＝機械の判断が覆った。
  - 触れたカテゴリ（`src:<モジュール>`・`tests`・`scripts`・`docs`・`other`）の自動マージを**凍結**する
  - `breaker.max_escapes`（2）件に達したら、自動マージ**全体を停止**する
  - 数えるのは `breaker.since` 以降の escape だけ。`since` を進めるのは `policy.json` の変更
    （`governance`）なので、再開には必ず人間の承認が要る
- **reconcile**：人間に回した変更への人間の回答を記録する。`trust.mjs stats` で、規則ごとに
  「そのまま承認された件数」（規則が厳しすぎる候補）と「差し戻された件数」（規則が役に立った証拠）が見える。
  規則を緩めるかどうかは、この数字を見て人間が決める

## 3. 再発防止（`data/trust/incidents.json`）

見つかった問題は、次の組にして登録するまで閉じない：

- **根本原因クラス**（kebab-case）
- **guard**：その問題を捕まえられる成果物（ツリー上に実在するもの）

| guard kind | 強さ | 例 |
|---|---|---|
| `checklist` | 弱 | レビュアーのチェック項目（`trust.mjs incident checklist` で出力） |
| `test` | 中 | 欠陥が再発すると落ちるテスト |
| `gate` | 強 | その欠陥クラス全体を落とすゲートの段や静的検査 |

- gate の `trust` ステージが毎回 `incident check` を実行する（docs だけの変更でも実行する）。
  次のどれかに当たった時点で赤になる：
  - guard のファイルが消えた
  - `contains` の文字列が消えた
  - `contains` が実行されない位置にしか残っていない（`gate` はコマンド行の先頭でない、`test` はテスト宣言でない・コメント内・skip されている）
  - `test` guard（.mjs）が、今回の実行の TAP 出力で pass していない
- `.mjs` の test guard は本体に assert があることも要求する（中身を抜かれた guard を弾く）。
  Swift の test guard は、今回の `swift test` の xUnit で、その**テスト名**が pass していることを要求する。
- ゲートの G2 は `trust`（node テスト）→ `test`（swift test、xUnit 出力）→ `guards`（incident 検査）の順。
  assess は `G2 trust PASS` と `G2 guards PASS` の両方を要求する。
- guard の置き場所は kind ごとに決まっている：`test` は `Tests/**.swift` か `Scripts/**/tests/*.test.mjs`、
  `gate` は `Scripts/gate.sh`、`checklist` は `docs/**.md`。作者が kind を自己申告して水増しできない。
- `Scripts/trust/tests` に skip / todo のテストがあると、trust ステージは赤になる。
- **同じクラスが `recurrence_limit`（2）回起きたら**、最新の incident には `test` 以上の guard が
  必要になる。弱い guard は既に一度破られているため。
- `escape` は incident ID なしでは記録できない。guard を作る前にカテゴリを凍結しても、
  次の再発は防げないから。

## 4. 運用フロー（Pre-Ship）

```bash
T=/abs/main/Scripts/trust/trust.mjs     # 評価器は main 側のものを使う（ブランチ側は改変されうる）
WT=.worktrees/feature/<task>

node $T diff-id --worktree $WT          # 1. レビュアーに渡す id
node $T incident checklist              #    過去の incident 由来のチェック項目も渡す
#                                          2. 作者と別コンテキストのレビュアーが review.json を書く
#                                          3. Pre-Ship の approval 以外のステップを済ませる
node $T approve --worktree $WT --review review.json
#   exit 0 AUTO_MERGE → approval が source: trust で記録される。そのまま /create-pr ship-worktree
#   exit 3 HUMAN      → 理由を Pre-Ship Panel に添えて人間に承認を求め、回答後に:
node $T reconcile --worktree $WT
node $T stats                           #    自動マージ数・breaker・規則ごとの人間の回答
```

`approve` は Pre-Ship のステップ実行器の `recordAnswer` を通して approval を記録する。
順序（他のステップが済んでいること）と diff への束縛は人間の回答と同じく強制される（INC-014）。

- 判定した diff・HEAD と一致することを**書き込む前に**確かめ、`source: "trust"` と判定理由を付けて
  1 回の原子的な書き込みで記録する。判定後にツリーが動いていれば何も書かない
- 人間が abort / revise と答えたブランチの回答は**上書きしない**。人間が止めたものは人間に残す
- `reconcile` は `source: trust` の回答を人間の回答として取り込まない

自動マージに進んでよいのは、exit 0 で、`TRUST AUTO_MERGE` と記録完了の行が出力されたときだけ。
exit 0 は「何も実行されなかった」場合と区別できないため、それだけでは判断しない（INC-012）。
記録がなければ、ship 側の approval ステップも通らない。

判定だけを見たいときは `assess`（`--dry-run` で台帳にも記録しない）。

着地後に欠陥が見つかった場合：

```bash
# 1. data/trust/incidents.json に guard 付きで登録する（guard は同じ PR で追加）
# 2. 判断が覆ったことを記録する（カテゴリが凍結される）
node $T escape --incident INC-00N --diff-id <id>
```

### review.json

```json
{
  "diff_id": "<trust.mjs diff-id の出力>",
  "reviewer": "fresh-context subagent (not the author)",
  "verdict": "go",
  "findings": [
    { "severity": "MEDIUM", "file": "Sources/...:42", "summary": "...", "resolved": false }
  ]
}
```

## 脅威モデルと既知の限界

ローカルでは、作者（AI）と評価器が同じ OS ユーザーで動く。評価器が読むもの（台帳・review.json・
Pre-Ship 回答・ゲート・trunk 実行のキャッシュ）は、原理的にすべて作者も書ける。
2026-10-06、リポジトリが public になり macOS runner とブランチ保護が無料で使えるため、実行系の証拠を
CI に移した（`--ci`）。それ以外は**強制ではなく手順**であり、次のリスクを受け入れている：

- AI が手順を無視して `gh` で直接マージすることは、ブランチ保護（CI 必須）で CI 赤のままでは塞がれるが、
  CI 緑・レビューなしのマージは防げない（AI はあなたの gh トークンを使う）
- review.json の作者が本当に別コンテキストかは検証できない（INC-003）
- 台帳の escape を AI が消せば breaker は戻る
- `breaker` の値はポリシー検証で ISO-8601 の過去の日時と正の整数に限る。読めない escape の時刻は数える側に倒す（INC-015）

この受け入れが致命的にならないように、次の範囲は機械の判定に関係なく人間が承認する：
評価系そのもの（`governance`）と、revert で戻らない・影響が外に及ぶ変更。誤って自動マージされた
変更が残りうるのは「revert で戻せる、小さい、テストとレビューを通った」範囲に限られる。

その他：

- bar_move も executed_tests も**件数と実行有無**で測る。本物の assertion を `#expect(true)` に置き換える、
  テスト本体の先頭で `return` する、といった「実行されて pass するが何も検証しない」ものは捕まらない。
  これはレビュアーが見る領分
- `destructive` と `persistence` の検知は文字列ベースで、ファイル単位。削除操作やスキーマ文を**別ファイルの**ラッパー経由で呼ぶと、呼ぶ側のファイルの変更は見えない
- 台帳はローカル（`.harness/`）にあり、マシンをまたいで共有されない
- main へのマージはリリースではない（配布物は G3 を人が明示的に通したときだけ作られる）。
  自動マージの誤りが利用者に届く前に revert できる時間があることも、この基準の前提になっている

## 経緯

この仕組みの最初の版は、独立レビュアー（作者とは別コンテキストのサブエージェント）に
**no-go**（CRITICAL 1 / HIGH 7 / MEDIUM 5 / LOW 2）と判定された。指摘は INC-002〜004 として登録し、
それぞれに test / gate guard を付けて修正した。INC-002 は INC-001 と同じクラスの再発なので、
ラダーの規定により `test` 以上の guard が必須になっている。

修正版の再レビューでは、元の 15 件のうち 13 件の解決が確認されたが、新たに HIGH 2 件を含む 8 件が
見つかった（INC-005〜008）。`evaluator-blind-spot` は 3 回目、`hollow-guard` と `forgeable-evidence`
は 2 回目になった。どちらの対策も「書き方の列挙」から「実際に何が起きるか」（コンパイラの評価・
今回の実行の TAP・作者が書けない場所）へ寄せている。

3 回目のレビューでも `evaluator-blind-spot` が 4 回目の再発（`.enabled { false }`・`TestScoping`・
`swift(<5.0)` など）となったため、列挙をやめて **trunk と branch のテスト実行結果の比較**
（`executed_tests`）に切り替えた（INC-009）。実ブランチで `.enabled { false }` と引数の削除を仕込んだ
E2E 検証で、両方が「trunk で pass、branch では skipped」「ケース数 4 → 3」として検出されることを確認した。

4 回目のレビューで **go**（CRITICAL / HIGH なし）となった。残った MEDIUM のうち、ケース数を表示名で
数えていた問題（名前なし・同名テストでの見逃し）と trunk ビルドの排他なしは、INC-011 として修正した
（実出力の fixture を使うイベントストリーム解析、ロック、toolchain を含むキャッシュキー）。

2026-09-26、shadow モード（判定を記録するだけで人間が承認）を廃止し、「判断が覆ったとき致命的か」を
基準に AI が自動マージする方式に切り替えた（ユーザーの決定）。実績による昇格・抜き取り監査・
ローカル CLI の `would_auto` 上限（`TRUSTED_RUNNER = false`）は削除し、代わりに致命的リスクの軸
（`if_wrong` の明記を必須化）、不可逆な削除操作の検知、escape による凍結と停止（breaker）を加えた。
