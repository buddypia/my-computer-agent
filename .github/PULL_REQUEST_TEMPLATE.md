## Description / 概要

<!-- 
EN: What does this PR change and why? Link to issues where applicable.
JA: このPRが何を変更し、なぜ変更するのかを記載してください（関連Issueがあればリンクしてください）。
-->

Closes #

## Type of Change / 変更の種類

- [ ] Bug fix (バグ修正)
- [ ] New feature (新機能)
- [ ] Breaking change (破壊的変更)
- [ ] Refactoring / Optimization (リファクタリング・最適化)
- [ ] Documentation (ドキュメント更新)

## Architecture & Security / 設計とセキュリティ規約

- [ ] **Layer order preserved** (`Package.swift` layers: Core → Sensing → Perception → Memory → Reasoning → Realtime → Interop → Presentation)
- [ ] **Zero plaintext secrets** (`SecretStore` Enclave seal used; no API keys, credentials, or personal paths in code/tests/docs)
- [ ] **Privacy preserved** (`PrivacyFilter` and explicit sensor opt-in respected; mic remains off at launch)
- [ ] **Tests added or updated** (Unit / contract / integration tests verify the change)

## Quality Gate / 品質ゲート

Before requesting review, ensure all checks pass:

- [ ] `swift build`
- [ ] `swift test`
- [ ] `./Scripts/gate.sh`

## Verification Evidence / 検証結果

<!--
Paste the output of `./Scripts/gate.sh` or include screenshots/screen recordings for UI changes:
`./Scripts/gate.sh` の実行ログ、またはUI変更の場合はスクリーンショットを添付してください:
-->

```
GATE PASS stages G1..G2
```
