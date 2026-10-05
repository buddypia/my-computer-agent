# Implementation audit: screen-driven agent


## 2026-10-04 follow-up

`pw-agent` successfully used and closed only an owned X test tab. Two scrolls exposed multiple explicit >5K view counts, but that is manual DOM-visible evidence, not MCA production collector output. An MCA ask did not collect posts; an unscoped capture resolved a different existing Chrome window, so no content from that capture is used. Keychain showed a login-password prompt; no password or Always Allow action was provided. The debug binary was ad-hoc signed, so persistent permission is unverified.

A train-only intent/search fix reached 54/54 train while heldout remained 25/28; the source changes were REVERTed. During diagnosis, a grep accidentally exposed a partial heldout JSONL excerpt to the agent context. The excerpt is not reproduced or used, but blind independence for this session is compromised. Do not claim an uncontaminated blind heldout pass. Current candidate remains No-Go and unmerged; actual meeting material and the native route/accessibility matrix remain incomplete.

旧candidate `feature/screen-agent-integrate`（base `58f66dd`）の当時の状態は後掲の履歴。現行candidateの判定・検証は2026-10-04 checkpointを参照。



Latest gate recheck: two standard `Scripts/gate.sh` runs pass G1 and G2 trust but fail G2 tests with the same two 700ms child-process timeout assertions (first 0.983s/0.947s; second 1.706s/1.699s). The isolated suite passes 4/4 in 0.387s; no root cause is established and thresholds are unchanged. Do not call the current full gate green.


Resolution: dedicated the timeout and delayed SIGKILL callbacks to a concurrent `userInitiated` queue. Focused process tests pass 4/4 in 0.380s; the latest full `Scripts/gate.sh` now passes G1/G2/guards (1272 tests, 2 skips, 0 failures). Earlier full-run timing failures remain recorded; the scheduling-contention explanation is plausible but not proven. No timing threshold or assertion changed.

## 2026-10-04 refreshed-current-main checkpoint

現行 `main` の `5f23e868806c119ba9e4a5cf94d6f36d1625dcbb` を基点とする隔離worktree `feature/screen-agent-refresh` へ候補を載せ替え、main側のkeystroke承認を保ったscoped authorization統合を行った。focused authorization/integration suiteは85tests／8suites PASS。未変更の `Scripts/gate.sh` はG1 build、G2 trust、Swift tests、guardsすべてPASS。xUnitは1270tests、既存skip2、failure/error0、160 suites。fresh gate evidenceはworktree `.tmp/gate/logs/`、summaryは `CONTEXT.json` の `evidence.current_main_refresh`。

必須System One evalはtrain50/54（baseline50/54）、heldout25/28（baseline25/28）、noise0、NO CHANGE／STALLED 3 rounds。4 missesは `r-q-python-file`、`r-q-ko-report`、`r-q-screenshot-howto`、`d-search-for`。heldout data、grader、floor、baselineを変更していない。Chrome attach失敗後の状態変更回答は未取得で再試行なし。実会議資料はユーザーの最後の回答で「まだない」。全7 FRはin_progress／accepted0。現candidateのfresh独立trust review、実機受け入れ、mergeは未完了。この段落をcurrent statusとし、以下の旧checkpointは記録時点のsource/evidenceとして読む。

## Historical checkpoints — source/evidence are bounded to the date recorded

## 2026-10-03 current-main checkpoint

証拠はcurrent worktreeの `.tmp/screen-agent-review/upstream-integration/`、`approval-system-integration/`、`approval-contract-alignment/`、`postcapture-privacy/`。native AX/keyboardはown UI/file経路のrecorded snapshotのみ。actual model/browser/meetingや最新SCK transitionを証明しない。以下は旧checkpointの履歴。旧「最新」「PASS」は記録当時のsourceに限定。

以下はkickoff時点 `e9b9d7f`（2026-10-01）の履歴。現在の判定は [FINAL_REVIEW.md](FINAL_REVIEW.md) とCONTEXT.jsonを参照。

## Reproduced collection defects

The diagnostic compiles the actual `Sources/MCACore/ScreenIntent.swift` with a
temporary main program. It makes no API calls and sends no desktop input.

```sh
swiftc Sources/MCACore/ScreenIntent.swift \
  .tmp/screen-agent-review/probes/main.swift \
  -o .tmp/screen-agent-review/probes/intent-collection-probe
.tmp/screen-agent-review/probes/intent-collection-probe
```

Observed output:

```text
false  Firefoxのx.comでビューが5K以上のデータをスクロールしながら探して
true   Firefox の X でビューが5K以上のTweetをまとめて教えて。スクロールしながら収集して
false  Find posts with at least 5K views while scrolling in Firefox
second viewport after line dedup: ["@author_b", "Second post"]
second post retains observed view count: false
```

The first three lines are direct observations of the production intent function.
The last two reproduce the line-filter algorithm from `Copilot.collectWindowContent`
on a synthetic two-post fixture; they are not a live Firefox run.

1. **Request wording changes the task route.** `ScreenIntent` recognizes summaries,
   lists and questions but does not recognize the user's simple “探して” request.
   `Copilot.ask` uses this boolean to keep collection tasks out of the pure
   actuator loop. The final route also depends on triage confidence/category, so
   this probe proves the missing informational classification, not every runtime
   route for every model response. Future regression tests must exercise the real
   routing boundary with a deterministic triage decision and check final content.
2. **Line deduplication loses per-post evidence.** The collector remembers every
   line globally. A second post with the same `5K views` keeps its author/body
   but loses its view count if other lines are new. Deduplicate complete post
   identities after associating metrics with each post. Retain viewport boundaries
   and raw evidence; missing counts cannot be reconstructed from engagement totals.

## Concrete dispatch seams requiring protection

