# Final Review — Screen-driven agent

## 2026-10-04 human-approved merge with open verification

The independent review bound to candidate diff `7227b5a79d6016aec8322e18da08cf2ad8b2ac91bb4f2d8baca07044ba316814` returned HUMAN/no-go. The user then explicitly approved PR merge with the reported gaps. This approval accepts the release risk; it does not turn the gaps into passing results. Chrome/X production collection, the full native route/race/accessibility matrix, and the frozen System One both-score improvement remain unresolved. Zoom/Meet live verification was separately waived because meeting material was unavailable. Any PR for this candidate must keep these exceptions and follow-up work visible.


## 2026-10-04 follow-up

`pw-agent` successfully used and closed only an owned X test tab. Two scrolls exposed multiple explicit >5K view counts, but that is manual DOM-visible evidence, not MCA production collector output. An MCA ask did not collect posts; an unscoped capture resolved a different existing Chrome window, so no content from that capture is used. Keychain showed a login-password prompt; no password or Always Allow action was provided. The debug binary was ad-hoc signed, so persistent permission is unverified.

A train-only intent/search fix reached 54/54 train while heldout remained 25/28; the source changes were REVERTed. During diagnosis, a grep accidentally exposed a partial heldout JSONL excerpt to the agent context. The excerpt is not reproduced or used, but blind independence for this session is compromised. Do not claim an uncontaminated blind heldout pass. At this checkpoint, the candidate remained No-Go and unmerged; actual meeting material and the native route/accessibility matrix remained incomplete. The later human-approval addendum above records the subsequent merge decision without changing those findings.



Latest gate recheck: two standard `Scripts/gate.sh` runs pass G1 and G2 trust but fail G2 tests with the same two 700ms child-process timeout assertions (first 0.983s/0.947s; second 1.706s/1.699s). The isolated suite passes 4/4 in 0.387s; no root cause is established and thresholds are unchanged. Do not call the current full gate green.


Resolution: dedicated the timeout and delayed SIGKILL callbacks to a concurrent `userInitiated` queue. Focused process tests pass 4/4 in 0.380s; the latest full `Scripts/gate.sh` now passes G1/G2/guards (1272 tests, 2 skips, 0 failures). Earlier full-run timing failures remain recorded; the scheduling-contention explanation is plausible but not proven. No timing threshold or assertion changed.

## 2026-10-04 refreshed-current-main checkpoint

現行 `main` の `5f23e868806c119ba9e4a5cf94d6f36d1625dcbb` を基点とする隔離worktree `feature/screen-agent-refresh` へ候補を載せ替え、main側のkeystroke承認を保ったscoped authorization統合を行った。focused authorization/integration suiteは85tests／8suites PASS。未変更の `Scripts/gate.sh` はG1 build、G2 trust、Swift tests、guardsすべてPASS。xUnitは1270tests、既存skip2、failure/error0、160 suites。fresh gate evidenceはworktree `.tmp/gate/logs/`、summaryは `CONTEXT.json` の `evidence.current_main_refresh`。

必須System One evalはtrain50/54（baseline50/54）、heldout25/28（baseline25/28）、noise0、NO CHANGE／STALLED 3 rounds。4 missesは `r-q-python-file`、`r-q-ko-report`、`r-q-screenshot-howto`、`d-search-for`。heldout data、grader、floor、baselineを変更していない。Chrome attach失敗後の状態変更回答は未取得で再試行なし。実会議資料はユーザーの最後の回答で「まだない」。全7 FRはin_progress／accepted0。現candidateのfresh独立trust review、実機受け入れ、mergeは未完了。この段落をcurrent statusとし、以下の旧checkpointは記録時点のsource/evidenceとして読む。

Depth: Deep / Self-review: same session / HEAD and base: `58f66dd` + uncommitted candidate

現在の判定は **No-Go**。全7 FRはin_progress、受け入れ完了0件。第三fresh dual reviewは両者FAIL／No-Go。追加source欠陥2件を作者が修正し、標準gate PASS。第四独立reviewは未実施。実機受け入れとeval双方改善条件が未完了のため、commit／PR／mergeは未実行。

