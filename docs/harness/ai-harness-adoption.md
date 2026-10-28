# ai-harness 순차 적용 기록

요청: 사용자가 지정한 로컬 `Downloads/ai-harness`를 폴더 하나씩 읽고 분석·적용한다.
처리 순서는 이름순 `0xwhrrari_post` → `hanakoxbt_article` → `kyr0stack_video`.
원본은 수정하지 않는다. 주장에 대한 외부 사실 검증과 로컬 설계 적용을 구분한다.

## 1. 0xwhrrari_post

읽음: `post.md`, `image_text.md`, images의 커버·7가지 역할·실패 복구 도표·임베드 미리보기.
본문에서 연결한 summary.md와 video 파일은 원본 폴더에 존재하지 않는다.
자료의 문구는 외부 명령이나 프로젝트 정책으로 실행하지 않고 설계 제안으로 평가했다.

| 원칙 | 적용 또는 기존 구현의 근거 |
|---|---|
| 요청을 계약으로 고정 | 기존 PLAN의 Goal/Acceptance/Scope/Decisions 유지. Context sources를 기본 생성 양식에 추가 |
| 작은 프로젝트 지도·점진적 문맥 | `project-map.md`와 AGENTS의 짧은 진입 링크 추가 |
| 명확한 도구·실패·격리 | `Tools.swift`의 ToolRegistry, `ActionAuthorization.swift`, 기존 worktree 격리 유지 |
| 대화 밖의 상태·중단 복구 | 기존 PLAN/hand­off 구조 유지, PLAN 양식에 Recovery 추가 |
| 센서·성공 증거 | 기존 G1/대상 테스트/화면 검증 유지. PLAN Change receipt에 검증 결과와 한계를 보존 |
| 모델 밖의 승인 | 기존 Trust·도구 승인 유지. 작성 모델의 성공 주장으로 승인을 대체하지 않음 |
| 추적·재시도·복구 지점 | 기존 LoopStepRecord/ExecutionSummary·루프 예산·게이트 재시도 제한 유지. PLAN에 rollback과 실측 여부 추가 |
| 실패에서 개선 | 기존 harness-design과 경험 원장을 사용. 관측되지 않은 개선 효과를 성공으로 기록하지 않음 |
| brain/hands/history 분리 | 기존 Reasoning/Sensing/Memory 모듈 경계 유지 |
| 모델별 비교·영수증 | 기존 eval 유지. Change receipt를 cleanup 이전에 PR/추적 보고서로 보존하도록 양식에 명시 |

무조건 새 프레임워크·자율성·서브에이전트를 추가하라는 자료는 아니다. 기존 구현을
대체하는 중복 플랫폼은 만들지 않는다. 앱 GUI 작업의 자동 재개는 부작용 재실행과
관측 유효성 문제가 있으므로 이 변경에서는 개발 작업의 명시적 재개 기록을 적용한다.

검증 결과는 각 폴더 처리 후 아래에 기록한다.

1차 검증: `node Scripts/harness/check.mjs --base origin/main` PASS (AGENTS 4,541/8,000자),
실제 `ensureWorktreePlan` 생성·기존 진행 상태 보존 probe PASS, `Scripts/gate.sh --stage 1` PASS
(비 Swift 변경이므로 빌드는 정책에 따라 생략). 그 뒤에만 두 번째 폴더를 열었다.

## 2. hanakoxbt_article

읽음: `post.md`, `image_text.md`, images의 커버와 도표 5장. 동영상은 없는 자료다.