| Entry point | Current execution path | Required regression boundary |
|---|---|---|
| Chat tools | Agent.answer → ToolRegistry.invoke → tool.invoke | A pending/rejected mutation produces no tool side effect |
| Direct computer tools | ComputerActionTool, ClickElementTool, RunAppleScriptTool and WriteFileTool execute inside invoke | Calling the tool directly cannot bypass authorization |
| TypeSafe single-step | TypeSafeActTool.invoke computes a decision and dispatches it itself | A generated action is checked after grounding, before input |
| Native autonomous loop | TwoTierAutonomousLoopCoordinator calls executeSyntheticAction after deciding | A dangerous step pauses before AX/native dispatch |
| Browser actions | BrowserSession.perform is called by both direct actions and BrowserSession.act | Each concrete action, including a generated second step, is authorized |
| Browser recovery | BrowserSession.act catches any action failure, re-observes, then performs a healed action | Denial/cancellation cannot enter self-heal; changed actions need their own authorization |
| Watch action card | ScreenWatcher.executeAction activates an app and submits text through AppleScript | Generic actionPayload cannot approve a different pending operation |
| MCP built-ins | ContextMCPServer.dispatch instantiates tools and invokes them directly | Built-ins without a presenter return approval_required and zero dispatch |
| MCP extra tools | CallTool handler invokes extraTools directly | Browser/extra tools cannot bypass the same contract |
| CLI autonomous | ActCommand constructs TwoTierAutonomousLoopCoordinator | Noninteractive unsafe step halts before execution |
| CLI single-step | ActCommand directly switches over the grounded decision and synthesizes events | Protect the non-autonomous CLI path as well |

Adding a check only to ToolRegistry would miss several of these paths. The
authorization contract must be shared and enforced where a concrete side effect
is executed. Grounding helpers and planners must not execute while approval is
pending. An approval denial must propagate as a terminal authorization result,
not as a generic recoverable tool/action failure.

## Verification gaps

Existing ScreenIntentTests and CopilotAutonomousIntegrationTests contain prompts
with explicit “まとめて教えて”, “Summarize” or “모아서 알려줘”. They check routing
classification, not post/view association or final search results. Searching
current tests for approval and view-count identifiers did not locate a typed
approval lifecycle or qualifying-post extraction test; this is supplementary
source evidence, not proof of complete test coverage.

Required additions after approval:

- Test the exact Japanese “探して” and English “Find posts … while scrolling”
  requests through the app task route, plus pure click/type requests and explicit
  `/act` controls, so collection changes do not reroute unrelated actions.
- Feed two distinct posts with the same count on successive viewports; preserve
  both counts. Repeated post identities yield one result; distinct same-text posts
  remain distinct. Include 4.9K, 5K, 5,000, 12K and 1.2万 boundary cases.
- Assert zero dispatch for denial, cancellation, expiration and stale approval
  through direct tools, registry, loop, watch, browser second-step/recovery, MCP
  built-ins/extraTools and both CLI paths. Use recorded actuators and disposable files.
- Verify task-target identity survives chat focus, model waits and approval UI.
  Do not replace a missing pinned target with the current foreground application.
- Verify useful meeting artifacts and search answers, then exercise actual pinned
  Firefox scrolling and meeting shared-content actions. Offline probes do not
  establish live OCR, permissions, model behavior or actual GUI control.

The original goal and all FR-CU-001 through FR-CU-007 remain required. These
findings refine implementation and regression coverage without changing the UI
proposal or treating a diagnostic as finished software.

## Approved implementation checkpoint — 2026-10-01

User verdict: **承認**。SPEC/UI approvalを実装開始に反映。全FRの受け入れ完了とは扱わない。

| 境界 | 現在の実装 | 確認 / 残る作業 |
|---|---|---|
| task scope | Window ID/PID/bundleをTaskLocal authorizationに保持、driver scope、capture実PID照合 | native focus/target喪失・複数windowの実機検証が必要 |
| chat approval | immutable operation/card、single pending waiter、approve/reject/cancel/expire、message削除時cancel | lifecycle fixtures成功。実描画/keyboard/VoiceOver未確認 |
| tool/CLI/MCP/loop | concrete mutation sinkでapproval必須。CLI/MCPにpresenterがなければ拒否。denialはfallback禁止 | direct MCPとtool/browser fixtures成功。native loop/CLI/watch全route matrixは未完 |
| watch objective | pinned targetにstanding objective、observation fingerprint claim、同じaskへ接続 | claim・queued action Stop成功。Zoom/Meet→artifactの実確認は未完 |
| native input | approval前coordinate固定、observed一意candidate、snapshot revalidation、選択window内/foreground/field確認 | 実AX/CG dispatchは未検証。背景scrollの検証はforegroundと分離 |
| file writes | 新規/既存caller指定pathはapproval、parent FD/device/inode固定、realpath/祖先照合、openat、NOFOLLOW/EXCL、内容照合 | stale bytes/parent、hardlink/FIFO、新規unapproved zero-write fixtures成功 |
| browser | active page/tab/ref snapshot再検証、navigation/evaluate/newtab/close承認、scope違い拒否 | fake driver成功。focus不明のpress拒否。live Firefox未確認 |
| subprocess | invocation group、TERM→KILL、unreaped leaderでgroup identity保持、bounded nonblocking drain | TERM-resistant childのRED→GREEN。owned group外の外部効果はrollback保証なし |
| collection | viewport全体保存、scroll failure/unchanged/budget/time/cancelの理由、post/labelled metric対応、重複をpost単位で抑制 | 4.9K/5K等と同値別投稿fixtures成功。Xのicon-only countsを推測しない |
| results/deadline | 完了未確認のfallbackを修正、20 actions/15 rounds/120秒active budget、approval待ちは除外、late answer ID拒否 | fixture成功。最終モデルanswer/会議artifactとdeadline実機確認は未完 |
| privacy | 既存exclusion/secure candidate filter、新objective/selected OCR/collector textに既存redaction | PrivacyFilter tests成功。画素中すべてのPII redactionを証明していない |

検証結果: 関連**121 tests / 25 suites PASS**。`git diff --check`成功。
未変更gateはbuildとtrust tests成功後、full Swift testsが終了しないため未通過。
単独の既存SecretStore testsは**9 failures / Keychain -50**。full-suite hangの原因は未特定。
テストをskipせず、assertion・gate・trust基準を下げていない。SwiftPM用worktree cache設定と診断backtrace抑制を使用。