## Project profile

Swift6.2/macOS26、native AppKit/SwiftUI/CLI/MCP、AX/CG/ScreenCaptureKit/Vision、SQLite/FTS、Keychain、external LLM/TypeSafe。GitHub CIを持つ製品。AGENTS.md/CLAUDE.md/CONTRIBUTING.mdと凍結SPECに従う。追加dependencyなし、Package.swiftはtest resourcesのみ。mainへ直接変更せず隔離worktreeで作業。

## Scope and intent

全7 FRの画面駆動agentを完成し、実会議資料からnotes、実Chrome/Xの>=5K postsから有用な回答を作る。一操作一承認、fresh target検証、取消・期限・正直な結果表示を全routeへ適用し、完了後create-prでmergeする。Core→Sensing→Reasoning→Presentationとwatch/chat/CLI/MCPのconsumerをreview対象に含む。

## Gate

| Command / evidence | Exit | Result |
|---|---|---|
| Scripts/gate.sh / final-review-fixes/round3-gate.log | 0 | build2s、trust4s、tests4s、guards0s PASS |
| swift test / round3-gate-evidence xUnit | 0 | 1261 discovered =1259 executed PASS+2 existing credential skips、159 suites、2.543389s |
| node trust tests / trust-tap.txt | 0 | 66 PASS、incident guards PASS |
| round3 related regressions | 0 | 26 tests/12 suites/.057s PASS |
| final hillclimb run | 0 | train50/54、heldout25/28、noise0、NO CHANGE／STALLED |

証拠はcurrent worktree `.tmp/screen-agent-review/final-review-fixes/`。skipは既存Gemini/Anthropic credential guards。G3未依頼。gate/threshold/parallelism/trust/floor/grader/baseline変更なし。

## Findings

round1/2で確定したsource欠陥は修正済み。approval detailsはMarkdownを通さずescaped literalで全行表示し実SwiftUI+Vision回帰で確認。PIDと共通JSON整数変換は非trapping検証。既存file snapshotは8MiB上限とchunk取消。displayのnil-local-targetはread/collector境界で拒否。公開pinned inspectorはasync exact-selected snapshot、syncはfail closed。tool候補数1...25、native0...100、file/history非正limitは検索前拒否。未観測Korean結果を完了と表示しない。

原REDのnumeric signal5、candidate/scope8issues、approval/size3issues、read/result8issuesを保持。negative-limit初回はfixture型名compileFAIL、訂正後runtime signal5が有効RED。原numeric/scope test hashes不変。関連GREENは上表。第三独立reviewは117-source snapshotでB/CともC0/H3、FAIL／No-Goを確定。追加source欠陥は次段の2件。

第三review後の作者修正（独立再review未実施）: Copilot.askは質問開始時にHUD targetをfreezeし、同じtarget resolver結果をauthorization.window、screenshot、subjectへ渡す。implicit/explicit displayはlocal resolverを呼ばずwindow=nilを保持。dragは既存ensureTrusted／validateCoordinateでmove、down、drag、最終pause後を確認し、down後はdeferで最後に送信した位置にupを必ず送る。click／key／unicode／scroll／mouseMoveのdispatch直前にも既存guardを再利用。

本番branch／sequencingの抽出後、修正前にRED6tests/2suites/24issuesを再現。元2test filesのhashを保持して関連GREEN26tests/12suites/.057s。実child Task取消を3pause境界で追加確認。ここでの証拠は内部本番helperとrecording emitterであり、public askのmodel／capture／全session構築やCGEvent／AX／TCCの実入力、native raceの原子性を証明しない。source helper抽出ではCGEvent作成をcursor移動の前に寄せ、作成失敗時の不要な移動を防ぐ。四回目のreviewで同じblockerを再採点しない。

HIGH: 全7 FRの実機受け入れが未完了。actual Chrome/X collector/model answer、actual Zoom/Meet notes/dedup/Stop、Keychain回数、VoiceOver speech/Tab、full native routes/races/deadlinesは未証明。ownerは実装agent、外部条件の回答後に凍結SPEC ACを実測する。
HIGH: mandatory train AND heldout improvement未達。train-only2候補はREVERTしcurrent sourceへ残さず、final runもNO CHANGE。heldoutを開かずfloor/grader/baselineを変えない。ownerは実装agent、principled root-class修正が必要。

