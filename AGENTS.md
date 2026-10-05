# AGENTS.md

エージェント（Claude Code / Codex CLI など）がこのリポジトリで作業するときの規約。

## 品質ゲート

コードに触れた作業は、応答を終える前に必ずゲートを通す。

```bash
Scripts/gate.sh
```

段階は費用の安い順に並んでおり、失敗した時点で以降は打ち切られる。
コンパイルの通らないツリーにテストを走らせても得られる情報がないため。

| | ステージ | コマンド | 既定 | 実測 |
|---|---|---|---|---|
| G0 | 変更分類 | — | 自動 | 即時 |
| G1 | ビルド | `swift build` | 実行 | ~20s |
| G2 | trust | `node --test Scripts/trust/tests/*.test.mjs` + `trust.mjs incident check` | 実行 | ~1s |
| G2 | テスト | `swift test` | 実行 | ~12s |
| G3 | リリース束 | `Scripts/bundle.sh` | **手動のみ** | 数分 |

G3 が既定に入っていないのは、`build/` を作り直して `codesign` を走らせるためで、
これはエージェントが毎ターン行ってよい副作用ではない。リリース前に人が
`Scripts/gate.sh --stage 3` として明示的に通す。

### G0 がスキップする条件

変更が次のパスのみに収まる場合、ゲートは何も実行せず終了する。

```
*.md  *.markdown  *.txt  docs/**  LICENSE  NOTICES*  .github/**  .gitignore  .editorconfig
```

判定は「無害だと分かっているパスの列挙」であって「コードパスの列挙」ではない。
未知のファイルは常にゲート対象に倒れる。新しいトップレベルディレクトリが
黙ってすり抜けることがない側に倒してある。

### 強制

`.claude/hooks/gate-stop.sh` が Claude Code と Codex CLI の Stop フックに
登録されている。ゲートが落ちている間は応答を終えられず、失敗出力が差し戻される。
差し戻しは 1 セッションあたり 3 回まで（`MCA_GATE_MAX_RETRIES`）。使い切った場合は
失敗を明示したうえでターンを終える — 赤いまま進める判断は人間のものだから。

`MCA_GATE=off` は環境側の緊急脱出口であり、ゲートを避けるために使ってはいけない。

## 自動マージと再発防止（Trust）

設計は `docs/trust/auto-approval.md`。基準は「**その判断が覆ったとき致命的か**」。
評価系自身・不可逆な変更（DB スキーマ変更 `CREATE/ALTER/DROP TABLE` 等・破壊的データ削除 `DELETE FROM` / `rm -rf` 等）・秘密/権限/依存・仕様・大きな UI・大規模変更（大規模リファクタリングを含む 10 ファイル以上 または 300 行以上）は必ず人間が承認する。
それ以外（revert 可能かつ局所的）は、証拠（gate 緑・テスト基準引き下げなし・独立レビュー等）がすべて緑なら AI が人間に聞かずにマージする。

1. ゲートを通し、作者とは別コンテキストのレビュアー（サブエージェント）に `trust.mjs diff-id` の値へ
   束縛した review.json を書かせる。チェック項目は `trust.mjs incident checklist`。
2. Pre-Ship の approval 以外のステップを済ませてから、**main 側の**評価器で判定する:
   `node <main>/Scripts/trust/trust.mjs approve --worktree <wt> --review <json>`
   - exit 0 かつ `TRUST AUTO_MERGE` と「Pre-Ship approval を trust として記録した」が出力された場合だけ、
     人間に聞かずに `/create-pr ship-worktree` へ進む。PR 本文に判定結果を載せ、マージ後に報告する。
     exit 0 だけでは判断しない（INC-012）。
   - exit 3（`HUMAN`）: 表示された理由（どの軸で致命的か）を Pre-Ship Panel に添えて人間の承認を待つ。
     回答は `node .claude/scripts/pre-ship-steps.mjs answer --worktree <wt> --step approval --value "<人間の言葉>"` で記録する。
     台帳への取り込み（`trust.mjs reconcile`）は `ship-worktree` が push の前に行う。
     worktree を消した後では回答が残っていないので、手で取り込むときは ship より前に行う。
3. 自動マージした変更に欠陥が見つかったら、`data/trust/incidents.json` に根本原因クラスと
   guard（checklist < test < gate）を登録してから `trust.mjs escape --incident INC-NNN --diff-id <id>`。
   そのカテゴリは凍結され、2 件で自動マージ全体が止まる。再開は人間が `policy.json` の `breaker.since` を進める。
- `data/trust/**`・`Scripts/trust/**`・ゲート・フックの変更は常に人間の承認を通す。
  AI が自分の採点基準を下げられないようにするため。

## 멀티 AI 병렬 개발 (Worktree Isolation)

복수의 AI 에이전트(Claude Code / Codex CLI / Antigravity CLI)가 동시에 작업할 때는 충돌 방지를 위해 반드시 Git Worktree를 사용한다. 보호된 브랜치(`master`, `main`)에 직접 쓰기/커밋 시 가드가 차단한다.

1. **워크트리 생성**:
   ```bash
   make wt.new BR=feature/<작업명>
   ```
   `.worktrees/feature/<작업명>/` 디렉토리가 생성되고 독립된 브랜치에서 격리 실행된다.

2. **워크트리 내 명령 실행**:
   ```bash
   make wt.run CMD="make q.check"
   ```

3. **작업 완료, PR 생성 및 완전 클린업**:
   - `create-pr` 스킬을 사용하여 워크트리 변경사항을 검증 및 커밋 후 PR로 제출한다:
     `/create-pr ship-worktree`
   - PR マージ後は、必ず worktree ディレクトリ、ローカル branch、リモート branch をクリーンアップし、リモート追跡参照のパージ（`git fetch --prune`）と main の fast-forward 同期（`git merge --ff-only`）を完了する（`create-pr` が自動実行）。

## System One eval

triage・routing・offline fallback（`TypeSafeDecisionEngine` / `RequestRoute`）を変えるときは、
`node Scripts/eval/hillclimb.mjs run` で train と heldout の両方が改善することを確かめる。
`Evals/system-one/heldout.jsonl` は開かない。手順は `docs/evals/system-one.md`。

## その他

- 依存の追加は `Package.swift` のレイヤ順（Core → Sensing → Perception → Memory
  → Reasoning → Realtime → Interop → Presentation）を壊さないこと。
- 秘密情報をリポジトリに書かない。`SecretStore` 経由で Keychain に置く。