CLI native preflightはAX=false / ScreenCapture=false、対象app取得なし。インストール済みappの権限・modelアクセス可否は未確認。
先行pw-agent attach失敗後はretryせず、ユーザーの既存tabへの操作も行っていない。

独立source reviewers 2名の具体的HIGH指摘を修正後再確認。追加のregistry停止条件と履歴/tool/metadata redactionも独立source reviewerが再確認しPASS。
trust diff-bound review、human Pre-Ship approval、commit/PR/merge/cleanupは未実施。
実装は既存worktreeに保持し、CONTEXTでは**0 accepted / 7 in_progress**。

制限: browser press拒否、任意新規text fileも承認必須、保存先parentは既存である必要がある。
advisory file lockは非協調editorとの完全CASを保証しない。
詳細・残るacceptance手順・review verdictは[FINAL_REVIEW.md](FINAL_REVIEW.md)参照。

## 続行による追加修正

Registryのcancel/terminalFailure確認をdispatch直前に追加。実HUD承認→file artifact、次の承認の独立性、取消時zero-write、非simulation coordinatorの承認なしzero-dispatchを検証。
watchで保存するbody/title、既存履歴の整形、現在画面toolのlegacy/live結果、Copilot由来の送信用metadataを既存PrivacyFilterでredact。identity照合用の原文は保持。final model transcriptの2round目まで確認したfixtureはRED→GREEN。画像のredactionは未検証。
関連102 tests PASS。最終gateはG1/G2 trust PASS、全Swift test未完了（60秒でowned groupを停止）。native依存の16 issuesはmainの既存bundleでも同じfilterで再現。全FRの受け入れ、ship判定は未完了のまま。

## 選択window観測と承認後focusの修正

Inspector factoryへpinを渡し、CG WindowID/PIDとCG/AX双方の一意なtitle/frameから選択windowだけを観測する。OCR fallbackも同じwindowのcaptureを使う。初回snapshotはauthorization TaskLocal内で取得する。無効pinが別app snapshotへfallbackしたREDを再現して修正。
Desktop承認後は選択AX windowへfocusを戻す。座標操作の承認再検証はwindow/candidatesを固定してfocus復帰だけ許容し、keyboard/未知の操作はfocused ID/role/boundsまで維持する。不整合を10 coordinate casesのREDで確認後修正。最新の独立source reviewはPASS。
最新関連121 tests / 25 suites PASS（0.381秒）。最新gateはbuild 15秒・trust 4秒PASS、全Swift testsは完了せず60秒でowned groupを停止。実機focus・入力の成功は未検証。0 accepted / 7 in_progress、出荷No-Goを維持する。

## Actual Copilot native / offline fallback checkpoint — 2026-10-02

実Copilotの通常chat依頼→configured real model tool call→production ClickElementTool→実ChatWindowのnative mouse承認→別processのowned selected windowで3cases PASS。最終run `87635f5c-1ca9-445d-9702-0fb164a84339` は診断wrapperなしの元registryを使用。Approveだけcount0→1、Reject/Stopはcount/fields非変更、別window非変更、回答は物理count1と一致。GoalへexpectedCountを渡しているため、model自身の再観測はこのfixtureでは未立証。Pinをstart前に設定しambient captureを抑制。Approvalのeffective coordinateが観測button内であること、run UUID/PID/executable/window ID、9source hashes、両process正常exitを検査。証拠 `.tmp/screen-agent-review/copilot-native-answer/result.json`、PNG、`final-source.json`。

先行runの失敗も保持。Stop OCRはgoal本文中の「Stop」にもmatchしたため、fixtureはbuttonのstandalone textだけを一意matchするよう修正（同2s deadlineとpostconditions維持）。別runでは承認後count0、さらに別runではcount0のまま追加AppleScript提案となり、未承認のため実行せず終了した。単一原因は未確定。実ClickElementToolへdelegateする診断wrapperのrunはPASSしたが原因の証明とは扱わず、最終runでは登録を無効化した。失敗証拠 `first-result.json`、`second-approve-nondispatch-result.json`、`additional-operation-result.json`。

`/act`診断はoffline fallbackで「Do not type」をtypeへ、window titleを操作候補へ誤選択した。今回、unavailable evaluatorかつnonempty candidatesのfallbackは検出した一般的EN/JA/KO禁止形でnone/conf0/notcompletedを返しSystem2へ渡す。Scoring/typing両selectorはisActionable必須。公開decideNextAction境界のRED→GREEN4tests/12cases（禁止9形・button/window競合・read-only target/input）を確認。全NLP表現は未網羅、禁止markerを含むlabelは保守的escalation。既存empty-candidates+2低confidence circuit breakerのcompleted挙動はこの保証に含めない。実`/act`全goalの受け入れは未完了。

未変更gate1065 tests/109 suites/1.581s PASS、`.tmp/screen-agent-review/gate-copilot-complete-regressions.log` と `-evidence/`。初回全gateのcancellation timingのみ676ms対400msで失敗、同コード単独1test56msと全gate再実行PASS。基準・skip・parallelism変更なし、timing原因は未断定。全FR in_progress、No-Go、real Chrome/X/meeting、全route/races/VoiceOver/Tab/deadlinesとcommit-bound trustは残る。

## Actual Copilot postclick reobservation checkpoint — 2026-10-02

新しいowned-window fixtureではgoalからexpectedCountを外し、native button callback時にだけランダム8桁receiptを生成する。Actual Copilot／configured real model／production authorization・presenter／実ChatWindow mouseを使用。診断wrapperは元tool definitionとargumentsを保ち、実ClickElementTool・InspectUIElementsToolへ委譲し、結果・例外をそのまま返す。run `e2d6999f-5f64-4aa3-a708-e1f27bbf03b2` でclick resultの後にproduction inspect結果がcount1と新receipt `14611157` を返し、modelの最終回答が両値と一致した。Receiptはpromptへ渡していない。Approveだけselected count0→1、別windowとfieldsは非変更。Reject/Stopは追加変更なし、exact card UUID/statusと同2s mouse解決条件を確認。両owned processesはexit0。

