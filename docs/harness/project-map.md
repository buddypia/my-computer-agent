# 작업별 프로젝트 지도

필요한 행의 파일만 읽는다. 작업 계약과 진행 상태는 워크트리의
`.tmp/worktree-<branch의 /를 __로 치환>/PLAN.md`에 둔다.
`make wt.new BR=feature/<name>`이 기본 양식을 만든다. 요청의 목표·범위·완료 조건을
먼저 채우고, 조건 변경은 Decisions에 이유를 남긴다. 재개할 때는 Recovery와
실제 git/프로세스/PR 상태를 함께 확인한다. 작업이 끝나면 Change receipt를 PR 또는
추적되는 보고서에 옮긴다. `.tmp`와 워크트리는 정리 후 남는 기록이 아니다.

| 작업 | 진입점과 근거 |
|---|---|
| 빌드·테스트 | `AGENTS.md` 품질 게이트, `Scripts/gate.sh`, `Package.swift`, `docs/dev-notes/TEST_INFRA.md` |
| 실행 중 앱에 반영 | `README.md`의 “Getting a change into the running app”, `Scripts/run.sh` (번들·서명·재시작 포함) |
| 모듈·의존 방향 | `Package.swift`: Core → Sensing → Perception → Memory → Reasoning → Realtime → Interop → Presentation |
| 대화·도구 실행 | `Sources/MCAReasoning/Agent.swift`, `Tools.swift`, `docs/architecture/single-agent-loop.md` (실측한 단일 루프 결정) |
| 자율 GUI 루프 | `TwoTierAutonomousLoopCoordinator.swift`, `MCACore/SubgoalPlan.swift`; Tests/MCAReasoningTests의 TwoTier/AutonomousLoop 스위트 |
| 모델·로컬 판단 | `ModelRouter.swift`, `TypeSafeDecisionEngine.swift`, `RequestRoute.swift`, `docs/evals/system-one.md`; heldout 파일은 읽지 않는다 |
| 권한·위험 작업 | `ActionAuthorization.swift`, `SafetyGuardrails.swift`, `Sources/MCACore/ActionApproval.swift`, `SECURITY.md` |
| 브라우저 | `Sources/MCASensing/BrowserDriver.swift`, `Sources/MCAReasoning/BrowserTools.swift`, `docs/features/browser-automation/SPEC.md` |
| MCP·컴퓨터 조작 | `Sources/MCAInterop/ContextMCPServer.swift`, `docs/evals/computer-use.md`, `docs/features/cursor-computer-use-parity/SPEC.md` |
| 관측·검색·메모리 | `Sources/MCASensing`, `Sources/MCAPerception`, `Sources/MCAMemory/ContextStore.swift`, `MCACore/DesktopObservation.swift` |
| UI·음성 | `Sources/MCAPresentation`, `Sources/MCARealtime`, `Sources/mca/Copilot.swift` |
| 하네스 수정 | `.agents/skills/harness-design/SKILL.md`, `data/harness/experience.json`, `Scripts/harness/check.mjs` |
| 세션 간 메모리 검토 | `.agents/skills/memory-curation/SKILL.md` (근거·버전·범위를 고정한 별도 검토) |
| 배포·리뷰·승인 | `.agents/skills/create-pr/SKILL.md`, `.agents/skills/trust-auto-merge/SKILL.md`, `docs/trust/auto-approval.md` |

Sources의 축약 파일명은 `Sources/MCAReasoning/` 기준이다. 이 지도는 파일 위치와
기존 정책으로 연결하며, 별도의 승인·테스트 정책을 만들지 않는다.
