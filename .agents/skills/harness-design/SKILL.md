---
name: harness-design
description: エージェントへの指示を足す・変えるとき（AGENTS.md、.agents/skills、hook、補助スクリプト、サブエージェント）や、同じツールエラーがセッションをまたいで繰り返すときに、変えるかどうか・どの形で入れるかを決め、結果を経験レジャーに残す規則。Scripts/harness/check.mjs による機械検査の使い方も含む。
---

# ハーネス（エージェント向け指示）の変え方

出典: Google Research の harness2（`harness2/core/prompts.py` の `_SURFACE_CODEX`・`propose`・`experience`、
`harness2/core/tree.py#validate`）。

## 変えるかどうか（KEEP_BASE）

すべての変更は、それを必要にした具体的な瞬間に結びつける: セッション記録の該当箇所、incident（`INC-NNN`）、
PR、ゲートやテストの失敗出力。瞬間を名指しできない変更は推測で、文脈を払って何も買わない。
**変えない（KEEP_BASE）も正当な答え**であり、失敗ではない。

根拠の強さはこの順:

1. **ばらつき** — 同じ種類の作業で、あるセッションはやり、別のセッションはやらなかった。エージェントはもうできるので、
   言えば済む。一番安く効く。
2. **繰り返す具体的な失敗** — 同じエラーや抜けが複数のセッションに出ている。
3. 記録には見えるが、まだ起きていない危険。

すでにうまくいっていることは直さない。ハーネスがすでに明確に言っていることを言い直さない（重複は残りを薄める。
AGENTS.md と skill の同一行は check.mjs が落とす）。

変える前に `data/harness/experience.json` の `lesson.cue` を読み、今の状況に当てはまる教訓があれば従う。

## 常駐テキストは一番高い

`AGENTS.md`（`CLAUDE.md` はその symlink）は毎ターン丸ごと文脈に入り、エージェント自身の出力トークンと取り合う。
増やすほど「考えている途中で予算が尽きて何も出さずに終わる」失敗が起きやすくなる。上限は **8,000 文字**。
足すなら、別の何かを削って払う（`check.mjs --base origin/main` が増減を出す）。

## 足す形の優先順位

1. **Skill**（`.agents/skills/<name>/SKILL.md`）— 認識できるきっかけがある手順。新しい指示の既定の形。
   トリガーは話題ではなく状況で書く（「Swift のテスト」ではなく「壁時計に上限を置くテストを書くとき」）。
   補助スクリプトは `.agents/skills/<name>/scripts/` に同梱する。
2. **Script**（`Scripts/…` / `.claude/scripts/…`）— エージェントが手で組んで間違えた・遅かった決定的な操作。
3. **Subagent**（`.claude/agents/<name>.md`、frontmatter に `name:` と `description:`）— 入力が大きく答えが小さい、
   境界のはっきりした調査。親の会話は見えないので単独で読める指示にする。出力が入力と同じくらい大きいなら割に合わない。
4. **Hook**（`.cli/hooks/*.mjs` を `.claude/settings.json`・`.codex/hooks.json`・`.agents/hooks.json` に登録）—
   ツールループの中で機械的に止める・直後に検証する。プロンプトの注意書きが無視されるなら、文を太らせずにこれで止める。
   よくある形:
   - 既知の悪い呼び出しを、直し方を教える理由付きで拒否する（PreToolUse）
   - 書き込み直後に検証して差し戻す（PostToolUse、例: `harness-lint-guard`）
   - 繰り返すエラーシグネチャの直後にヒントを足す（`error-hint`。`.cli/hooks/error-hints.json` に 1 件足すだけで、
     `evidence` に再発の記録を書く。1 回きりの失敗は入れない）

   重い処理は hook に書かず、hook から呼ぶスクリプトに置く。hook でリポジトリやパスを解決するときは HX-002 の教訓に従う。
5. **AGENTS.md** — 最後の手段。全ターンに当てはまる短い規則だけ。

手順（どう作業するか）と事実を分ける。題材が変わると意味をなさなくなる変更は、その状況の skill に入れる。
検証済みのこのリポジトリの事実は、再発見の手順よりも価値がある。そのときは「この repo では…」と事実として書き、
証拠が確かめたことだけを書く（推測した事実はないより悪い）。

## 検証で落ちる 3 つ

- **トリガー行のない Skill は存在しないのと同じ。** Skill を作ったら同じ変更で AGENTS.md の「スキル」節に
  `- When <条件>, read .agents/skills/<name>/SKILL.md and follow it.` を 1 行入れる。
- SKILL.md の frontmatter に `description:` がないと黙って読み込まれない。`name:` を書くならディレクトリ名と一致させる
  （違うとディレクトリ名を上書きし、トリガー行が当たらなくなる）。
- Skill や AGENTS.md が呼ぶスクリプトは実在させる。

## 経験レジャー（`data/harness/experience.json`）

ハーネスの変更が実際に使われて結果が見えたら（後続の修正 PR、セッション記録、ゲート・テストの出力）、1 entry 足す。

- `edits`: 変えた component ごとに 1 行。`change`（何を変えたか）・`observed`（実行で何が違ったか、どこで見たか）・
  `verdict`（`helped` / `hurt` / `no observed effect` / `confounded`）。
  同じ変更で複数の component を変え、どれの効果か切り分けられないとき、または 1 回の実行しか裏付けがないときは
  `confounded` を選ぶ。でっち上げた帰属は、後でこれを読むすべての作業を誤らせる。
- `lesson`: edits が支えるときだけ最大 1 件、なければ `null`。`cue` は事実ではなく状況の形（別の題材でも発火する）、
  `lesson` は component を名指しした、適用して確かめられる操作。`evidence` は根拠にした行の番号（1 始まり）。
  `helped` か `hurt` の行を含まない教訓は推測なので書かない。広すぎ（「丁寧に」）も狭すぎ（この PR の固有値）も役に立たない。

## 検査

```bash
node Scripts/harness/check.mjs                     # 問題があれば列挙して exit 1
node Scripts/harness/check.mjs --base origin/main  # 常駐文字数の増減も出す
node Scripts/harness/check.mjs --json              # 集計（常駐文字数・skill 数など）
```

上限・トリガー行・frontmatter（skill・subagent）・hooks.json の形・参照スクリプトの実在・AGENTS.md と skill の重複・
error-hints.json・経験レジャーの形を見る。
`Scripts/gate.sh` が docs-only の変更でも走らせ、`harness-lint-guard` hook が該当ファイルの編集直後に走らせて差し戻す。