証拠 `.tmp/screen-agent-review/copilot-reobserve/result.json`、`tool-trace.json`、PNG。`post-run-source.json` は事後source fingerprintで、前fixtureのproduction9hashと一致するがpre-run binary provenanceではない。これは診断wrapperを用いた1runであり、元registryのみの再観測・全activation/race・real Chrome/X/meeting/watch・全route/accessibility/deadlinesの受け入れではない。Inspectにはclick coordinateがないため、traceのhit_owner=otherは対象誤認の観測を意味しない。先行click非成立は今回は再現せず、原因未確定のまま保持。全7FR in_progress、出荷No-Goを維持する。

標準 `Scripts/gate.sh` はG1 build13s／G2 trust4s／Swift1065 tests・109 suites・1.667s／guards PASS。証拠 `.tmp/screen-agent-review/gate-copilot-reobserve.log` と `-evidence/`。独立レビューで診断runnerのfailed-result／timeoutがexit0になり得る問題を検出し、passed=true・stage=complete必須とtimeout再throwへ修正。元runnerをmock subprocess・隔離filesで評価し、false-result／timeoutは失敗、true-completeは成功、全3casesでcleanup保持を確認（`runner-boundary-check.json`）。修正後のnative再実行はしていない。記録済み実runのpassed=trueは独立確認済み。

`final_independent_c` の限定source/evidence reviewはPASS、runner修正後に残るHIGH/MEDIUMなし。記録 `.tmp/screen-agent-review/copilot-reobserve/independent-review.md`。独立reviewは実機再実行・全機能受け入れ・commit-bound trust承認を代替しない。

記録更新後の全gateで既存取消timingが420.150ms／400ms上限となり1issue。失敗 `.tmp/screen-agent-review/gate-copilot-reobserve-final-status-sync.log` と `gate-copilot-reobserve-status-failure-evidence/` を保存。同コード・同assertionの対象1testは58ms PASS（`cancellation-timing-reobserve-isolated.log`）。Timingの単一原因は未特定、基準・skip・parallelismは未変更。

## Offline completion evidence / actual /act checkpoint — 2026-10-02

Unavailable evaluatorのpublic decideNextActionでは、goal中のDone／完了等や未一致・空候補での低confidence2回からcompleted=trueになり、実coordinatorも未操作のDoneを成功扱いした。さらにdefault heuristic plannerは再試行枯渇・inert/boundaryだけでcompleteGoalを返した。今回はgoal語による完了を削除し、未解決の3decision branchesはnone/conf0/notcompleted、3planner branchesは未検証outcomeのabortへ変更。既存の早期retry、structured model completion、観測したscroll停滞のdecision branchは維持。

Public regressionはdecision/coordinator RED35issues、public planner4casesと上限5の実default coordinator RED5issues→GREEN。新7tests／17case executionsのRED時bytesは変更せずSHAで照合（installed lock CLIはSwiftを認識せず、強制lock成功とは扱わない）。既存の未観測success期待はtyped failure／nil dispatch／unverified理由を必須へ更新し、action履歴・scroll1／PageDown1・escalation数を保持。Positive E2Eはgoal語doneによるゼロ操作successから、simulated scroll1→実UIStateDiffの期待title変更→success／totalsteps1の確認へ改善。試験skip・削除・閾値・parallelism・gate／trust policy変更なし。関連341tests／15suites PASS、標準全gate1072tests／111suites／1.685s PASS。先行全gateの旧成功期待22issuesは保存。独立source/evidence review PASS、残る新HIGH/MEDIUMなし。

証拠 `.tmp/screen-agent-review/offline-completion-{red,all-loop-final}.log`、`offline-planner-completion-red.log`、`offline-completion-independent-review.md`、`offline-completion-final-source.json`、`gate-offline-completion-final.log` と `-evidence/`。Model-completion controlはmock probabilityによる回帰で、real modelのlive outcome verificationではない。以前のnative PASSは旧source snapshotの証拠として保持し、今回の最新source全native受け入れとは扱わない。

実Copilot `/act` の初回run `1d01a323-ef49-4863-aebd-737bf70cd853` は240s timeout、terminal resultなし（`copilot-act-final/first-startup-timeout/`）。Owned startupに境界記録だけを加えた2回目 `c656b23f-55d7-4d0f-a55a-7b1ce229609b` はstartup完了、正しいowned button elem2と内側coordinateへのDesktop click承認を要求したが、承認後にproduction EventSynthesizerがInput target changedで拒否しcount0／fields・receipt非変更。両owned process exit0、hardened runnerはpassed=falseを拒否してfailure終了。`result.json`／`startup-trace.json`／`last-run.json`はこのfresh2回目で相関。Decision fix後・planner拡大fix前の中間source runであり、未確定のforeground／focused-window／occlusionのどのguardかを次に診断する。初回startup timeoutの原因も未特定。両runは受け入れPASSではない。

全7FRはin_progress、No-Go。実Chrome/X・Zoom/Meet artifact、全route/races／VoiceOver/Tab／end-to-end deadlines・commit-bound trustが残る。No commit／PR／merge。

## Chatの入力遮蔽と確認指示 — 2026-10-02

実 `/act` のown-target監視で、foregroundとfocused AX identityが正しく戻ってもChatのQuartz surfaceがクリック位置に残っていた。公開ChatWindowの分離再現でもAppKit非表示後に約177ms残存し、実presenterの150ms yield条件で回帰RED。ChatのanimationBehaviorを.noneにし、同じ回帰GREEN。同期即時除去という最初のtest条件はQuartzの非同期反映に合わず、150ms条件へ訂正後に元sourceでREDを再確認した。150msは最低待機で、厳密なdeadlineではない。既存input guardsは維持。

クリック後のVerify指示がnumeric fragmentで無関係なfieldへclickを提案する別障害も公開decideNextActionでRED。限定EN/JA/KO観測指示はnone/confidence0/notCompletedでSystem2へ渡す。既存helperでreplan wrapperを除去し、観測するscroll名称と明示scroll動詞を区別。新回帰はChat1、直接観測2／7cases、replan2／4cases、navigation名称1／2cases。Corrected RED後の4fingerprints不変、関連347tests／19suites PASS。Swift lock非対応を明記し、強制lockを主張しない。独立reviewの2MEDIUMを回帰付きで解消、最終source review PASS。言語全網羅は未証明。

