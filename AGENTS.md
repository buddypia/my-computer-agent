# AGENTS.md

エージェント（Claude Code / Codex CLI など）がこのリポジトリで作業するときの規約。

## 品質ゲート

コードに触れた作業は、応答を終える前に必ずゲートを通す（Stop フックが G1 まで自動で走らせる）。
G2 のテストは CI に任せる。手元で全段を確かめたいときだけ `Scripts/gate.sh` を実行する。

```bash
Scripts/gate.sh --stage 1   # Stop フックと同じ
Scripts/gate.sh             # G0..G2
```

段階は費用の安い順に並んでおり、失敗した時点で以降は打ち切られる。
コンパイルの通らないツリーにテストを走らせても得られる情報がないため。

| | ステージ | コマンド | 既定 | 実測 |
|---|---|---|---|---|
| G0 | 変更分類 | — | 自動 | 即時 |
| G1 | ビルド | `swift build` | 実行 | ~20s |
| G2 | trust | `node --test Scripts/trust/tests/*.test.mjs` + `trust.mjs incident check` | 実行 | ~1s |
| G2 | テスト | `swift test` | 実行 | ~12s |
| G2 | 隔離 | `MCA_ISOLATED_TIMING=1 swift test --no-parallel --filter 'Isolated\('` | 実行 | ~25s |
| G3 | リリース束 | `Scripts/bundle.sh` | **手動のみ** | 数分 |

G3 が既定に入っていないのは、`build/` を作り直して `codesign` を走らせるためで、
これはエージェントが毎ターン行ってよい副作用ではない。リリース前に人が
`Scripts/gate.sh --stage 3` として明示的に通す。

`node Scripts/harness/check.mjs`（AGENTS.md の上限・skill のトリガー行・hooks.json の形）は
docs-only の変更でも G0 の前に走る。

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
毎ターン払う費用なので、フックは **G1（ビルド）まで**しか走らせない（`MCA_GATE_HOOK_STAGE` で変更可）。
テストは push した HEAD に対して GitHub Actions（`.github/workflows/ci.yml`）が走らせる。
差し戻しは 1 セッションあたり 3 回まで（`MCA_GATE_MAX_RETRIES`）。使い切った場合は
失敗を明示したうえでターンを終える — 赤いまま進める判断は人間のものだから。

`MCA_GATE=off` は環境側の緊急脱出口であり、ゲートを避けるために使ってはいけない。

## 自動マージと再発防止（Trust）

設計は `docs/trust/auto-approval.md`。基準は「**その判断が覆ったとき致命的か**」。
評価系自身・不可逆な変更（DB スキーマ変更 `CREATE/ALTER/DROP TABLE` 等・破壊的データ削除 `DELETE FROM` / `rm -rf` 等）・秘密/権限/依存・仕様・大きな UI・大規模変更（大規模リファクタリングを含む 10 ファイル以上 または 300 行以上）は必ず人間が承認する。
それ以外（revert 可能かつ局所的）は、証拠（gate 緑・テスト基準引き下げなし・独立レビュー等）がすべて緑なら AI が人間に聞かずにマージする。

手順（独立レビュー → `trust.mjs approve --ci` → AUTO_MERGE / HUMAN → escape）は `trust-auto-merge` skill にある。
`exit 0` だけで AUTO_MERGE と判断しない（INC-012）。

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

## スキル

本文は必要になったときだけ読む。skill を足したら、同じ変更でここに 1 行足す（ないと開かれない）。

- When opening a PR, or shipping / cleaning up a worktree, read .agents/skills/create-pr/SKILL.md and follow it.
- When pushing a worktree for merge, deciding AUTO_MERGE vs HUMAN, or a merged change turns out defective, read .agents/skills/trust-auto-merge/SKILL.md and follow it.
- When writing or changing a Swift test that bounds latency, a watchdog, wall-clock or memory, read .agents/skills/isolated-timing-tests/SKILL.md and follow it.
- When a feature needs a typed AI judgment (routing, ranking, extraction, verification) instead of prompt-and-parse, read .agents/skills/typesafe-ai/SKILL.md and follow it.
- When adding or changing agent instructions (AGENTS.md, a skill, a hook, a helper script, a subagent), read .agents/skills/harness-design/SKILL.md and follow it.

## その他

- 依存の追加は `Package.swift` のレイヤ順（Core → Sensing → Perception → Memory
  → Reasoning → Realtime → Interop → Presentation）を壊さないこと。
- 秘密情報をリポジトリに書かない。`SecretStore` 経由で Keychain に置く。