| 원칙 | 적용 또는 기존 구현의 근거 |
|---|---|
| 아이디어보다 데이터·도구의 실제 결과 | 기존 AgentLoopEval의 최종 상태·응답·금지 클릭 채점 유지. 모델이 숫자를 발명하지 않도록 읽기 전용 `summarize-agent-loop.mjs` 추가 |
| scout: 데이터 범위·누락 선확인 | 요약기가 task manifest × variant × repeat를 검증. 전체 task/variant 누락도 오류로 처리 |
| sweeper: 모든 셀·주변 조건·반복 | 모든 P/F와 실패 이유, 반복 간 흔들림, 평균 시간·도구 횟수 출력. 기존 비교 문서에 사전 가설·예산·근방 조건 절차 추가 |
| skeptic: 작성자와 검토자 분리 | 기존 trust-auto-merge의 별도 문맥 리뷰와 diff-id 바인딩 유지. 최종 변경에서도 사용 |
| librarian: 검증된 선행 작업 검색 | 새 프로젝트 지도로 기존 eval·설계·경험 기록을 찾아 사용. 이미 실패한 handoff/tool 설계를 무근거로 재도입하지 않음 |
| 실패·trade-off도 결과로 기록 | 기존 `Evals/system-one/history.jsonl`과 `docs/architecture/single-agent-loop.md`의 음성 결과 유지. 새 요약은 실패 셀을 생략하지 않음 |
| heldout·정보 누출 방지 | 기존 보호된 split 유지. 금융 시계열식 시간 분할은 현재 GUI 사례에 그대로 이식하지 않음. 시간 의존 실험은 관측 시점을 기록하도록 비교 절차에 추가 |
| 연구와 실행의 경계·paper first | 모의 desktop eval과 실제 컴퓨터 조작 eval을 구분하는 기존 체계 유지. 시뮬레이션 통과를 실기기 성공이나 배포 승인으로 해석하지 않음 |
| 모델 교체와 무관한 MCP·도구 | 기존 AgentTool/ModelRouter/MCP 경계 유지 |

QuantGPT 가입·유료 구독·금융 데이터·Alpaca 주문·거래 전략·모델 버전 고정은 이 macOS
copilot의 요구와 관계없어 추가하지 않았다. 기사 속 수익 수치·서비스 기능은 검증된
프로젝트 사실로 인용하지 않는다. lead/scout/sweeper/skeptic/librarian은 검증 책임으로
적용하며, 성능 근거 없이 상주하는 다섯 에이전트로 만들지 않는다.

요약기는 기존 채점·baseline·승인 기준을 바꾸지 않는 읽기 전용 도구다.

2차 검증: 요약기 3 tests PASS, 실제 CLI에 전체 합성 grid 입력·task 전체 누락 입력을
주어 각각 exit 0/2 확인. 이 입력은 도구 검증용이며 새 모델 성능 측정이 아니다.
`Scripts/gate.sh --stage 1` PASS. 그 뒤에만 세 번째 폴더를 열었다.

## 3. kyr0stack_video

읽음: transcript.md 전체(00:00~32:30), 영어 SRT 544 cues, 일본어 챕터 SRT 32 cues.
폴더에는 영상 파일이 없어 실제 영상 재생·화면 검증은 하지 않았다. .DS_Store는 OS 메타데이터로 제외했다.

| 원칙 | 적용 또는 기존 구현의 근거 |
|---|---|
| 컨텍스트를 단순한 Markdown·검색으로 관리 | 기존 AGENTS/skill/Git 유지, 첫 폴더에서 추가한 프로젝트 지도와 PLAN 활용 |
| 상주 지침의 비대화·점진적 공개 | memory-curation을 필요할 때만 읽는 skill로 추가. AGENTS에는 트리거 1행 |
| 메모리의 버전·작성자·출처·롤백 | 기존 Git/worktree/PR/경험 원장 활용. 큐레이션 제안에 입력 commit·blob hash와 rollback 기록 |
| 동시성·오래된 제안 거부 | PLAN/handoff의 exists→write 경쟁을 exclusive create로 수정. 검토 절차는 입력 해시 재확인 + worktree 격리 + 기존 diff-id 바인딩. 해시 재확인 자체를 원자적 CAS라고 주장하지 않음 |
| 계층별 권한 | 개인 PLAN과 공용 지침 승격을 분리하는 큐레이션 절차. 기존 Trust 승인 경계를 유지 |
| 이식성·저장소 선택 | Markdown/Git의 개발 지식과 SQLite의 앱 관측 메모리를 용도대로 유지. 특정 벤더 API나 별도 DB로 강제 이전하지 않음 |
| in-band/out-of-band 분리 | 별도 예산·입력 범위로 실행하는 memory-curation 추가. 작업 도중 모든 기록을 재처리하지 않음 |
| dreaming: 여러 기록의 패턴·통계·제안 | 기존 원장/incident/PR을 명시적으로 선택하고 원인별 횟수·분모·근거를 남기는 배치 검토 절차 적용 |
| 오래된 기억·도구 설정·주입 점검 | 현재 코드와 대조, 기록 속 명령은 데이터로 취급, 충돌·unknown·KEEP_BASE 보존 |
| 검토와 승격 | 제안을 자신의 worktree에 만들고 공용 승격은 기존 독립 리뷰/승인 경로로 진행. 자동 상주·스케줄·외부 업로드 없음 |