最新source hashと一致するactual Copilot `/act` run `b6ded815-a22b-40db-8bb3-5475b310f4a5` でnative mouse Approveはphysical count0→1／receipt32c7d44a、modelが観測確認して追加入力なく終了。Rejectは全count／fields不変。そのrun全体はStopの診断OCRが本文もmatchして一意特定できずFAILのまま保持。別fresh run `61539300-524e-468f-92ee-eb1feabd4ea9` はstandaloneのown Chat toolbar StopだけをOCR選択し、native mouse→cancelled／Task stopped、count0／fields不変、matchedUUID＋terminal complete＋passedtrue、runner exit0。直接approval resolveは使わず、両runのown processesはexit0。Read-only監視はtimingへ影響し、全focus raceの保証ではない。

証拠は `.tmp/screen-agent-review/chat-close-evidence/` の各RED／GREEN・fingerprints・independent-review、`copilot-act-final-guarded/` と `copilot-act-stop-current/` のresult／pre-run-source／PNG。旧失敗・中間sourceの成功を保存し、最終sourceの証拠と区別。最新標準gateは1078tests／115suites PASS、`gate-chat-observation-final.log` と `-evidence/`。G3は未依頼。全7FR in_progress、No-Go。実Chrome/X・会議artifact・全route/races・VoiceOver/Tab・full deadlinesとcommit-bound trustは未完了。

## Standing objectiveの実機診断 — 2026-10-02

最新production sourceを変更せず、own別AppKit windowに資料とランダムreferenceを描画し、実ScreenWatcher／Copilot／configured model／native承認／notes保存の経路を試した。run `334cdd25-3896-4b57-9cfd-d9a2b6de8a3c` は起動待ちで420s timeout、terminal resultなし、FAIL。own PID/executable/UUIDを検証した1s sampleは884/884 main-thread stacksがSecretStore→SecItemCopyMatching→Security decrypt/mach_msgで待機していた。現在の待機境界は確認したが、全420sの状態・dialog表示・アクセス待ちの原因・過去timeoutの原因は未証明。Keychain値・設定・permissionsは変更せず、macOSのdialog有無を問い合わせ中。両own processesは終了済み。

独立fixture reviewのMEDIUM（revisionBの承認を古いAと区別できない）を、別draftにB ACK/fresh reference/新UUID/承認本文reference/alternate canary拒否で補強。元の失敗証拠を保持し、draftのsource review PASSは実行成功とは扱わない。`copilot-standing-observation-reviewed/` は未実行。

別のcapture-only診断run `003ac5f3-dcfa-4744-9181-e49707a60367` はreal SCK/OCRでselected materialのproject／decision／owner／action／referenceを4capturesで認識し、alternate内容を含まず、runner0／owncleanup0。Foreground／background／refocusのOCRとreferenceE0BD5BFFは同一だが、window chromeの変化でimage fingerprintとclaim結果が変わる（true／true／false）。実revisionBのreferenceEED0607Aは新たに認識。これは画像・OCR・fingerprint診断の完了であり、modelの重複操作抑止／notes生成のPASSではない。先行capture-only run `69e7b6dd-fa86-4a78-9642-00e48a8f389a` のOCR必須assertion失敗も保持し、原因を推測しない。

証拠は `.tmp/screen-agent-review/copilot-standing-observation/` のruntime／startup trace／sample／reviewと、`standing-material-observation-probe/` のresult／diagnostic JSON／PNG／source hashes。4capturesの226–398msはcapture／OCR／hash／diagnostic PNG保存を含む全体の限定計測。会議・browser・full performanceの受け入れには使わない。全7FR in_progress／受け入れ0／No-Goを維持し、Chromeの一度の再接続例外も回答待ち。

## 追加keyboard診断 — 2026-10-02

production変更なし。own-window key dispatch前のactivation検査を加えたignored fixtureで現在sourceのEN／JA／KO18cases PASS。Tab／Shift-Tabはtext-field focusを観測したが、承認ボタンへの移動／VoiceOverは未検証。先行Reject失敗と原因の不確実性はLIVE_VERIFICATION.mdに保存。全7FR in_progress／accepted0／No-Go。

Latest checkpoint: fixed-certificate own validation app reused without rebuild; observed notes saved, then full runtime FAIL at unchanged-material dedup. Chrome own-tab2scroll/3explicit>=5K DOM evidence verified and tab closed. Keychain one-time outcome unproved; production unchanged, all7FR in_progress/accepted0/No-Go. Details in LIVE_VERIFICATION.md.

## Window focus装飾による重複開始の修正 — 2026-10-02

同じowned資料のactive/background実SCK画像とAX metadataを照合。標準Close/Minimize/Zoom buttonとtitle glyphだけが変わり、raw fingerprintが別値となる公開回帰は1issueのvalid RED。AXで正確に識別した4領域のみをdownscale前に正規化し、本文／図／タブ／toolbar／OCR／modelへ渡す画像は変更しない。実titleの文字列はfingerprintに残す。選択CG ID/PID/title/frameとAX一意windowをcapture時の情報に結び、取得できない／無効／staleなmetadataはraw判定へ戻す。既存image hashのlossy quantization精度以上の全変更検出は保証しない。

独立reviewのMEDIUM: AX timeoutは子window/button/titleへ継承されずMainActorを待たせる。Public lookupに対するown slow-window-title fixtureは2.072626sでvalid RED。全returned objectにlocal50ms timeout、500msのcooperative budgetと取消を検査し、utility detached workerから読み取る。Global timeout／権限／入力guardを変更せず、同じfixtureで0.153053s／empty mask／probe0のGREEN。500msは厳密なhard deadlineではなく複数IPCとOS schedulingによる超過があり得る。Synthetic imageでのmetadata性能境界で、capture/modelの受け入れ証拠ではない。最初の5s起動preflight失敗は保存し、30sへ調整後のvalid REDでsourceを固定した。Slow runnerはprobe失敗をraiseしないため、result/probe exitを判定根拠にする。