## Dimension coverage

| D | Evidence / limits |
|---|---|
| D1 Intent | 全7FRを維持、全件in_progress、actual meeting/feed未完 |
| D2 Correctness | scoped reads/collection、literal approval、bounded numeric/sizeのpublic回帰、round3追加source欠陥を作者修正、独立再reviewなし |
| D3 Failure | huge/fraction/bool/negative integers、stale/denial/cancel/expiry/changed parent/windowを検証 |
| D4 Tests | 1259PASS/2existing skips、immutable RED→GREEN、eval改善とnative matrix未完 |
| D5 Security | main default-deny/FileWritePolicy、scope拒否、details全表示保持 |
| D6 Privacy | composite exclusions/postpixel metadata、nil scoped fallback拒否、native transition未完 |
| D7 Supply chain | 新dependency/CI変更なし、owned test resourcesのみ |
| D8 Performance | 8MiB existing file/64KiB chunks、AX800 nodes、bounded candidates/collection、device実測未完 |
| D9 Concurrency | UUID once、cooperative await取消、fresh inode/held parentFD、native race/ABA未証明 |
| D10 Reliability | bounded loops/process/deadline、typed failure、全native120s未証明 |
| D11 Cost/ROI | 20actions/15rounds/10scrolls/256fingerprints、新runtimeなし |
| D12 Compatibility | legacy gate/error-result/public typealias/optional persisted fields、native inspector42/100保持 |
| D13 UX/DX | own AX9/keyboard18、literal OCR、honest locale results、VoiceOver/Tab未証明 |

PM/QE/UXは全意図未完了でNo-Go。Developer/Security/SREも第三reviewでNo-Go。追加source修正のunit確認を独立source再reviewへ昇格しない。STRIDEではscope/excluded-read/opaque script/file gateをtrace、根拠のないsecret/privilege claimなし。architectureは既存境界再利用とrollback可能性、全受け入れを省略する根拠にはしない。

## Verified / NOT verified / Known limitations / Adversarial check

own default ChatView/HUD/registry/guarded fileの外部AX run `0775a9ea-d811-45ba-bd35-16d83f0d9c5b` 9controls/27responsesとkeyboard run `085b949d-efaa-4869-a8eb-92bcbb3a1c22` 18postconditionsはrecorded UI/file hashesでPASS、helpers終了。実会議/feed、model、VoiceOver/Tab、最新numeric/Sensing native acceptanceを含まない。

Chrome最後のattach失敗後は状態変更回答待ち、会議資料は最後「まだない」、Keychain AlwaysAllow未確認。pixel/metadataはatomicではなくABAを保証しない。file advisory lockは非協調editorへのCASではない。Stopは既effectをrollbackしない。legacy sync pinned inspectorは明示的に空を返しasync APIへ誘導。

修正は必要だったか: valid model JSONとdisplay sessionが実sourceのcrash/foreign scopeへ到達したため必要。単純な代替: consumer毎のtrapping変換やAX複製より既存shared helper/snapshotへ集約。削除可能code: .tmp diagnosticsは製品に含まれず、承認/取消境界は必要。未疑問の前提: 実OS/native timingがfixtureと同じという前提は採用しない。unit/gateとownUIのPASSでlive成果欠落を相殺しない。

## Review Summary

| Item | Result |
|---|---|
| Verdict | No-Go |
| Counts | Third B/C each C0/H3 No-Go; author fixed two distinct new source defects; HIGH2 whole-intent blockers remain; post-fix unreviewed |
| Evidence | gate0、1259PASS/2skips、related26GREEN、public runtime RED保存、evalNOCHANGE |
| Blockers | 全実機受け入れ、eval双方改善、post-round3 source independent re-review未実施、shipping trust |
| Next actions | root: 同じblockerの第四reviewを停止。外部条件の改善または新approach後live AC／both-score改善、全受け入れ後create-pr |

