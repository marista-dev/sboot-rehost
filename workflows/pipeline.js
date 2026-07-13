/*
 * pipeline.js — sboot-rehost 의 본 실행 파이프라인
 *
 * /sboot-rehost:rehost-sboot (트랙 1) 이 호출. INPUT.md 가 이미 있는 상태에서 시작.
 *
 * Phase 1 (병렬 멀티에이전트): 정적 분석 (bl3-analyzer + stub-locator 4 sub-task)
 * Phase 2 (직렬): 머신 .c 생성 + ninja
 * Phase 3 (직렬): 회차 루프 (iter-loop.js 위임)
 * Phase 4 (직렬): 5/5 검증
 * Phase 5 (직렬): 재현 키트
 *
 * args: {
 *   workdir, bl3_path, model, target,
 *   max_iterations: 30, time_budget_min: 240
 * }
 */

export const meta = {
  name: 'pipeline',
  description: 'sboot-rehost 본 파이프라인 — 정적 분석 (병렬) → 머신 → 회차 → 검증 → 재현 키트',
  phases: [
    { title: 'Static',   detail: 'bl3-analyzer + stub-locator 4 sub-task 병렬' },
    { title: 'Machine',  detail: 'machine.c 생성 + ninja' },
    { title: 'Iterate',  detail: 'iter-loop.js (회차 직렬)' },
    { title: 'Verify',   detail: '5/5 정직성 검증' },
    { title: 'Package',  detail: '재현 키트 생성' },
  ],
}

const workdir         = args?.workdir
const bl3_path        = args?.bl3_path
const model           = args?.model
const target          = args?.target ?? 'A'
const max_iterations  = args?.max_iterations ?? 30
const time_budget_min = args?.time_budget_min ?? 240

if (!workdir || !bl3_path || !model) {
  log('ERROR: pipeline.js requires args.workdir, args.bl3_path, args.model')
  return { error: 'missing_args' }
}

// =====================================================================
// Phase 1 — Static Analysis (병렬 멀티에이전트)
// =====================================================================
phase('Static')
log(`[Phase 1/5] Static analysis — bl3-analyzer + stub-locator (병렬)`)

const STATIC_SCHEMA = {
  type: 'object',
  properties: {
    carve_is_full: { type: 'boolean' },
    entry_offset:  { type: 'string' },
    linker_base:   { type: 'string' },
    load_base:     { type: 'string' },
    delta:         { type: 'string' },
    cmd_table:     { type: 'string' },
    cmd_list_head: { type: ['string', 'null'] },
    shell_func:    { type: ['string', 'null'] },
    num_cmds:      { type: ['integer', 'null'] },
    entry_format:  { type: ['object', 'null'] },
    undefined_count: { type: 'integer' },
  },
  required: ['carve_is_full', 'undefined_count'],
}

// 1A. bl3-analyzer 가 8 도출 일괄 수행
const static_result = await agent(
  `INPUT.md (${workdir}/INPUT.md) 와 BL3 (${bl3_path}) 를 분석.
   8 도출 (carve 판정, entry, linker_base, load_base, Δ, cmd_table,
   cmd_list_head, shell_func) 수행하고 STATIC.md 작성.
   정직성 §1~7 준수. 미확정은 "미확정" 으로.`,
  {
    agentType: 'bl3-analyzer',
    schema: STATIC_SCHEMA,
    label: 'bl3-analyzer',
    phase: 'Static',
  }
)

if (!static_result?.carve_is_full) {
  log(`★ critic 신호 4 — BL3 가 carve 같음. 진행 중단 권장.`)
  return { error: 'carve_suspected', static_result }
}

log(`bl3-analyzer 완료: ${static_result.undefined_count} 미확정 도출`)