回帰test＋実画像2枚、slow fixture3sourcesはvalid RED後のhash不変。Focus不変・文字なしの図の変更検出・invalid rect raw fallbackと関連取消を含む13tests／5suites PASS。独立source/evidence reviewは指摘resolved、限定PASS。

最終source run `fe8a5e52-d469-4363-bb95-b0f5c968c033` はactual watcher/SCK/OCR/configured model/native mouse approval→owned notesのexact approved bytesと観測referenceC559EBDDを確認。未承認時はbaseline非変更、48s unchanged資料ではuser turn1のまま、revisionBはfresh referenceと別approval UUIDを要求、native Stopで取消し、revisionCでも48s再開／late書込なし。Terminal complete/passedtrue、strict runner0、両own helper0、ps不在、最終sourceとrecorded linked inputs一致。前timeout-hardening source run850782...の成功と元duplicate失敗は別保存。同じ証明書／bundle identifierのDRはbinary再build前後で不変。Keychain「常に許可」の選択／今後のdialog再発は未確認。

証拠 `.tmp/screen-agent-review/objective-decoration-regression/` のred/green logs、regression fingerprints、slow RED/GREEN、independent-review、native-final-evidence／native-final-provenance。Test画像はown人工資料のみ。Package.swiftにはtest resource指定のみ追加、依存追加／レイヤ変更なし。Latest full gateは1081tests／116suites中ActionApprovalTests.swift66が100ms expiryをcancelledとして期待して1issue。失敗bundleを保存、条件を変えず単独6tests／2suites PASS（.056s）。全suiteと単独の差は観測したが、正確なscheduler根本原因は未断定。Checkpoint gateもFAIL：1081tests／116suites、expired／cancelled不一致と取消441.308ms（400ms未満条件）の2issues。両failure bundleを保存。

Actual Google Meet tab metadataはhomeページだけで共有資料の証拠ではない。ユーザーに共有資料window titleを問い合わせ中。全7FR in_progress／accepted0／No-Go。実Zoom/Meet artifact、production Chrome/X collector/model回答、full routes/races/accessibility/deadlinesとcommit-bound trustは残る。G3／commit／PR／push／mergeなし。

Final native/source/evidence独立reviewは限定PASS。旧c162FAILのparent metadataはold-run名へ分類しbytesを保持（LOW resolved）。全体受け入れと出荷判定を変更しない。

## 最終checkpoint — 2026-10-02

未変更のScripts/gate.sh最終実行はG1 build／G2 trust／Swift1081tests・116suites／guardsすべてPASS。証拠gate-objective-decoration-terminal.logと同名-evidence。先行full gateの1issue／2issuesと単独6tests PASSは保持し、最終greenからscheduler根因解明／deadline保証とは結論しない。最終production4hashes／両immutable regressionhashesはnative/source reviewと一致。

会議共有資料はユーザーが「まだない」と回答。Meeting acceptance保留。Chromeの製品collector/model検証の準備で、同一session scrc1002-root-xのpw-agent open-testがattach失敗（Error: attach failed. A hung tab may be blocking CDP; report it to the user.）。AGENTS.mdに従い再試行せず、同じsessionでclose-testを実行。既存tabのnavigation/reload/close／browser起動／外部process停止は行っていない。copilot-chrome-collection/open-test.txt／close-test.txtに記録し、product collector/modelは起動していない。前のchrome-live-scroll2scroll／3explicit>=5K DOM evidenceは歴史的限定証拠として保持。

Keychain用controllerは同じ証明書／bundle identifier／DRを維持し、最終native成功を確認したが、OS「常に許可」の選択と以後の確認dialog回数は未確認。All7FR in_progress／accepted0／No-Go、G3／commit／PR／push／mergeなし。次はChrome接続条件の変化とactual会議資料の表示を受けて実機を再開し、残るfull matrixとshipping trustを検証する。

## 外部Accessibility clientによる承認カード確認 — 2026-10-03

Production sourceは変更せず、専用AppKit process3703の実ChatViewを別process3706のAXUIElement clientから検証。run `0ed225ba-400b-49b8-84fa-4ab39930b394`、EN／JA／KOの各Approve／Reject／Stop、9個の一意operation UUID、27応答でPASS。CG window ID／PIDと一意AX titleを固定し、user windowを操作しない。公開AXButtonのlabel／role／enabledからcontrolを識別し、ApproveのAXPressで表示された操作のbytesを保存、Reject／Stopではbytes非変更。解決後にApprove／RejectのAX controlsは存在しない。保持した古いAX参照へのpressはinvalidUIElement（-25202）で、次cardはpendingのまま、Stop後もfile非変更。成功した古いpressをauthorization guardが拒否した証拠とは扱わない。

最初のinternal NSAccessibilityProtocol経路はNSHostingView AXGroupだけでbuttons0となり2run FAILを保持。既存native-keyboardの空buttons配列もAX label証拠として扱わない。外部clientでlabelsを確認した今回runとは区別する。VoiceOver読み上げ、Tab移動、AXPosition／AXSize／pixel geometry、model／meeting／browserの受け入れは含まない。297個のsource／object／fixture hashes不変、両helper exit0／ps不在。Keychain／global preferences／既存Chrome tabsへ操作なし。

証拠は `.tmp/screen-agent-review/native-accessibility/` のexternal-run.log、UUID下terminal／response／pre-run-sourceと独立review。標準gate初回はChatWindowDismissalTests.swift31の150ms後Quartz残存で1081tests／116suites中1issue FAIL。変更なしの単独1test／.612s PASS、標準2回目はbuild／trust／test／guards PASS。初回full logsも保存し、passing retryからdeadline保証を主張しない。会議資料はユーザー「まだない」、Chrome新attach失敗後は再試行なし／状態変更の回答待ち。All7FR in_progress、No-Go、G3／commit／PR／mergeなし。

## 承認カードのgeometryと外部AX focus診断 — 2026-10-03

Production source変更なし。別fixture `.tmp/screen-agent-review/native-accessibility-geometry-tab/`、run `6cf79479-bbd3-41de-88d2-28a5541ad54d` のown host8997／probe8998／window11255でEN／JA／KOを検証。AXPosition／AXSizeはfinite・positiveで3controlsがown AX window内、Approve／Rejectは非重複。own-window600×732のPNG3枚も視認して表示を確認。物理clickのhit-test、全window size、AXとpixel座標の厳密対応を受け入れた証拠ではない。