三回連続No-Goの同じall7受け入れ／eval blockerに対し、`~/.codex/skills/final-review/SKILL.md`の「Three consecutive No-Go on the same blockers means stop and escalate to the user with options, never a fourth attempt.」を適用。具体的な再開経路は実Chrome接続の状態改善・実会議資料・Keychain結果を揃えて全件検証、または要件分割／評価policy変更をユーザーが明示決定すること。後者の決定は受けておらず、全7要件は保持。

## Historical checkpoints（以下の「最新」「PASS」は記録当時のsourceのみ）


# Screen Agent Approval Loop — 検証記録

現在の判定は **No-Go**。全7 FRはin_progress、受け入れ完了0件。共有token取消の4境界を修正し、非同期処理中の実display変化に依存していた座標回帰にinternal TaskLocal viewportを追加。元のassertionを維持し、2つのviewportのexact center・nil復元を追加した未変更RED testで関連345tests／16suites／0.168s PASS。最新の標準gateは1086tests／118suites／3.281s、process timeout2件と取消sleep1件の時間制限でFAIL。今回の4取消cases・2座標casesは同じ全体runでもPASS。失敗対象の未変更単独検証5tests／2suites／0.381s PASSは全体PASSを代替せず、全体で遅くなる根因は未確定。先行gate／nativeの成功は歴史的checkpointとして保存。Chrome製品経路・実会議・Keychain・VoiceOver／Tab・native取消／全routeの受け入れは未完了。

## 以前のcheckpointでの検証

| 検証 | 結果 | 証拠 |
|---|---|---|
| 未変更 `Scripts/gate.sh` G1/G2 | PASS、1078 tests /115 suites、Swift 1.806秒 | `.tmp/screen-agent-review/gate-chat-observation-final.log` と同名 `-evidence/` |
| Browser scope/privacy追加回帰 | PASS、22 tests /4 suites。拒否・取消・承認後Task取消・destination変更でzero dispatch、許可したswitch、除外metadata、pinned一覧、pinned AX URL/new-tab拒否 | `workspace-scope-green.log`、`tabs-boundary-red.log`、`workspace-scope-red.log` |
| その他追加privacy/scroll回帰 | PASS、40 tests /9 suites | `.tmp/screen-agent-review/privacy-browser-scroll-final.log` |
| EN/JA/KO native ChatView | PASS、実描画のApprove/Reject/Stopと検証file結果、old/late UUID拒否 | `.tmp/screen-agent-review/native-ui/result.json`、各locale PNG |
| 実Copilot／real model／ChatWindow | PASS、Approveで正確なbytesのみ保存、Reject/Stopは非変更 | `.tmp/screen-agent-review/live-validation/runtime-result.json`、runtime PNG |
| 実Copilot startup | Accessibility=true、Screen Capture=true、credentialを持つprovider2種 | `live-validation/preflight.json`、`startup.txt` |
| 実Firefox/X専用window | FAIL、navigation後にowned AX/CG identity消失。viewport/scroll/最終回答の証明なし | `live-validation/firefox-result.json`、`firefox-cleanup.json` |
| 独立source review | Scope/privacy/承認UIに加え、未観測offline completionのdecision/planner修正と回帰のsource/evidence PASS。残る新HIGH/MEDIUMなし。実機をreviewerは実行していない | `final_independent_c`、`offline-completion-independent-review.md` |
| 最新source actual Copilot `/act` | Approve／Rejectの2cases＋別run Stop1caseを確認。初回3case run全体のStop OCR FAILは保持 | `copilot-act-final-guarded/result.json`、`copilot-act-stop-current/result.json` |
| `git diff --check` | PASS | CLI |

最新sourceの `/act` 行は今回の限定経路の証拠。他のnative PASS行は旧source snapshotの証拠で、全native受け入れは未証明。表内の略記logは `.tmp/screen-agent-review/` 以下。通常のSwiftPMで実行し、試験削除・skip・閾値・parallelism・gate・trust policy変更なし。旧未観測success期待はfailure必須へ強化した。特別なSwift shim／cache設定は最新gateで使わない。G3は未依頼。

