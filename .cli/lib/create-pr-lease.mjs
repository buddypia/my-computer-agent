/**
 * create-pr-lease.mjs — `.tmp/create-pr-active` 판정 SSOT
 *
 * 배경 (실증된 결함, 2026-08-23): `/create-pr` 가 SIGKILL 로 죽어 남긴 플래그 파일 하나가
 * **3일간** main 직접 커밋 차단을 무력화하고 있었다. 실제 hook 에 페이로드를 주입해 확인:
 *   - 유물 플래그 존재 → `commit-guard` 가 `{}` (passthrough)
 *   - 같은 페이로드, 플래그 제거 → `deny`
 *
 * 근본 원인: 이 파일은 **시한부 권한(lease)** 인데 소비자 4곳이 3가지로 읽고 있었다.
 *   - `worktree-shipping-guard`: `isFresh(flag, CREATE_PR_ACTIVE_TTL_MS)` — TTL 준수
 *   - `destructive-git-guard`:   자체 `isFreshCreatePrFlag` + TTL 상수 **중복 정의** — TTL 준수
 *   - `commit-guard`:            `existsSync(flag)` — 영구 플래그로 오독
 *   - `worktree-session-owner-guard`: `existsSync(flag)` — 영구 플래그로 오독
 *
 * trunk-branch.mjs 와 같은 병이다(하나의 개념이 여러 hook 에 제각기 구현 → 일부만 작동 →
 * 사용자는 보호받고 있다고 믿는다). 같은 처방을 쓴다: 단일 진입점 + 전 호출부 전환 +
 * `tests/unit/create-pr-lease-ssot.test.mjs` 의 재발 차단 스캔.
 *
 * **왜 TTL 이 정답인가**: 종료 시 정리(trap/finally)는 SIGKILL 을 못 덮는다 — 이번 유출이
 * 정확히 그 경우였다. 임대는 프로세스 생사와 무관하게 스스로 만료하므로 정리 실패가
 * 영구 구멍이 되지 않는다.
 *
 * **왜 30분인가**: 새 숫자가 아니라 기존 두 구현이 이미 쓰던 값을 그대로 승격했다.
 * ship 1회(전체 게이트 약 10분)를 여유 있게 덮으면서, 유출 시 노출 창을 제한한다.
 *
 * R-CM-028 경계: boundary-uniform. 관점 2 는 `.cli/` 를 import 할 수 없어
 * `project-scaffolder/templates/scripts/lib/create-pr-lease.mjs` 에 독립 사본을 두고,
 * 동작 동등성은 위 테스트가 강제한다 (trunk-branch.mjs 와 동일한 관행).
 */
import { existsSync, statSync } from 'node:fs';
import { join } from 'node:path';

/** 임대 유효 기간. 기존 두 hook 구현이 각자 정의하던 값을 단일화한 것. */
export const CREATE_PR_ACTIVE_TTL_MS = 30 * 60 * 1000;

/** 임대 파일 경로. 경로 리터럴이 흩어지면 오타가 조용한 무동작이 된다. */
export function createPrLeasePath(projectDir) {
  return join(projectDir || '', '.tmp', 'create-pr-active');
}

/**
 * 임대가 아직 유효한가. 부재·만료·stat 실패는 모두 false —
 * 판정 불능일 때 가드를 여는 쪽으로 기울지 않는다 (fail-safe: 의심스러우면 보호한다).
 */
export function isCreatePrLeaseActive(projectDir, { now = Date.now() } = {}) {
  const path = createPrLeasePath(projectDir);
  try {
    if (!existsSync(path)) return false;
    return now - statSync(path).mtimeMs <= CREATE_PR_ACTIVE_TTL_MS;
  } catch {
    return false;
  }
}
