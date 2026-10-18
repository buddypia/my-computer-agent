---
name: isolated-timing-tests
description: main thread の遅延・watchdog・共有プールの壁時計・常駐メモリなど、プロセス全体の量に上限を置く Swift テストを書く・直すときの書き方（…Isolated 命名と IsolatedTiming.enabled の三項演算子）。
---

# プロセス全体の量を測るテスト

プロセス全体の量（main thread の遅延・watchdog・共有プールの壁時計・常駐メモリ）は、並列の `swift test` では
隣のテストの負荷まで測ってしまう。

- テスト関数名を `…Isolated` で終える（`Tests/*/IsolatedTiming.swift`）。
- 上限は三項演算子で書く:

  ```swift
  let budget = IsolatedTiming.enabled ? tight : parallelSafe
  #expect(elapsed < budget)
  ```

- `if IsolatedTiming.enabled { #expect(…) }` ブロックにしない。並列実行でアサート自体が消え、`swift-bar-move.mjs` の
  テスト基準引き下げ検知（`\.enabled\s*[({]`）にも引っかかる。

機能のアサートは常に走り、厳しい数値は G2「隔離」
（`MCA_ISOLATED_TIMING=1 swift test --no-parallel --filter 'Isolated\('`）が単独・直列に強制する。
宣言した `…Isolated(` 関数より実行数が少ない、または skip が 1 件でもあれば G2「隔離」は落ちる。
