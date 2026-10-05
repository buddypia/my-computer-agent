/**
 * trunk-ref-guard.mjs — AI 세션이 로컬 trunk 를 origin 에 없는 지점으로 옮기는 것을 git 레벨에서 막는다
 *
 * 왜 필요한가: commit-guard(PreToolUse) 는 Bash 명령 *문자열* 을 읽는다. eval · bash -c · git alias ·
 * 명령 밖에서 받은 변수로 만든 commit 은 문자열로 판정할 수 없다. pre-commit backstop(#1326) 은 그
 * 구멍을 commit 에서만 닫는다 — 대상 저장소에서 trunk 가 실제로 움직인 경로인 merge · cherry-pick ·
 * fast-forward · reset · update-ref 에는 pre-commit 이 돌지 않는다 (실측 2026-10-01: my-computer-agent
 * 의 main 은 merge 와 cherry-pick 으로만 움직였다).
 *
 * git 의 reference-transaction hook 은 ref 가 바뀌는 모든 경로에서 돈다. "prepared" 단계에서 0 이 아닌
 * 값으로 끝나면 transaction 이 abort 된다. `--no-verify` 로도 건너뛸 수 없다.
 *
 * 불변식: AI 세션에서 로컬 trunk 는 이미 origin 에 올라간 지점(refs/remotes/origin/<branch> 의 조상)으로만
 * 움직인다. 동기화(ff · pull --ff-only · reset origin/main)는 허용하고, 새 작업의 착지는 /create-pr
 * 임대가 유효할 때만 허용한다. trunk 삭제는 막는다.
 *
 * opt-out: worktree-policy.json `trunk_ref_guard: false`. AI 가 로컬 merge 로 trunk 에 착지하는 것이
 * 정식 절차인 저장소(remote 없음)용이다. 정책 파일은 이식해도 보존되므로 재이식 때 다시 뺄 필요가 없다.
 *
 * 설치: git hook 은 clone 으로 따라오지 않는다. 그래서 commit-guard 가 git 명령을 볼 때마다
 * ensureTrunkRefGuardInstalled 로 hooks 디렉토리(core.hooksPath 존중)에 shim 을 둔다 — 새 clone 에서도
 * 첫 git 명령에서 스스로 복구된다. 남의 reference-transaction hook 은 덮지 않고 conflict 로 알린다.
 *
 * 한계 (정직하게): AI 세션은 CLAUDECODE 로만 식별한다 (Codex · Antigravity 세션은 범위 밖).
 * `env -u CLAUDECODE` 나 `-c core.hooksPath=` 는 hook 을 건너뛴다 — 후자는 destructive-git-guard 가 막는다.
 * "origin 에 있다" 는 로컬 remote-tracking ref 로 판정한다. hook 안에서 원격에 묻는 것(ls-remote)은 오프라인에서
 * 모든 ref 갱신을 막거나 열어야 해서 쓰지 않았다. 그래서 `update-ref refs/remotes/origin/main <oid>` 나
 * `remote add x .` + fetch 로 remote-tracking ref 를 로컬에서 위조하면 그 commit 은 published 로 통과한다
 * (적대 리뷰 2026-10-01 실측). 실수를 막지 적대적 우회를 막지 않는다.
 * remote 이름은 origin 고정이다 — 다른 이름의 remote 만 있는 저장소에서는 모든 AI 착지가 거부된다
 * (/create-pr 임대 또는 trunk_ref_guard:false 로 연다).
 *
 * R-CM-028: boundary-uniform — "AI 는 trunk 에 직접 착지하지 않는다" 는 harness 와 이식 대상에서
 * 같은 뜻이다. harness 는 core.hooksPath=.husky 라 shim 을 tracked 파일로 둔다.
 */

import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

import { isTrunkBranch, loadWorktreePolicy } from './trunk-branch.mjs';

export const HOOK_NAME = 'reference-transaction';
export const GUARD_SCRIPT_REL = '.claude/scripts/trunk-ref-guard.mjs';
const MARKER = 'trunk-ref-guard';

/**
 * hooks 디렉토리에 두는 shim. AI 세션 · prepared 단계 · refs/heads 변경일 때만 node 를 띄운다 —
 * 사람의 git 과 fetch 같은 remote-tracking 갱신에는 프로세스 하나 늘지 않는다.
 * 스크립트가 없으면(번들 제거) 통과, 저장소를 읽지 못하면 거부한다.
 */