直前のdocs-sync後gateはschema/summary用TypeSafeActTool testがlive Search候補からactionを試み、approvalRequiredで1issueとなった。既存inspectorProviderを既存UIStateProviding protocolへ一般化し、mock snapshotでAX metadata依存も除去。Action none／Confidence0.00のexact assertionsと、actual click decisionのnopresenter拒否を検証。Default inspector、許可条件・skip・閾値は変更せず、関連19testsと最新全gateはPASS。独立reviewも基準引下げなしと判定。失敗証拠は `gate-status-sync-final.log` と `gate-status-sync-failure-evidence/`。

## Scopeと修正

既存native Swift/AppKit/SwiftUI、CLI、stdio MCPを利用する。追加dependency、DB migration、CI、gate、trust policyの変更なし。Package.swiftにはowned画像のtest resource指定のみ追加。Main側では作業せず、feature branchだけを`38368cb`へfast-forwardした。別作業者のmain/check-out変更には触れない。

- Immutable approval UUIDと操作内容をHUDからconcrete sinkまで保持。Stop／reject／expiry／late callbackは後続dispatchを止める。
- 観測したwindow ID/PID、AX/CG title/frameの一意性と候補を再検証。同appの別windowへfallbackしない。座標clickは正当な承認後focus復帰を許し、keyboardはfocused field identityを保持する。
- ファイルの既存bytes、parent FD/dev/inode/realpathとopenatを検証。親差替え、hardlink/FIFO、対象変更を拒否。新規のcaller指定pathも承認必須。
- Own child process groupのTERM→KILL、bounded pipe drain、cancel/timeoutを実装。外部processや既存user tabの終了は行わない。
- Historical/live/watch/tool textをmodel投入前にredact。fresh title/PID/bundleのprivacy gateをAX、browser、SCK captureへ伝播。除外したfocused windowがない場合に全displayへfallbackしない。
- Native capture既定scaleを1.0にし、560×672の実button文字をOCRで認識。半解像度で認識しなかった比較も保存。
- 背景scrollはfinite/display内coordinateとliving PID、selected scopeを検証。NaN／infinity／display外のRED→GREENを確認。
- `browser_tabs`のpinned switchをdispatch前に拒否。unscoped switchは承認＋destination metadata再確認＋取消検査。pinned listは選択windowのみ、除外windowはURL取得／返却前に除く。
- AX workspace URL openはwindow IDを指定できないため、pinned goto/new-tabを承認・dispatch前に拒否。unscopedでもopen直前に取消を検査。
- Collectorは完全なviewportを保持し、post単位で重複を除く。観測views・body・author対応とbounded coverageを返す。

## 実機証拠の範囲

Native UI fixtureは実ChatView→HUD.requestApproval→ToolRegistry→GuardedFileWriterを使う。Approve/Reject/Stopの解決は描画されたbuttonへのnative NSEvent。old/late UUIDを直接resolveするケースは無視されることの検証専用。AX buttonsの列挙は空で、keyboard／VoiceOverの証明には使わない。keyboardは別のNSApplication event queue fixtureで確認した。

Full Copilot fixtureは実compositionとconfigured real modelを使う。供給したsynthetic decisionを検証fileへ書く経路がPASSした。最初の試行はmodelが文章で承認を求めて未実行、次の試行は内容不一致で拒否。exact JSONを指定した試行だけがApprove/Reject/Stop全件PASS。これを実会議の資料観測の証明としない。

実SCKでfresh excluded title、forged PID、missing focused targetを拒否。Display filterは他appの49 windowsを除外したcountのみ確認し、pixelの意味比較は未実施。性能はowned native UI 9 capturesで77.7–150.5ms、capture+OCR257.1–656.6ms。Firefox性能を証明しない。

Chromeはpw-agentのCDP filter proxy起動失敗後に同sessionの専用tabを閉じ、attachをretryしなかった。pending専用Firefox-tab例外への最新のユーザー承認を受け、既存Firefoxに専用windowを作成。新規CG IDがbaselineにないことと新規AX identityを確認し、native入力はexpected PID/window guardを通した。navigation後のidentity喪失で停止し、未知／既存windowをcloseしなかった。Chrome選択済み。修復後の一度の再接続例外への回答待ち、実Zoom/Meet共有資料の受け入れは未完了。