各localeのTab12回／Option-Tab12回／Shift-Option-Tab4回はown NSWindow.sendEventに限定。84eventsと外部AX focus87観測は全てAXTextFieldのみ、full keyboard access=false。承認pendingと元file bytes非変更はPASSだが、ボタンtraversalは未確認。設定falseだけを単一原因とは断定しない。global preferences変更／forced focus／global event／VoiceOver起動なし。

114responses PASS、9個の一意operation UUID、現controlsのAXPress9回success0、Approve exact bytes／Reject・Stop非変更。古いAX参照12回はinvalidUIElement（-25202）で、guardへ成功pressが到達した証拠ではない。297source／test／object／fixture hashes不変、両helper exit0／ps不在。最終標準gate exit0、1081tests／116suites／2.412s PASS、証拠gate.log／gate-evidence。過去のinternal tree FAILとQuartz150ms FAILは保持し、原因未確定。独立review記録は同directory。全7FR in_progress／accepted0／No-Go、Chromeは接続状態変更の回答待ち、会議資料は「まだない」、Keychain AlwaysAllowは未確認。G3／commit／PR／mergeなし。


## MCP公開dispatchの承認・停止検証 — 2026-10-03

変更は `Tests/MCAInteropTests/ContextMCPServerAutonomousActTests.swift` のみ。無presenterのnonsimulation経路は実public dispatch→production coordinator／decision engineを通り、1evaluation後にapproval_required、input call0／完了0。Initial snapshotを保持し、実server.stopとcaller Task.cancel後にlate observationを返す。両caseでJSON cancelled／success=false／steps0／completion0／evaluation0／input0。Safe recording actuatorとdeterministic planner／evaluator／snapshotを使用し、native OS input、configured model、stdio transportの受け入れ証拠とは扱わない。

旧キャンセルtestの実行前cancelと非empty結果を、実dispatch中の取消assertionsへ強化。独立reviewが検出した無期限start waitは、ContinuousClock5s start／output期限、success/error記録、失敗時task.cancel＋snapshot releaseで解消。公開MCP空goal validationの観測前終了はtyped failureになり、release-before-captureも後続waiterを残さない。5sはfixture期限で製品latency保証ではない。関連27tests／5suites／.385s PASS、独立source再reviewは限定PASS。Production109 source hashes不変。

標準gate1回目1082／116／7.127sで5issues、2回目1083／116／5.647sで4issues、3回目1083／116／7.056sで4issues FAIL。最新はUIStateDiff5000 64.817ms>=50ms、TERM resistant child .703161083s>=.7s、Cancellation1008.216ms>=400ms、ActionApprovalTests66 expired!=cancelled。G1とtrustはPASS、G2 guards未実行。3回分raw logsを別bundleで保存、新MCPcaseはfull suiteでもPASS。高host loadは観測したが根因・唯一原因・既存不具合の証明とはしない。閾値／assertion／skip／parallelism／gate不変、再試行上限に達したため追加実行なし。

証拠 `.tmp/screen-agent-review/mcp-live-dispatch/` のcheckpoint.json、focused-test.log、targeted-after-review.log、independent-review.md、gate-first-failure-evidence／gate-second-failure-evidence／gate-third-failure-evidence。Chromeはattach条件変更の回答待ちで再接続なし。会議資料はユーザー「まだない」、Keychain AlwaysAllowも未確認。全7FR in_progress／accepted0／No-Go、commit／PR／push／merge／G3なし。


## 承認期限の同期検証 — 2026-10-03

HUDStateの期限切れは以前timer taskだけが解決しており、MainActorの遅延中にlate Approveが通った。登録時にContinuousClockの絶対期限を記録し、timerも同じ期限まで待つ。resolve時に期限以後のapprovedをexpiredに変換し、waiter／deadline／timerを一回だけ除去する。拒否・取消はdenialのまま。期限はMainActorがrequestを登録した時点からで、登録前queue待ちを含む保証ではない。

公開回帰REDでpending assertion成立後に30ms actor占有、timeout10ms後のapproved結果を3issuesで確認。未変更test hashで関連10tests PASS、最終sourceの標準gate1084／117 PASS、独立review限定PASS。Swift lock CLIはpattern非対応なので機械lockは主張しない。setupのTask.yield中にtimerが先行するとpending assertionが落ちるLOWは残り、setup全体の決定性を主張しない。先行gateのexpired/cancelledを直した証拠ではない。

証拠は `.tmp/screen-agent-review/approval-deadline/` のred／green.log、gate.log、gate-evidence、source-hashes、checkpoint.json、root-cause.md、independent-review.md。今回変更前のnative／Keychain証拠は旧source snapshotとして保持。閾値／assertion／skip／parallelism／gate／policy変更なし。G3／commit／PR／push／mergeなし。Chrome状態変化、actual会議資料、Keychain常に許可の回答待ちを維持。


## 承認テストのsetup競合と最新AX検証 — 2026-10-03

現在の判定は **No-Go**。全7 FRはin_progress、受け入れ完了0件。承認テストのsetup中に実timerが先行する競合を専用probeで再現し、internal-only sleeperで期限切れ通知を制御。10ms／100ms期限と六methodのexact denial assertionsを維持し、実timerの5ms expiry-before-cancel回帰を追加。Guard除去RED6issues／2cases、関連11tests／3suites PASS、最新標準gate1085tests／117suites／2.384s G1／G2 PASS。独立reviewで先行2LOW解消。初回gateのexpired/cancelled1issueは保存し、exact iteration／schedulerと他の時間制限失敗の根因は未確定。最新default-HUD実描画はEN／JA／KOのexternal AX9操作／27応答／298hashes一致でPASS、own2helpers exit0／不在。Chrome製品経路・実会議・Keychain・VoiceOver／Tab・全route／race／deadlineは未完了。