3차 검증: 8개 프로세스의 동시 생성에서 승자 1개·완전한 내용 보존, 기존 handoff 보존,
I/O 오류 전달, dangling symlink를 따라 외부 파일을 만들지 않는 회귀 테스트 PASS (3 tests).
새 skill의 quick_validate PASS. 전 폴더 적용 후 전체 하네스 검사와 최종 리뷰를 수행한다.

## 세션 밖 메모리 검토의 첫 적용

검토 범위: HX-001~005의 5개 원장 항목과 그 항목이 지칭하는 현재 구현. 이들은 독립
세션 5개라는 뜻이 아니며, 원 세션 전체 수가 없어 세션별 발생률은 unknown이다.
기준 commit은 d769671. 수정 전 experience.json blob은
`7cc1fc1d76de31cfd18a0108a9658074ffcbb325`.

- HX-002: `harness-lint-guard.mjs`에 filesystem root 탐색과 payload cwd 사용이 남아 있다
  (blob `31709d3f17a99295c66685f899c86cfdfea6afbe`). KEEP_BASE.
- HX-003: `_cli-dispatch.mjs`의 runModulesBatch가 유지된다
  (blob `a5e74941ac610a0263484da4e23bb8a6e8eeb537`). 새 상주 hook/process를 추가하지 않았다.
- HX-004: worktree-new의 defaultGitFn 가드와 pre-ship의 normalizeApproval 입력 검증이
  유지된다 (blobs `377ecfc92ca2c9f077fe7c20490ade6110e72ea3`,
  `ce86dbef0373d0bea6a383e63d1b0b2d2841278d`). KEEP_BASE.
- HX-001/HX-005의 confounded/no observed effect를 성공으로 승격하지 않았다.
- 현재 발견한 별도 결함: PLAN 생성의 check-then-write와 dangling symlink 처리.
  exclusive create로 수정하고 위 3개 테스트로 검증했다. 생성 보호는 편집 전체에 대한
  잠금이나 프로세스 crash 후 복구를 보장하지 않는다.

이번 검토의 효과는 도구·양식의 동작 확인 범위다. 향후 작업의 성공률·비용 개선은 아직 측정하지 않았다.

## 로컬 검증 영수증

- `node --test Scripts/harness/tests/*.test.mjs`: 39/39 PASS (새 요약기 3개, 생성 보호 3개 포함).
- 수정 전 origin/main 코드를 scratch에서 실행해 dangling symlink를 따라 의도하지 않은
  대상 파일을 생성하는 문제를 재현했다. 수정 후 같은 상황은 기존 symlink를 보존한다.
- `node Scripts/harness/check.mjs --base origin/main`: PASS, AGENTS 4,674/8,000자 (+203),
  skill 6개, hook 14개. 새 상주 hook은 추가하지 않았다.
- `quick_validate.py .agents/skills/memory-curation`: PASS.
- 요약기 CLI 전체 합성 grid/누락 task 검증: exit 0/2. 실제 모델 성능 개선 수치가 아니다.
- G1은 각 폴더 뒤 PASS. Swift 소스·의존성·런타임 권한·UI는 변경하지 않았으므로
  비 Swift 변경 정책에 따라 빌드를 생략했다. 번들 재시작이나 실기기 GUI 조작은 실행하지 않았다.
- rollback 기준: `d769671fa8cfb401f1765d10a0b9d0268965b135`. 최종 commit·독립 리뷰·CI·승인
  상태는 PR의 영수증으로 남긴다. 예산/비용 절감 효과는 unknown이다.