## Deep dimension coverage

| Dimension | 確認／限界 |
|---|---|
| D1 Intent | 全要求維持。実会議→artifactとChrome/X ≥5Kは未完 |
| D2 Correctness | Immutable operation、snapshot/candidate、window scope、post/count対応をsource/fixturesで確認 |
| D3 Edge cases | reject/cancel/expiry/late UUID、parent/page/destination変更、ambiguous window、bounded partial result |
| D4 Tests | 全1078成功、public registry・native ChatView・actual Copilot経路の回帰。全native route matrixは未完 |
| D5 Security | Concrete sink gate、非interactive mutation拒否、pinned scope外dispatch拒否 |
| D6 Privacy | Task-scoped policy、fresh metadata拒否、text redaction。画像中の全PII masking／display pixel比較は未証明 |
| D7 Supply chain | N/A、dependency/manifest/CI変更なし |
| D8 Performance | 10scroll、8K viewport、20actions、15rounds、120秒active budget。Firefox測定とfull deadline未完 |
| D9 Concurrency | MainActor waiter、actor budget、answer UUID、late callback停止、parent FD。owned native changed-field/wrong-window/cancelled-focus拒否PASS。native focus race全件は未完 |
| D10 Reliability | Own process timeout/cancel、partial report、権限診断。以前のhangは最新gateで再現せず、単一原因は断定しない |
| D11 Cost/ROI | 既存pipelineに局所gate、追加runtime/dependencyなし。liveモデルcost未測定 |
| D12 Compatibility | Optional Codable candidateLimit。pinned AX goto/new/switch、未証明pressは拒否 |
| D13 UX/DX | EN/JA/KO実描画と実provider承認経路PASS。keyboard操作はown-window eventsでPASS、VoiceOver/Tab未検証 |

Wiring: Swift targetへの自動組込はbuildで確認。ChatView/HUDState→Copilotとwatch→ask→authorization→sinkを確認。Web route/barrel/SSEはN/A。静的配線はnative acceptanceの代替ではない。

## 残る受け入れ／出荷

- ユーザーが選んだ実Chrome/Xのviewport観測、scroll、≥5K対応の最終answerとcoverage。
- 実Zoom/Meet共有資料→standing objective→有用artifact、重複抑制、Stop後非再開。
- Actual Copilot/watch/CLI/MCPのDesktop経路、全app/OSのfocus/activation/interruption race、VoiceOver/Tab、全route/120秒deadline。owned別processの複数window/focus/input/対象消失は後掲の範囲で確認。
- 最新committed diffへの独立trust review、人間の必要なshipping承認、PR/merge/cleanup。

`trust.mjs diff-id`はcommitted main...HEADのみを対象とし、現時点のdirty変更を含まない。空diffのIDにtrust reviewを束縛してはいけない。source PASSはshipping承認ではない。Feature commit／PR／push／mergeは未実行。

## 履歴と限界

前回の全test待機ではowned helperにSkyLight/TCC XPC waitとdispatch_once waiterを観測した。自身のhelperのみ停止。fresh main `38368cb`の994testsにも3 timing failuresを再現し、既存閾値は緩めていない。最新変更treeの全gateはPASS。過去のrestricted Keychain／AX=false診断を、現在の実app状態へ適用しない。

Parserは明示views labelと@handleを要求し、icon-onlyの数値を推測しない。Advisory lockは非協調editorに対する完全CASを保証しない。Stopは既に実行済みの外部effectをrollbackしない。

診断中に`xcrun xctest -help`が認証情報を含む環境変数をtool出力へ表示した。値は成果物に保存しておらず、この診断方法を停止した。出力を共有せず、該当キーを更新する必要がある。値をこの記録へ転記しない。

## 最新browser環境 checkpoint — 2026-10-02

ユーザーはChromeを選択。pw-agentを新規session `scrc1002-root-x`で一度呼び、missing websocketsで失敗。専用tab `F3E80093`を同sessionでcloseし、attach retryは未実施。

