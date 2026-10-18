---
name: harness-design
description: エージェントへの指示を足す・変えるとき（AGENTS.md、.agents/skills、hook、補助スクリプト、サブエージェント）に、どの形で入れるかを決める規則と、それを機械的に検査する Scripts/harness/check.mjs の使い方。
---

# ハーネス（エージェント向け指示）の変え方

出典: Google Research の harness2（`harness2/core/prompts.py` の `_SURFACE_CODEX`、`harness2/core/tree.py#validate`）。

## 常駐テキストは一番高い

`AGENTS.md`（`CLAUDE.md` はその symlink）は毎ターン丸ごと文脈に入り、エージェント自身の出力トークンと取り合う。
増やすほど「考えている途中で予算が尽きて何も出さずに終わる」失敗が起きやすくなる。上限は **8,000 文字**。
足すなら、別の何かを削って払う。

## 足す形の優先順位

1. **Skill**（`.agents/skills/<name>/SKILL.md`）— 認識できるきっかけがある手順。新しい指示の既定の形。
2. **Script**（`Scripts/…` / `.claude/scripts/…`）— エージェントが手で組んで間違えた・遅かった決定的な操作。
3. **Subagent** — 入力が大きく答えが小さい、境界のはっきりした調査。出力が入力と同じくらい大きいなら割に合わない。
4. **Hook**（`.cli/hooks/*.mjs` を `.claude/settings.json`・`.codex/hooks.json`・`.agents/hooks.json` に登録）—
   ツールループの中で機械的に止める・直後に検証する。プロンプトの注意書きが無視されるなら、文を太らせずにこれで止める。
   よくある形: 既知の悪い呼び出しを、直し方を教える理由付きで拒否する（PreToolUse）／書き込み直後に検証して差し戻す（PostToolUse）。
   重い処理は hook に書かず、hook から呼ぶスクリプトに置く。
5. **AGENTS.md** — 最後の手段。全ターンに当てはまる短い規則だけ。

## 検証で落ちる 3 つ

- **トリガー行のない Skill は存在しないのと同じ。** Skill を作ったら同じ変更で AGENTS.md の「スキル」節に
  `- When <条件>, read .agents/skills/<name>/SKILL.md and follow it.` を 1 行入れる。
- SKILL.md の frontmatter に `description:` がないと黙って読み込まれない。`name:` を書くならディレクトリ名と一致させる
  （違うとディレクトリ名を上書きし、トリガー行が当たらなくなる）。
- Skill や AGENTS.md が呼ぶスクリプトは実在させる。

## 検査

```bash
node Scripts/harness/check.mjs          # 問題があれば列挙して exit 1
node Scripts/harness/check.mjs --json   # 集計（常駐文字数・skill 数など）
```

上限・トリガー行・frontmatter・hooks.json の形・参照スクリプトの実在を見る。
`Scripts/gate.sh` が docs-only の変更でも走らせ、`harness-lint-guard` hook が該当ファイルの編集直後に走らせて差し戻す。