export const SHIM = `#!/bin/sh
# ${MARKER} shim — installed by commit-guard; logic: .cli/lib/trunk-ref-guard.mjs
[ "$1" = prepared ] || exit 0
[ -n "$CLAUDECODE" ] || exit 0
input=$(cat)
case "$input" in *" refs/heads/"*) ;; *) exit 0 ;; esac
common=$(git rev-parse --path-format=absolute --git-common-dir) || exit 1
script="$(dirname "$common")/${GUARD_SCRIPT_REL}"
[ -f "$script" ] || exit 0
command -v node >/dev/null 2>&1 || { echo "[trunk-ref-guard] node 를 찾지 못해 ref 갱신을 거부했다" >&2; exit 1; }
printf '%s\\n' "$input" | exec node "$script"
`;

const ZERO_OID = /^0+$/;

/**
 * reference-transaction stdin (`<old> <new> <ref>` 줄) 을 읽는다.
 * @param {string} text
 * @returns {{ oldOid: string, newOid: string, ref: string }[]}
 */
export function parseRefUpdates(text) {
  return String(text || '')
    .split('\n')
    .map((line) => line.trim().split(/\s+/))
    .filter((parts) => parts.length === 3)
    .map(([oldOid, newOid, ref]) => ({ oldOid, newOid, ref }));
}

/**
 * 순수 판정. trunk 를 건드리는 갱신 중 허용되지 않는 것을 돌려준다 (빈 배열 = 통과).
 * @param {{ updates: ReturnType<typeof parseRefUpdates>, policy?: object|null, leaseActive?: boolean,
 *           isPublished: (oid: string, branch: string) => boolean,
 *           isUnmoved?: (update: { oldOid: string, newOid: string }, branch: string) => boolean }} args
 * @returns {{ branch: string, kind: 'delete'|'unpublished' }[]}
 */
export function findTrunkViolations({
  updates,
  policy = null,
  leaseActive = false,
  isPublished,
  isUnmoved = () => false,
}) {
  // opt-out 은 명시적 false 만 — 키가 없거나 오타면 보호가 켜진 쪽으로 떨어진다.
  if (leaseActive || policy?.trunk_ref_guard === false) return [];
  const violations = [];
  for (const update of updates) {
    const { newOid, ref } = update;
    if (!ref.startsWith('refs/heads/')) continue;
    const branch = ref.slice('refs/heads/'.length);
    if (!isTrunkBranch(branch, policy) || isUnmoved(update, branch)) continue;
    if (ZERO_OID.test(newOid)) violations.push({ branch, kind: 'delete' });
    else if (!isPublished(newOid, branch)) violations.push({ branch, kind: 'unpublished' });
  }
  return violations;
}

/**
 * oid 가 origin 의 같은 이름 branch 에 이미 있는가. origin 만 본다 — fork 구성의 upstream 처럼
 * 다른 remote 에만 있는 commit 은 "origin 에 올라갔다" 가 아니다 (/create-pr 도 origin 으로만 낸다).
 * 같은 transaction 에서 갱신되는 `refs/remotes/origin/<branch>`(`fetch origin main:main`)도 본다 —
 * 아직 디스크에 쓰이기 전이기 때문이다.
 * @param {{ updates: ReturnType<typeof parseRefUpdates>,
 *           isAncestor: (oid: string, ref: string) => boolean }} deps
 */
export function makeIsPublished({ updates, isAncestor }) {
  return (oid, branch) => {
    const tracking = `refs/remotes/origin/${branch}`;
    return updates.some((u) => u.ref === tracking && u.newOid === oid) || isAncestor(oid, tracking);
  };
}