内部timer待機だけをfixtureで保留し、承認の絶対期限とpublic resolverは実時計のまま。Default public initは従来のContinuousClock.sleep(until:)を使う。Deadline回帰は通常setupと30ms遅延setupの2cases、取消回帰は各method専用streamで100ms expiry deliveryを保留し、cancel前に150msの遅延を加えて検証する。旧実timer5ms expiry試験は維持し、expiry後のcancel／Approveがdenialを上書きしない試験を追加。旧test bytesと過去RED／GREENは別保存し、新期限回帰もguard除去RED後のhashを保持。Swift lock pattern非対応のため機械lockは主張しない。Probe runner再実行時の旧test上書きもone-shot制約で解消。

Fresh native run `ef78fa88-cc6c-47bd-a8bc-94395f93629c` のhost70430／probe70432／window12750のみを操作。承認だけがguarded fileを更新し、拒否／停止は非変更。9個のoperation UUID、27応答、298個のsource／object／fixture hashesを照合。古いAX参照へのpressはinvalidUIElementで、成功したstale dispatch拒否の証明とは扱わない。Native helperはcustom sleeperを使わず最新public initializer。Geometry／Tab／VoiceOver／model／会議／browser／Keychain受け入れは含まない。

証拠 `.tmp/screen-agent-review/approval-setup-stability/` のcheckpoint、旧test、setup/cancel probes、guard-removed-red、green-with-cancel、gate-first-failure-evidence、gate-second-evidence、native-current.log、independent-review。Native詳細は `.tmp/screen-agent-review/native-accessibility/ef78fa88-cc6c-47bd-a8bc-94395f93629c/`。閾値／assertion／skip／parallelism／gate／policyの引下げなし。G3／commit／PR／push／mergeなし。


## 複合入力中の共有token取消 — 2026-10-03

現在の判定は **No-Go**。全7 FRはin_progress、受け入れ完了0件。公開coordinatorでtoken-only取消後にも複合入力のclick／typing／後続keyが送られる4境界をRED4issuesで再現。共有tokenをprivate input executorへ渡し、承認・座標計算後、focus click後のtyping、両branchの各key前にチェックを追加。未変更回帰4cases、関連45tests／4suites PASS、標準gate1086tests／118suites／1.747s G1／G2 PASS、独立review限定PASS。Simulation recorderの協調的境界検証で、既に送信したprefixの取消・native primitive内・live承認待ち・全route／deadlineの保証ではない。先行native AX9操作のef78証拠は旧coordinator snapshotに保持。Chrome製品経路・実会議・Keychain・VoiceOver／Tab・他の時間制限失敗の根因は未完了。

executeSyntheticActionは従来Task取消だけを確認し、外側のCancellationTokenチェック後にtokenだけが取消されると、そのdecisionの入力が続いた。公開executeと実decision engineで、dispatch entry／clickからtyping／clickからkey列／座標なしkey列の最初のkey後を制御し、余分な入力を4casesで検出。共有tokenをhelperへ渡し、そのthrowIfCancelledでTask取消も確認。既存rollback／held-input releaseを維持する。新public API／handler／dependency／budget／閾値の変更なし。

証拠 `.tmp/screen-agent-review/coordinated-cancellation/` のbefore-coordinator、red、未変更test hash、green、gate-evidence、root-cause、independent-review、checkpoint。Swift lock pattern非対応のため機械lockは主張しない。Mock inputはOS eventを送らず、単一native call内部のraceや原子的dispatch停止・latency deadlineは未証明。ActCommand single-stepをこの変更で検証したとは扱わない。前checkpointのHUD／native成功や歴史的gate失敗を保存。G3／commit／PR／push／mergeなし。


## 座標viewportの固定と最新全体gate — 2026-10-03

現在の判定は **No-Go**。全7 FRはin_progress、受け入れ完了0件。共有token取消の4境界を修正し、非同期処理中の実display変化に依存していた座標回帰にinternal TaskLocal viewportを追加。元のassertionを維持し、2つのviewportのexact center・nil復元を追加した未変更RED testで関連345tests／16suites／0.168s PASS。最新の標準gateは1086tests／118suites／3.281s、process timeout2件と取消sleep1件の時間制限でFAIL。今回の4取消cases・2座標casesは同じ全体runでもPASS。失敗対象の未変更単独検証5tests／2suites／0.381s PASSは全体PASSを代替せず、全体で遅くなる根因は未確定。先行gate／nativeの成功は歴史的checkpointとして保存。Chrome製品経路・実会議・Keychain・VoiceOver／Tab・native取消／全routeの受け入れは未完了。

元のtestは空候補の座標を先に読み、その後のasync coordinatorが無効候補に使った座標とexact比較していた。両方ともNSScreen.mainを参照するため、途中でmain displayが変わると異なる。失敗座標864,558.5と818,1837はowned probeで得た2つの実display中心に一致。ただしprobe自身はmain変更を再現せず、元runのOS／app／並行fixtureの寄与は未隔離。内部fixtureだけをnil-default TaskLocalで保持し、製品既定のlive fallbackと有効候補の優先順位を維持。viewportのfinite／positive-sizeを確認。元のsuccess・finite・positive・nonempty・exact-equality assertionsを保持した2casesは、fixture未読RED2issues／0.115sから同一test bytesのGREENへ。

証拠 `.tmp/screen-agent-review/coordinated-cancellation/coordinate-checkpoint.json`、`coordinate-root-cause.md`、`coordinate-viewport-red-final.log`、`green-coordinate-final.log`、`source-hashes-coordinate-final.json`、`gate-coordinate-final-failure-evidence/`、`timing-isolation.log`。最新全体FAILはprocess0.754525／0.754470416s対700ms、sleep743.8449859619141ms対400ms。閾値／skip／parallelism／gate／trust変更なし。単独PASSだけでは全体失敗原因・期限保証を主張しない。前の全体PASS・座標FAILも保存。G3／commit／PR／push／mergeなし。

独立reviewは今回のinternal TaskLocal／既定挙動／元assertions維持／RED-GREEN／最新FAILを確認し、限定source/evidence PASS、新指摘なし。全体gate FAIL／全goal No-Goのまま。review記録は `coordinated-cancellation/independent-review.md`。