// 1B. stub-locator 4 sub-task 병렬 (shell_func 필요)
const stubs = await parallel([
  () => agent(
    `STATIC.md 의 shell_func (${static_result.shell_func}) 안에서 콘솔 vtable
     base + 3 슬롯 (getchar/putchar/haschar) 오프셋 도출. capstone 디스어셈블
     근거 첨부. 미확정 시 "미확정".`,
    { agentType: 'stub-locator', label: 'vtable',  phase: 'Static',
      schema: { type: 'object', properties: { vtable_base: { type: ['string','null'] }, slots: { type: 'object' } } } }
  ),
  () => agent(
    `BL3 (${bl3_path}) 안에서 heap allocator entry 함수 (free-list traversal
     패턴) 도출. 함수 시작 주소 + capstone 근거. 미확정 시 "미확정".`,
    { agentType: 'stub-locator', label: 'heap',    phase: 'Static',
      schema: { type: 'object', properties: { heap_alloc_addr: { type: ['string','null'] } } } }
  ),
  () => agent(
    `BL3 entry 첫 0x100 안에서 BL2→BL3 핸드오프 매직 (addr, value) 페어들
     도출. ldr literal / cmp #magic 패턴. 미확정 시 빈 리스트.`,
    { agentType: 'stub-locator', label: 'handoff', phase: 'Static',
      schema: { type: 'object', properties: { magic_pairs: { type: 'array' } } } }
  ),
  () => agent(
    `STATIC.md 의 shell_func 안에서 getline timeout 분기 (b.ls/b.gt + cntpct
     비교) 도출. 미확정 시 "회차 N 에서 fault 로 확정" 마킹.`,
    { agentType: 'stub-locator', label: 'timeout', phase: 'Static',
      schema: { type: 'object', properties: { timeout_branch: { type: ['string','null'] } } } }
  ),
])

const stubs_clean = stubs.filter(Boolean)
log(`stub-locator 완료: ${stubs_clean.length}/4 sub-task`)

// STUBS.md 통합
await agent(
  `다음 4 stub-locator 결과를 ${workdir}/STUBS.md 로 마크다운 통합.
   각 슬롯 + 디스어셈블 근거 + 미확정 사유.
   결과: ${JSON.stringify(stubs_clean)}`,
  { label: 'stubs-md', phase: 'Static' }
)

// critic 1 차 점검
const critic1 = await agent(
  `Static analysis 후 위기 5 신호 점검. workdir=${workdir}.
   특히 신호 3 (미확정 ≥ 5) + 신호 4 (carve) 우선.`,
  { agentType: 'critic', label: 'critic-static', phase: 'Static',
    schema: { type: 'object', properties: { triggered: { type: 'boolean' }, signal: { type: 'integer' }, message: { type: 'string' } } } }
)
if (critic1?.triggered) {
  log(`★ ${critic1.message}`)
  // 자율 기본: pipeline 은 계속 (신호는 log + skill 이 JOURNAL decision 기록).
  // 하드 블로커 (carve 의심) 는 아래 carve_suspected 조기 return 으로 이미 중단됨.
}

// =====================================================================
// Phase 2 — Machine .c 빌드
// =====================================================================
phase('Machine')
log(`[Phase 2/5] Machine .c 생성 + ninja 빌드`)

await agent(
  `templates/machine.c.tmpl 의 13 슬롯에 STATIC.md + STUBS.md + INPUT.md 값
   채워서 ${workdir}/06_machine/machine.c 작성.

   슬롯 매핑:
   - {{MODEL_LOWER}}, {{LOAD_BASE}}, {{LINKER_BASE}}, {{DELTA}},
     {{CMD_TABLE}}, {{CMD_HEAD}}, {{NUM_CMDS}}, {{SHELL_FUNC}},
     {{ENTRY_REDIRECT}}, {{HANDOFF_MAGIC_BLOCK}}, {{HEAP_STUB_BLOCK}},
     {{VTABLE_BLOCK}}, {{SHELL_MODE_BLOCK}}, {{TRAMPOLINE_BLOCK}},
     {{CMD_RELOC_BLOCK}}, {{ENV_RELOC_BLOCK}}, {{CPU_BLOCK}}, ...

   그 후:
   1. ~/qemu-build/qemu-10.2.2/hw/arm/sboot_<MODEL_LOWER>.c 로 복사
   2. hw/arm/meson.build 의 arm_ss.add(files() 블록에 등록
   3. cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64
   4. 빌드 에러 시 그대로 보고 (추측 수정 금지)
   5. qemu-system-aarch64 -M help | grep sboot- 로 등록 확인`,
  { label: 'machine-build', phase: 'Machine' }
)