Task-local venvのmodule修復後、実pw-agent proxyのlocal synthetic upstreamによるfilter/bind/終了はPASS。Project dependencyやglobal pw-agentは変更していない。実browser acceptanceは未検証のまま、AGENTS.md規則の一度の再接続例外への回答待ち。証拠は `.tmp/screen-agent-review/chrome-runtime/`。

## Native keyboard / scroll checkpoint — 2026-10-02

Approve ⇧⌘A、Reject ⇧⌘R、Stop Escを追加し、Returnのみでは承認しない。押し続けた承認キーが次の操作を承認するREDを実NSApplication event queueで再現。両buttonsでkeyDown repeatを拒否し、mouse/nil eventはrepeat getterを読まない。最終sourceから診断printは除去済み。

実ChatViewのkeyboard→mouse連続fixtureはEN/JA/KO全件PASS。正確な承認bytes、Reject/Stop非変更、approve/reject repeat拒否、UUID分離、old/late callback拒否を確認。証拠は `.tmp/screen-agent-review/native-keyboard/both/result.json` とPNG。これはown-window NSEventによる検証で、VoiceOver・Tab・実browser・会議の証明ではない。

長い承認カードのmouse検証は最初の承認後にSwiftUI layout停止。新keyboardコードだけを除いた同条件も60秒timeout。sampleはGraphHost/LazyStackで、message-count scrollを非animationにする一変数比較で3locale/9mousecontrolsが完了した。両scroll triggerとbottom anchorを維持してanimationを除去。baselineとsample、mouse-only結果を同dirへ保存。全geometry/OSの証明ではない。

最初の非animation mixed runは通常Rejectが2秒以内に解決しなかった。承認カードのactual capture後にRejectを送るdiagnostic runとprint除去後の最終runはPASS。最初の未配送の単一原因は未確定として `mixed-reject-delivery-failure.json` に残す。閾値・assertionは緩めていない。最新全gateは1061/108 PASS。全7FRはin_progress、commit/PR/merge未実行。

## Native scoped desktop checkpoint — 2026-10-02

別processのowned AppKit appに2windowsを作り、実ChatView→HUD→scoped ActionAuthorization→ToolRegistry ComputerActionTool→AX snapshot/focus→EventSynthesizer CG inputを確認。Fresh run_id/target PID/controller PIDで相関した最終結果は11意味ケースPASS（別に2focus拒否診断）。選択clickは一度だけ、承認Unicodeは選択fieldとexact一致。他field/countは各操作で非変更。Reject/Stop、label/title変更、同名同frame、対象hide、別focused window、既に取消されたfocus要求を拒否。Field変更ケースはfocus復帰後のmutation ACKとexact staleTarget errorを要求。label/titleもexact staleTarget＋focus失敗なし、duplicate/hideはtyped selectedWindowUnavailable＋exact deniedをassertし、別のactivation失敗を代替証拠にしない。最終fresh runで強化済み全branchesがPASS。

最初の2runsはAXRaise成功・activation falseでzero click。後のdiagnosticはyieldなしでもPASSしたため、単一原因は確定しない。最終sourceは[Appleのcooperative activation手順](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation)に沿ってvalidated targetへyieldし、取消を再検査してactivateする。既存のactivation-result/foreground/window guardは維持。sourceの診断printは除去済み。

証拠は `.tmp/screen-agent-review/native-focus/result.json`、`final-source.json`、`pending-native-click.png`。両owned processes正常終了、logs空。Fixture本文がRejectというbutton labelを含みOCR2候補で停止した失敗は `ocr-ambiguity-result.json` に保存し、本文だけneutralにして一意性assertionを維持した。

このpresenterはCopilotと同じfocus手順を使う別composition。Actual CopilotのDesktop action、watch/CLI/MCPの全経路、全activation/input race、VoiceOver/Tab、実Chrome/X/会議、120秒全体deadlineは未証明。全FRはin_progress、出荷No-Goを維持する。最新標準gateは1061/108 PASS。

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

## Tab／keyboard追加確認 — 2026-10-02