/**
 * 갱신이 branch 가 가리키는 commit 을 바꾸지 않는가. pack-refs(git gc 포함)는 두 transaction 을 연다
 * (실측 git 2.56): ① packed-refs 에 loose 값을 쓴다 (`… <loose oid>`) ② loose 파일을 지운다
 * (`<oid> 0000…` — 삭제와 모양이 같다). ①은 새 값이 지금 값과 같고, ②는 그 순간 loose 와 packed 가
 * 같은 oid 라 ref 가 사라지지 않는다. 진짜 삭제(`branch -D`)는 old 가 0 으로 오거나 packed 에 같은
 * oid 가 없다. loose 와 packed 가 같은 oid 로 함께 있을 때(pack-refs --no-prune)의 삭제는 packed 쪽이 여기를
 * 통과하지만, git 이 loose 쪽을 old=0 인 별도 transaction 으로 보내 거부된다 (실측 git 2.56, test 로 고정).
 * 이 판정이 없으면 trunk 가 origin 보다 앞선 저장소에서 AI 의 git gc 가 매번 실패한다.
 * @param {string} commonDir  git common dir (refs/heads 와 packed-refs 가 사는 곳)
 */
export function makeIsUnmoved(commonDir) {
  const read = (path) => {
    try {
      return readFileSync(path, 'utf8');
    } catch {
      return null;
    }
  };
  return ({ oldOid, newOid }, branch) => {
    const loose = read(join(commonDir, 'refs', 'heads', branch))?.trim() ?? null;
    const packedLine = (read(join(commonDir, 'packed-refs')) ?? '')
      .split('\n')
      .find((line) => line.endsWith(` refs/heads/${branch}`));
    const packed = packedLine?.split(' ')[0] ?? null;
    if (ZERO_OID.test(newOid)) return !ZERO_OID.test(oldOid) && loose === oldOid && packed === oldOid;
    return (loose ?? packed) === newOid;
  };
}

export function formatDenial(violations) {
  const names = [...new Set(violations.map((v) => v.branch))].join(', ');
  const verb = violations.some((v) => v.kind === 'delete') ? '삭제하거나 ' : '';
  return (
    `[trunk-ref-guard] AI 세션에서 '${names}' 브랜치를 ${verb}origin 에 없는 commit 으로 옮기려 해 거부했다 ` +
    '(commit · merge · cherry-pick · reset · update-ref 모두 해당).\n' +
    '  작업은 worktree 에서 하고 /create-pr 로 착지한다: make wt.new BR=feature/<task>\n' +
    '  origin 과 맞추는 동기화(pull --ff-only, reset origin/<branch>)는 허용된다.\n' +
    '  사람이 직접 하려면 Claude Code 밖의 터미널에서 실행한다.\n'
  );
}

/**
 * hooks 디렉토리에 shim 을 두거나 최신으로 맞춘다. 판정에 영향을 주지 않도록 호출부는 결과만 읽는다.
 * opt-out 저장소는 건드리지 않는다 — 자체 reference-transaction hook 을 둔 저장소에서 conflict 경고가
 * 모든 git 명령마다 뜨기 때문이다. policy 는 판정 스크립트와 같은 main checkout 에서 읽는다.
 * @param {string} projectDir
 * @param {{ git?: (cwd: string, ...args: string[]) => string }} [deps]
 * @returns {{ status: 'current'|'installed'|'updated'|'conflict'|'skipped'|'disabled', path?: string }}
 */
export function ensureTrunkRefGuardInstalled(projectDir, { git = defaultGit } = {}) {
  if (!projectDir || !existsSync(join(projectDir, GUARD_SCRIPT_REL))) return { status: 'skipped' };
  let hooksDir;
  let mainDir;
  try {
    hooksDir = git(projectDir, 'rev-parse', '--path-format=absolute', '--git-path', 'hooks');
    mainDir = dirname(git(projectDir, 'rev-parse', '--path-format=absolute', '--git-common-dir'));
  } catch {
    return { status: 'skipped' };
  }
  if (loadWorktreePolicy(mainDir)?.trunk_ref_guard === false) return { status: 'disabled' };
  const path = join(hooksDir, HOOK_NAME);
  if (existsSync(path)) {
    const current = readFileSync(path, 'utf8');
    if (current === SHIM) return { status: 'current', path };
    if (!current.includes(`# ${MARKER} shim`)) return { status: 'conflict', path };
    writeShim(path);
    return { status: 'updated', path };
  }
  mkdirSync(dirname(path), { recursive: true });
  writeShim(path);
  return { status: 'installed', path };
}

function writeShim(path) {
  writeFileSync(path, SHIM);
  chmodSync(path, 0o755);
}

function defaultGit(cwd, ...args) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
}