// =====================================================================
// Phase 3 — Iteration Loop (직렬, iter-loop.js 위임)
// =====================================================================
phase('Iterate')
log(`[Phase 3/5] 회차 루프 시작 (max ${max_iterations} 회차)`)

const iter_result = await workflow('iter-loop', {
  n: max_iterations,
  workdir,
  machine_name: `sboot-${model.toLowerCase().replace(/[^a-z0-9]/g, '')}`,
  bl3: bl3_path,
  cmd: 'help',
})

log(`회차 루프 완료: ${iter_result.iterations_run} 회차, ` +
    `reached_shell=${iter_result.reached_shell}`)

if (!iter_result.reached_shell) {
  log(`★ 셸 미도달. 최대 회차 ${max_iterations} 초과.`)
  return {
    error: 'max_iterations_exceeded',
    iter_result,
    next: '/sboot-rehost:rehost-sboot 재호출 시 회차 추가 진행 옵션 제공',
  }
}

// =====================================================================
// Phase 4 — 5/5 Verification
// =====================================================================
phase('Verify')
log(`[Phase 4/5] 5/5 정직성 검증`)

const verify = await agent(
  `${workdir} 의 가장 최근 07_logs/console_*.txt 와 06_machine/machine.c 를
   Table G 5/5 로 검증. byte-match (BL3 ${bl3_path} 와) + 소스 negative +
   PC 트레이스 + UART 단일 경로 + 우회 목록. VERIFICATION.md 작성.`,
  {
    agentType: 'reality-verifier',
    label: 'verify-5of5',
    phase: 'Verify',
    schema: {
      type: 'object',
      properties: {
        passes: { type: 'integer' },
        verdict: { type: 'string' },
        failed_items: { type: 'array' },
      },
      required: ['passes', 'verdict'],
    },
  }
)

log(`검증 결과: ${verify?.passes ?? '?'}/5 (${verify?.verdict ?? 'unknown'})`)

if (!verify || verify.passes < 5) {
  return {
    phase_completed: 'Verify',
    verify,
    note: 'FORCED 또는 미완. 자율 기본: FORCED 로 마무리 (REAL 금지). interactive 면 skill 이 선택 요청.',
  }
}

// =====================================================================
// Phase 5 — Reproduce Kit
// =====================================================================
phase('Package')
log(`[Phase 5/5] 재현 키트 생성`)

await agent(
  `${workdir}/10_reproduce/ 폴더 생성. 다음 포함:
   - README.md (INPUT.md 정보 + 빌드/실행 가이드)
   - bl3/<bl3 파일 복사>
   - machine/machine.c (현재 06_machine/machine.c 복사)
   - scripts/01_setup_env.sh (플러그인 scripts/setup_env.sh 복사)
   - scripts/02_build.sh (machine.c → QEMU 통합 + ninja)
   - scripts/03_run.sh (qemu 실행 + EXPECTED_OUTPUT diff)
   - evidence/EXPECTED_OUTPUT.txt (현재 console 복사)
   - evidence/VERIFICATION.md (5/5 결과 복사)`,
  { label: 'package-repro', phase: 'Package' }
)

return {
  success: true,
  verify,
  iter_result,
  reproduce_dir: `${workdir}/10_reproduce/`,
}