現在sourceのEN／JA／KO keyboard18casesは、各入力前のown activation／key-window検査を加えたfresh run `678f76a3-6d2b-4046-be14-fc80cc7bcc59` でPASS。元の条件・2s deadlineを保持し、matched UUID／terminal complete／passedtrueをrunnerが確認。先行Reject失敗は保持し原因未断定。

実Tab／Shift-Tab16回はfull keyboard access=falseでtext fieldsの移動とpending／file非変更を確認。承認ボタンのTab移動／VoiceOverは未検証。詳細はLIVE_VERIFICATION.md「現在sourceのTab／keyboard診断」参照。production変更なし、全FR in_progress／No-Go。

Independent review: native-tab-guarded/independent-review.md scoped PASS; no new H/M. Hashes/bytes/status/cleanup and retained failure/limits verified. Not a trust/shipping approval.

## 固定署名とChrome再接続 — 2026-10-02

ユーザーからKeychain確認が繰り返し表示されることとChrome接続可能の回答を受け、専用test tabで再接続成功。pw-agent session scrc1002-root-x／tab6DF87C36／run1f37c369-7186-4fbd-a7b8-3451cbab2289で実scroll0→1063→2126、viewport bounds内DOMのpost-specific labelsとURLに対応する54,432／5,965／29,740viewsを確認。sticky header遮蔽／pixel全表示は未検証。requests／consoleを記録し、専用tabだけclose-test0。初回semicolon式scrollのSyntaxErrorは別ログに保持。production Copilot／collector／最終model回答の受け入れではない。

検証controllerがad-hoc署名／cdhash-only DR、本体build/MyComputerAgent.appは既にApple Development署名と確認。ignored runnerを固定証明書でown controller .appだけsign／strict verifyする方式へ変更。記録したsource／objects／Info.plist、identityと両binary SHAが一致する場合は再compile／re-signなしで再利用。Keychain ACL／unlock／credential値／環境へのコピーなし、G3も未実行。これは完全なcompiler-input再現cacheではない。source review PASS、署名後の固定binary再利用を実行確認。

実run c162c1f5-6a0c-4d89-bb84-9d1f3a654211はKeychain境界を通過しstartup14.23s、real watcher／configured model／native Chat mouse承認でselected materialのreference8E9A41F5を含むnotes保存、承認前非変更／approved exact bytesを確認。その後unchanged-dedupで「Unchanged material started a duplicate task」と失敗し、run全体FAIL（native0／target0／runner1）を保持。B変更／Stopは未実行。両own PID終了、212input hashesとsigned controller hash一致。確認dialogの回数／Always Allow選択／今後一度だけとなる実測保証は未証明で、ユーザーの選択を問い合わせ中。

証拠 .tmp/screen-agent-review/keychain-identity-diagnosis／copilot-standing-stable-signature／chrome-live-scroll。全7FR in_progress／accepted0／No-Go。実meeting artifact、重複taskの修正、production Chrome/X経路、全route/race/accessibility/deadlineの受け入れは残る。

Independent actual-runtime review confirms saved notes/exact reference/signature/hash/cleanup; unchanged-material second task remains MEDIUM acceptance failure (no second mutation proof, exact image cause unproved). Initial gate timing3issues retained; same-source targeted5tests/2suites PASS0.384s, thresholds/skip/parallelism unchanged. Full gate rerun pending.

Second full gate retained4issues (two diff elapsed assertions, cancellation elapsed, Chat Quartz-surface check). Same-source/threshold targeted14tests/3suites PASS3.375s. Observed other-process CPU load does not establish a sole cause; no external process terminated. Third standard gate pending. Actual-runtime review is in copilot-standing-stable-signature/fixture-review.md.

最新標準gateは未合格。3回目は取消テストが502.317msで400ms条件を超え、1078tests／115suites中1issue。先行3issues／4issuesの失敗も保存。単独5tests／2suitesと14tests／3suitesはPASS。Source／閾値／skip／parallelism変更なし、根本原因は未断定。G3／commit／PR／mergeは行わず、No-Goを維持する。署名の固定・binary再利用は実行確認できたが、確認dialogが以後1回だけとなることはユーザーのAlways Allow選択を含め未検証。

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


NO UNRESOLVED DECISIONS
