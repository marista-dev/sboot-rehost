/*
 * pipeline.js - unified sboot-rehost execution pipeline (tracks 1 and 2).
 *
 * The track is an argument, not an identity. One skeleton runs both; only the
 * goal ladder, the knowledge tables and the run script change.
 *
 *   [static-analyzer] derive facts
 *        |
 *   +-- LOOP (per goal) --------------------------------------------------+
 *   | (run_round.sh) snapshot + run + fingerprint + provenance gate +      |
 *   |                stop conditions, merged into ONE observation document |
 *   | [supervisor]            -> routing / stop                            |
 *   |   |- goal reached  -> next rung or verification                      |
 *   |   |- stop          -> structurally unreachable                       |
 *   |   |- escalate      -> [static-analyzer] re-derive                    |
 *   |   +- otherwise     -> [fault-classifier] -> [fixer] one change       |
 *   |                       -> (check_change verify) -> (ninja)            |
 *   +---------------------------------------------------------------------+
 *        |
 *   (verify.py stage 1) -> [verifier stage 2] -> REAL | FORCED
 *
 * Goal advancement is decided by MEASUREMENT, not by the supervisor's claim:
 * only a milestone that the run script observed (and that passed the
 * provenance gate) moves the ladder forward.
 *
 * Round count and elapsed time are never stop reasons. runtime_round_cap is a
 * runtime limit, not a verdict, and the run resumes where it left off.
 *
 * args: {
 *   workdir, track (1|2), target, model, plugin_dir,
 *   bootloader_path     (track 1; bl3_path also accepted),
 *   soc_family, arch, bl_surface, has_super,
 *   runtime_round_cap   (default 120 - runtime limit, not a stop reason),
 * }
 */

export const meta = {
  name: 'pipeline',
  description: 'sboot-rehost 통합 파이프라인 — 도출 → 빌드 → (실행·분류·수정)* → 5/5 검증 → 키트',
  phases: [
    { title: 'Analyze', detail: 'static-analyzer 사전 도출 (하드 블로커 검사)' },
    { title: 'Build',   detail: 'machine 소스 생성 + ninja' },
    { title: 'Loop',    detail: '목표 사다리마다 실행 → 분류 → 한 변경' },
    { title: 'Verify',  detail: 'verify.py 측정 → verifier 재검증' },
    { title: 'Package', detail: '재현 키트' },
  ],
}

// --- arguments ---------------------------------------------------------------
const workdir   = args?.workdir
const track     = Number(args?.track ?? 1)
const model     = args?.model
// bl3_path is the pre-0.10 name. BL3 is ARM/Exynos wording and reads wrong for a
// MediaTek LK image, so the slot is bootloader_path now; both are accepted.
const bootloader_path = args?.bootloader_path ?? args?.bl3_path
const target    = String(args?.target ?? (track === 1 ? 'A' : 'K2')).toUpperCase()
const socFamily = String(args?.soc_family ?? 'generic').toLowerCase()
const arch      = String(args?.arch ?? 'arm64').toLowerCase()
const PLUGIN    = args?.plugin_dir ?? '${CLAUDE_PLUGIN_ROOT}'
const ROUND_CAP = Number(args?.runtime_round_cap ?? 120)

// The bootloader's interactive surface is what track 1 actually targets. A UART
// shell is only one kind: MediaTek LK has an output-only UART, so its reachable
// surface is fastboot over USB. Undeclared means static-analyzer decides.
const SURFACES = ['shell', 'fastboot']
const declaredSurface = String(args?.bl_surface ?? '').toLowerCase()
const surface = SURFACES.includes(declaredSurface) ? declaredSurface : 'shell'
const surfaceDeclared = SURFACES.includes(declaredSurface)

if (!workdir || !model) {
  log('오류: pipeline.js 는 args.workdir 와 args.model 이 필요합니다.')
  return { error: 'missing_args' }
}
if (track === 1 && !bootloader_path) {
  log('오류: 트랙 1 은 args.bootloader_path (구 bl3_path) 가 필요합니다.')
  return { error: 'missing_bootloader_path' }
}

const slug = model.toLowerCase().replace(/[^a-z0-9]/g, '')
const machine = track === 1 ? `${slug}-bootloader` : `${slug}-kernel`

// The ladder is what the track/grade actually changes; the loop stays the same.
//
// K3 is the point of track 2: driving a real vendor UFS controller until the
// kernel enumerates partitions. The methodology sets minimum completion at
// `partitions_up` (K3a); `super_mounted` is the capstone (K3b) and only exists
// for firmware that ships a super image. Firmware with separate system/vendor
// raw partitions can never print it, so keeping it in the ladder unconditionally
// would strand such a run short of a goal it cannot reach by construction.
const hasSuper = args?.has_super === true
const LADDERS = {
  // Track 1's rung is the interactive surface, not "shell" by assumption.
  1: { A: [surface], B: [surface], C: [surface] },
  2: {
    K1: ['userspace'],
    K2: ['userspace', 'rootfs'],
    K3: ['userspace', 'link_up', 'power_mode', 'scsi_attach', 'partitions_up']
          .concat(hasSuper ? ['super_mounted'] : []),
  },
}
const goals = (LADDERS[track] || {})[target] || LADDERS[1].A
const ladderArg = goals.join(',')
const KNOWN_FIXERS = ['fixer-memory', 'fixer-el3', 'fixer-bootflow',
                      'fixer-kernel', 'fixer-storage']

// --- helpers -----------------------------------------------------------------

/* Quote arbitrary text for bash.
 * Agent-authored strings (rationale, descriptions) end up inside shell commands.
 * Interpolating them raw lets a backtick or $(...) execute, so everything goes
 * through single quotes with the only dangerous character escaped. */
function shq(value) {
  const text = String(value ?? '').replace(/[\r\n\t]+/g, ' ').slice(0, 400)
  return "'" + text.replace(/'/g, "'\\''") + "'"
}

function shell(label, phaseName, command, schema) {
  return agent(
    'Run the following commands exactly as written and report their output ' +
    'against the schema.\n' +
    'Do not guess, do not repair, do not smooth over failures. If a command ' +
    'fails, report the failure verbatim.\n\n' +
    '```bash\n' + command + '\n```\n',
    { label, phase: phaseName, schema }
  )
}

function recordRoundCmd(round, goal, fp, category, fixer, changeKey, effect, analystFacts, noNewChange) {
  const fields = [
    `round=${round}`,
    `goal=${shq(goal)}`,
    `fp_exc=${Number(fp?.exceptions ?? 0)}`,
    `fp_far=${shq(fp?.far ?? 'none')}`,
    `fp_elr=${shq(fp?.elr ?? 'none')}`,
    `fp_milestone=${shq(fp?.milestone ?? 'none')}`,
    `fp_bytes=${Number(fp?.console_bytes ?? 0)}`,
    `category=${shq(category ?? 'none')}`,
    `fixer=${shq(fixer ?? 'none')}`,
    `change_key=${shq(changeKey ?? 'none')}`,
    `effect=${shq(effect)}`,
    `analyst_new_facts=${Number(analystFacts)}`,
    `fixer_no_new_change=${noNewChange === true}`,
    `tokens_total=${budget.spent()}`,
  ].join(' ')
  return `python3 "${PLUGIN}/scripts/record.py" "${workdir}" round ${fields}`
}

function journalTryEnd(round, cause, analysis, fix, evidence) {
  return `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" try-end ${round} ` +
         `${shq(cause)} ${shq(analysis)} ${shq(fix)} ${shq(evidence)}`
}

const OK_SCHEMA = { type: 'object', properties: { ok: { type: 'boolean' } } }

// --- schemas -----------------------------------------------------------------
const ANALYST_SCHEMA = {
  type: 'object',
  properties: {
    mode: { type: 'string' },
    carve_is_full: { type: ['boolean', 'null'] },
    assets_ok: { type: ['boolean', 'null'] },
    bl_surface: { type: ['string', 'null'] },
    storage_driver: { type: ['object', 'null'] },
    undetermined_count: { type: 'integer' },
    new_facts_count: { type: 'integer' },
    facts: { type: 'array' },
    escalation_answer: { type: ['object', 'null'] },
  },
  required: ['new_facts_count'],
}

const RUN_SCHEMA = {
  type: 'object',
  properties: {
    run_ok: { type: 'boolean' },
    milestone: { type: 'string' },
    milestones_reached: { type: 'array' },
    injected: { type: 'boolean' },
    exceptions: { type: 'integer' },
    console_bytes: { type: 'integer' },
    far: { type: 'string' },
    elr: { type: 'string' },
    console: { type: 'string' },
    summary: { type: 'string' },
    trace: { type: 'string' },
    stop: { type: 'boolean' },
    stop_reason: { type: ['string', 'null'] },
    stall_count: { type: 'integer' },
    escalate_to_analyst: { type: 'boolean' },
    suspect_prior_bypass: { type: 'boolean' },
    best_milestone: { type: ['string', 'null'] },
  },
  required: ['milestone', 'stop'],
}

const SUPERVISOR_SCHEMA = {
  type: 'object',
  properties: {
    route: { type: 'string' },
    progress: { type: 'boolean' },
    stop_reason: { type: ['string', 'null'] },
    suspect_prior_bypass: { type: 'boolean' },
    decision_note: { type: 'string' },
  },
  required: ['route'],
}

const CLASSIFIER_SCHEMA = {
  type: 'object',
  properties: {
    category: { type: 'string' },
    confidence: { type: 'string' },
    milestone_reached: { type: ['string', 'null'] },
    evidence: { type: 'object' },
    novelty: { type: 'object' },
    fixer_ranking: { type: 'array' },
    escalation_request: { type: 'object' },
    note: { type: ['string', 'null'] },
  },
  required: ['category'],
}

const FIXER_SCHEMA = {
  type: 'object',
  properties: {
    fixer: { type: 'string' },
    not_mine: { type: 'boolean' },
    no_new_change: { type: 'boolean' },
    category: { type: 'string' },
    change: { type: ['object', 'null'] },
    change_key: { type: ['string', 'null'] },
    rationale: { type: 'string' },
    bypass_doc: { type: ['object', 'null'] },
    one_line_progress: { type: 'string' },
    escalate: { type: ['object', 'null'] },
  },
  required: ['fixer'],
}

const BUILD_SCHEMA = {
  type: 'object',
  properties: {
    build_ok: { type: 'boolean' },
    build_error: { type: ['string', 'null'] },
    machine_registered: { type: 'boolean' },
  },
  required: ['build_ok'],
}

const APPLY_SCHEMA = {
  type: 'object',
  properties: {
    gate_pass: { type: 'boolean' },
    gate_reason: { type: 'string' },
    build_ok: { type: 'boolean' },
    build_error: { type: ['string', 'null'] },
  },
  required: ['gate_pass', 'build_ok'],
}

const VERIFIER_SCHEMA = {
  type: 'object',
  properties: {
    script_passes: { type: 'integer' },
    final_passes: { type: 'integer' },
    final_verdict: { type: 'string' },
    override: { type: 'object' },
    failed_items: { type: 'array' },
    next_round_recommendation: { type: ['string', 'null'] },
  },
  required: ['final_passes', 'final_verdict'],
}

// =============================================================================
// Phase 1 - Analyze
// =============================================================================
phase('Analyze')
log(`[분석] 트랙 ${track} / 등급 ${target} — 목표 사다리: ${goals.join(' → ')}`)

const prior = await agent(
  `Run in mode=prior: derive every fact needed to build the machine model.\n` +
  `track=${track}, target=${target}, soc_family=${socFamily}, arch=${arch}\n` +
  `Input: ${workdir}/INPUT.md\n` +
  (track === 1 ? `Bootloader image: ${bootloader_path}\n` : `Boot assets: ${workdir}/fw/\n`) +
  `Profile hints: profiles/${socFamily}.yaml (hints about WHERE to look, never values)\n` +
  (arch === 'arm32'
    ? `This bootloader is AArch32/Thumb - disassemble with ` +
      `scripts/carve_disasm.py --arch arm32.\n`
    : '') +
  (track === 1
    ? `\nDERIVE THE INTERACTIVE SURFACE FIRST` +
      (surfaceDeclared ? ` (setup's hint: ${surface} - confirm or correct it)` : ' (no hint given)') +
      `.\nA command table existing in the binary does NOT mean it is reachable. Establish, ` +
      `as fact, whether an input path exists:\n` +
      `  - UART: does the driver have a receive path (RBR read / rx polling), or is it ` +
      `output-only?\n` +
      `  - USB: which dispatchers exist (fastboot, download/DA, vendor), and do any of them ` +
      `reference the console command table?\n` +
      `Report bl_surface as "shell", "fastboot", or "none" when no surface has an input path. ` +
      `"none" is a hard blocker - say so rather than inventing a route.\n`
    : '') + `\n` +
  `First record the phase:\n` +
  `  bash "${PLUGIN}/scripts/journal.sh" "${workdir}" phase "Analyze (static-analyzer prior)"\n` +
  `  python3 "${PLUGIN}/scripts/record.py" "${workdir}" start analyze\n\n` +
  (track === 1
    ? `Work through the track 1 checklist (carve verdict first) and write STATIC.md.`
    : `Work through the track 2 checklist (assets, DTB skeleton, security gate sites) ` +
      `and write KERNEL_STATIC.md.`) +
  `\nAnything you cannot derive stays "미확정" with a confirm plan. Never borrow ` +
  `values from another device or build.\n\n` +
  `Write STATIC.md / KERNEL_STATIC.md in natural Korean - the user reads them.\n\n` +
  `When finished:\n` +
  `  python3 "${PLUGIN}/scripts/record.py" "${workdir}" metric phase=Analyze ` +
  `event=analyze_end timer=analyze tokens_total=${budget.spent()}`,
  { agentType: 'static-analyzer', schema: ANALYST_SCHEMA, label: 'analyze', phase: 'Analyze' }
)

const blockers = []
if (track === 1 && prior?.carve_is_full === false) {
  blockers.push(['BLOCKED_CARVE', '부트로더 이미지가 carve 로 판정됨 (알려진 ASCII 부족)'])
}
if (track === 1 && String(prior?.bl_surface ?? '').toLowerCase() === 'none') {
  blockers.push(['BLOCKED_NO_INPUT_PATH',
                 '어느 표면에도 인터랙티브 입력 경로가 없음 — UART 는 출력 전용이고 ' +
                 '어떤 USB dispatcher 도 명령 테이블을 참조하지 않음'])
}
if (track === 2 && prior?.assets_ok === false) {
  blockers.push(['BLOCKED_ASSET', '부팅 자산을 확보하지 못함 (Image/DTB)'])
}

// static-analyzer may correct setup's surface hint; measurement wins over the hint.
const derivedSurface = String(prior?.bl_surface ?? '').toLowerCase()
if (track === 1 && SURFACES.includes(derivedSurface) && derivedSurface !== surface) {
  log(`[분석] 표면 정정: 힌트 "${surface}" → 도출 "${derivedSurface}". ` +
      `목표 사다리를 "${derivedSurface}" 로 바꿔 재실행하세요 ` +
      `(INPUT.md 의 bl_surface 갱신).`)
  return {
    success: false, stopped: true, stop_reason: 'SURFACE_CORRECTED',
    hinted_surface: surface, derived_surface: derivedSurface,
    note: `INPUT.md 의 bl_surface 를 "${derivedSurface}" 로 고치고 같은 명령을 다시 실행하면 ` +
          `그 표면을 목표로 진행합니다. 잘못된 표면으로 회차를 태우지 않기 위한 조기 종료입니다.`,
  }
}

if (blockers.length) {
  const [code, detail] = blockers[0]
  await shell('record-blocker', 'Analyze',
    `python3 "${PLUGIN}/scripts/record.py" "${workdir}" blocker code=${code} detail=${shq(detail)}\n` +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ${shq(`하드 블로커 ${code}: ${detail}`)}`,
    OK_SCHEMA)
  log(`★ 정지 — ${code}: ${detail}`)
  return {
    success: false, stopped: true, stop_reason: code, detail,
    note: '구조상 목표에 도달할 수 없습니다. 자산을 확보한 뒤 같은 명령을 다시 실행하면 이어서 진행됩니다.',
  }
}

log(`[분석] 완료 — 새로 확정한 사실 ${prior?.new_facts_count ?? 0} 개, 미확정 ${prior?.undetermined_count ?? 0} 개`)

// =============================================================================
// Phase 2 - Build
// =============================================================================
phase('Build')

const built = await agent(
  `Generate the machine source, integrate it into QEMU and build.\n` +
  `track=${track}, model=${model}, machine name=${machine}\n\n` +
  `1. Record the phase: bash "${PLUGIN}/scripts/journal.sh" "${workdir}" phase "Build"\n` +
  (track === 1 && arch === 'arm32'
    ? `★ This bootloader is AArch32. templates/machine.c.tmpl models an AArch64\n` +
      `   machine and would produce a wrong machine rather than a failure, so do\n` +
      `   NOT use it. Author the machine for AArch32 from the derived facts\n` +
      `   (exception-vector entry, CP15 MMU/cache setup, 16550-style UART at the\n` +
      `   derived base, DRAM covering the load address). If you cannot do that\n` +
      `   from derived facts alone, report build_ok=false saying an AArch32\n` +
      `   machine template is missing - do not guess.\n`
    : '') +
  `2. Fill the template ` +
  `${track === 1 ? (arch === 'arm32' ? '(no AArch32 template yet - see above)' : 'templates/machine.c.tmpl')
                 : 'templates/machine_kernel.c.tmpl' + (target === 'K3' ? ' (plus templates/storage_hci.c.tmpl)' : '')} ` +
  `with values derived in ${track === 1 ? 'STATIC.md' : 'KERNEL_STATIC.md'} and write ` +
  `${workdir}/06_machine/${track === 1 ? 'machine.c' : 'machine_kernel.c'}.\n` +
  `   Never invent a value that was not derived. Mark undetermined slots with a ` +
  `   comment instead of guessing.\n` +
  (track === 2
    ? `3. python3 "${PLUGIN}/scripts/patch_qemu_core.py"  (idempotent SMC core patch)\n` +
      `   python3 "${PLUGIN}/scripts/patch_kernel.py" ${workdir}/fw/Image ${workdir}/fw/Image.patched\n` +
      `   patch_kernel.py refuses to apply on a pre-image mismatch - report that as is.\n`
    : '') +
  `4. Copy into hw/arm/, register in meson.build, then\n` +
  `   cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64\n` +
  `5. A build error must be reported verbatim with build_ok=false. Never guess a fix.\n` +
  `6. Confirm registration: qemu-system-aarch64 -M help | grep ${machine}\n` +
  `7. Ensure ${workdir}/06_machine/bypasses.md exists (header only is fine).\n` +
  `   That file is user-facing: write it in natural Korean.\n` +
  `8. python3 "${PLUGIN}/scripts/record.py" "${workdir}" metric phase=Build ` +
  `event=build_end tokens_total=${budget.spent()}`,
  { schema: BUILD_SCHEMA, label: 'build', phase: 'Build' }
)

if (built && built.build_ok === false) {
  await shell('record-build-blocker', 'Build',
    `python3 "${PLUGIN}/scripts/record.py" "${workdir}" blocker code=BLOCKED_BUILD detail=${shq('ninja 빌드 실패')}`,
    OK_SCHEMA)
  log(`★ 정지 — BLOCKED_BUILD: ${built.build_error ?? '빌드 실패'}`)
  return {
    success: false, stopped: true, stop_reason: 'BLOCKED_BUILD',
    detail: built.build_error,
    note: '빌드 에러는 추측으로 고치지 않습니다. 원문 그대로 확인해 주세요.',
  }
}

// =============================================================================
// Phase 3 - Loop
// =============================================================================
phase('Loop')

const roundLog = []
let round = 0
let goalIndex = 0
let stopped = false
let stopReason = null

while (goalIndex < goals.length && !stopped && round < ROUND_CAP) {
  const goal = goals[goalIndex]
  round += 1

  // run_round.sh performs the journal entry, the change snapshot, the run and the
  // stop-condition computation, then merges them into one document. The agent only
  // relays that document: it never assembles `stop` itself, so the stop backstop
  // cannot be weakened by a transcription slip.
  const obs = await shell(`run-${round}`, 'Loop',
    `bash "${PLUGIN}/scripts/run_round.sh" "${workdir}" ${track} ${machine} ${round} ` +
    `${shq(goal)} ${shq(ladderArg)}` +
    (track === 1 ? ` ${shq(bootloader_path)} help ${shq(surface)}` : '') + `\n` +
    `\n# This prints ONE observation document, also saved to ${workdir}/observation.json.\n` +
    `# Relay it as-is. Do not merge, re-derive or adjust any field - above all\n` +
    `# stop and stop_reason, which the pipeline enforces against your route.`,
    RUN_SCHEMA)

  if (obs?.run_ok === false) {
    log(`[루프] 회차 ${round}: ★ fingerprint.json 이 생성되지 않았습니다 — QEMU 실행 자체가 실패했을 수 있습니다.`)
  }

  log(`[루프] 회차 ${round} (목표 ${goal}) — 마일스톤 ${obs?.milestone ?? '?'}, ` +
      `예외 ${obs?.exceptions ?? '?'} 건, 정체 ${obs?.stall_count ?? 0} 회` +
      (obs?.injected ? ' ★ 자가주입 감지' : ''))

  const sup = await agent(
    `Round ${round}, current goal "${goal}" (ladder: ${ladderArg}).\n` +
    `Fingerprint file: ${workdir}/fingerprint.json\n` +
    `Stop conditions: ${JSON.stringify({
      stop: obs?.stop, stop_reason: obs?.stop_reason, stall_count: obs?.stall_count,
      escalate_to_analyst: obs?.escalate_to_analyst,
      suspect_prior_bypass: obs?.suspect_prior_bypass,
      best_milestone: obs?.best_milestone,
    })}\n` +
    `Observed milestone: ${obs?.milestone}, provenance gate injected: ${obs?.injected}\n\n` +
    `Choose a route. If stop is true you may only answer route="stop".\n` +
    `Round count and elapsed time are not stop reasons: when stop is false, keep going.`,
    { agentType: 'supervisor', schema: SUPERVISOR_SCHEMA, label: `supervisor-${round}`, phase: 'Loop' }
  )

  // Honesty backstop: a measured stop cannot be routed around.
  let route = sup?.route ?? 'fault-classifier'
  if (obs?.stop === true && route !== 'stop') {
    await shell(`force-stop-${round}`, 'Loop',
      `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
      `${shq(`supervisor 회차 ${round}`)} ${shq('강제 정지')} ` +
      `${shq(`정지 조건이 stop=true(${obs?.stop_reason}) 인데 supervisor 가 ${route} 로 우회하려 해서 사실을 우선했습니다`)}`,
      OK_SCHEMA)
    log(`★ supervisor 가 정지를 우회하려 해서 강제로 멈춥니다 (${obs?.stop_reason})`)
    route = 'stop'
  }

  if (route === 'stop') {
    stopped = true
    stopReason = obs?.stop_reason ?? 'EXHAUSTED'
    break
  }

  // Goal advancement is decided by measurement, never by the supervisor's claim.
  // The run script already dropped any milestone that failed the provenance gate.
  //
  // Use every rung the run cleared, not just the highest. A ladder may skip rungs
  // (K3 has no `rootfs`), so a top milestone outside the ladder would otherwise
  // hide a lower rung inside it and strand the loop on a goal already met.
  const reachedList = (obs?.milestones_reached?.length ? obs.milestones_reached
                                                       : [obs?.milestone ?? 'none'])
  const reachedIndex = reachedList.reduce(
    (best, name) => Math.max(best, goals.indexOf(name)), -1)
  const goalMet = reachedIndex >= goalIndex

  if (goalMet) {
    const cleared = goals.slice(goalIndex, reachedIndex + 1)
    goalIndex = reachedIndex + 1
    log(`[루프] ★ 목표 ${cleared.map(g => `"${g}"`).join(', ')} 도달 — ` +
        (goalIndex >= goals.length ? '사다리를 모두 통과했습니다.' : `다음 목표는 "${goals[goalIndex]}" 입니다.`))
    await shell(`goal-${round}`, 'Loop',
      journalTryEnd(round, '목표 도달', `${obs?.milestone} 마일스톤을 커널·펌웨어 출력에서 확인`,
                    '다음 목표로 진행', obs?.console ?? '') + `\n` +
      recordRoundCmd(round, goal, obs, 'reached', null, null, 'progress', -1, false),
      OK_SCHEMA)
    continue
  }

  if (route === 'verify' || route === 'next_goal') {
    // The supervisor claims the goal without an observed milestone to back it.
    log(`[루프] supervisor 가 목표 도달(${route})을 주장했지만 관측된 마일스톤이 ` +
        `"${obs?.milestone}" 이라 인정하지 않고 분류를 계속합니다.`)
  }

  let analystNewFacts = -1
  if (route === 'static-analyzer' || obs?.escalate_to_analyst) {
    const esc = await agent(
      `Run in mode=escalation. Round ${round}, goal ${goal}.\n` +
      `The run is stalled or the stop point is unrecognised.\n` +
      `Fingerprint: ${JSON.stringify({
        far: obs?.far, elr: obs?.elr, exceptions: obs?.exceptions })}\n` +
      `Summary log: ${obs?.summary}\nFull trace: ${obs?.trace}\n\n` +
      `Derive what is actually executing at that address, who called it, or where ` +
      `the value comes from. Disassemble; do not guess.\n` +
      `If you find nothing new, report new_facts_count=0 honestly - that number ` +
      `feeds the stop condition, so inflating it means the loop never ends.`,
      { agentType: 'static-analyzer', schema: ANALYST_SCHEMA, label: `escalate-${round}`, phase: 'Loop' }
    )
    analystNewFacts = esc?.new_facts_count ?? 0
    log(`[루프] 도출 에스컬레이션 — 새 사실 ${analystNewFacts} 개`)
  }

  const cls = await agent(
    `Round ${round}, goal ${goal}, track ${track}.\n` +
    `Fingerprint: ${workdir}/fingerprint.json (provenance gate injected=${obs?.injected})\n` +
    `Console: ${obs?.console}\nSummary: ${obs?.summary}\nFull trace if needed: ${obs?.trace}\n` +
    `Registry: fixers/registry.yaml\n` +
    `Already attempted changes: read change_key values from ${workdir}/rounds.jsonl\n` +
    (sup?.suspect_prior_bypass || obs?.suspect_prior_bypass
      ? `The run is stalling. Before blaming anything new, suspect the side effects ` +
        `already recorded in 06_machine/bypasses.md.\n`
      : '') +
    `Name the stop point and rank the fixers that own it. ` +
    `"unknown" is a correct answer when nothing matches - do not force a fit.`,
    { agentType: 'fault-classifier', schema: CLASSIFIER_SCHEMA, label: `classify-${round}`, phase: 'Loop' }
  )

  const ranked = (cls?.fixer_ranking ?? [])
    .filter(f => KNOWN_FIXERS.includes(f?.fixer))
    .sort((a, b) => (a?.rank ?? 99) - (b?.rank ?? 99))

  if (cls?.category === 'unknown' || ranked.length === 0) {
    log(`[루프] 회차 ${round}: 분류할 수 없어(unknown) 담당 fixer 가 없습니다 — 다음 회차에 도출로 넘깁니다.`)
    await shell(`unknown-${round}`, 'Loop',
      journalTryEnd(round, 'unknown',
                    cls?.novelty?.why ?? '기존 분류와 시그니처가 맞지 않음',
                    'static-analyzer 재도출로 이관', obs?.summary ?? '') + `\n` +
      recordRoundCmd(round, goal, obs, cls?.category ?? 'unknown', null, null,
                     'stall', analystNewFacts, true),
      OK_SCHEMA)
    continue
  }

  const chosen = ranked[0].fixer
  const fix = await agent(
    `Round ${round}, goal ${goal}. Classification: ${cls?.category}\n` +
    `Evidence: ${JSON.stringify(cls?.evidence ?? {})}\n` +
    `Fingerprint: ${JSON.stringify({ far: obs?.far, elr: obs?.elr, exceptions: obs?.exceptions })}\n` +
    `Derived facts: ${track === 1 ? `${workdir}/STATIC.md` : `${workdir}/KERNEL_STATIC.md`}\n` +
    `Current sources: ${workdir}/06_machine/\n` +
    `Already attempted: ${workdir}/rounds.jsonl - never repeat an existing change_key\n` +
    `Bypass record: ${workdir}/06_machine/bypasses.md\n` +
    (sup?.suspect_prior_bypass
      ? `The run is stalling. Suspect the side effects of an earlier bypass before adding a new one.\n`
      : '') +
    `\nChange exactly ONE place and append the four-field bypass entry to bypasses.md.\n` +
    `bypasses.md and the PROGRESS.md line are user-facing: write them in natural Korean.\n` +
    `If this is not your area answer not_mine=true. If you have no untried change ` +
    `left, answer no_new_change=true honestly - that feeds the stop condition.`,
    { agentType: chosen, schema: FIXER_SCHEMA, label: `${chosen}-${round}`, phase: 'Loop' }
  )

  if (fix?.not_mine || fix?.no_new_change || !fix?.change) {
    log(`[루프] 회차 ${round}: ${chosen} 반려 ` +
        `(담당아님=${fix?.not_mine === true}, 새 시도 없음=${fix?.no_new_change === true})`)
    await shell(`decline-${round}`, 'Loop',
      journalTryEnd(round, cls?.category ?? 'unknown', `${chosen} 가 반려함`,
                    '다음 후보 fixer 또는 도출로 이관', obs?.summary ?? '') + `\n` +
      recordRoundCmd(round, goal, obs, cls?.category, chosen, fix?.change_key,
                     'stall', analystNewFacts, true),
      OK_SCHEMA)
    continue
  }

  const applied = await shell(`apply-${round}`, 'Loop',
    `# 1) One-change gate. On violation the edit is rolled back and the round is void.\n` +
    `bash "${PLUGIN}/scripts/check_change.sh" "${workdir}" verify; GATE=$?\n` +
    `if [ $GATE -ne 0 ]; then bash "${PLUGIN}/scripts/check_change.sh" "${workdir}" restore; fi\n` +
    `# 2) Rebuild. Report build errors verbatim; never guess a fix.\n` +
    `cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64\n` +
    `# 3) Human-readable one-line history\n` +
    `echo ${shq(fix?.one_line_progress ?? '')} >> "${workdir}/PROGRESS.md"\n` +
    `# 4) Journal entry\n` +
    journalTryEnd(round, cls?.category ?? '', fix?.rationale ?? '',
                  fix?.change?.description ?? '', obs?.summary ?? '') + `\n` +
    `# 5) Machine-readable round record - exactly one line per round.\n` +
    `#    The branch is bash, not a judgement call: recording both would put two\n` +
    `#    identical fingerprints in rounds.jsonl and fake a stall.\n` +
    `if [ $GATE -eq 0 ]; then\n` +
    `  ` + recordRoundCmd(round, goal, obs, cls?.category, chosen, fix?.change_key,
                          'applied', analystNewFacts, false) + `\n` +
    `else\n` +
    `  ` + recordRoundCmd(round, goal, obs, cls?.category, chosen, fix?.change_key,
                          'reverted', analystNewFacts, false) + `\n` +
    `fi\n` +
    `python3 "${PLUGIN}/scripts/record.py" "${workdir}" metric phase=Loop round=${round} ` +
    `event=apply_end tokens_total=${budget.spent()}\n` +
    `\n# Report gate_pass from the check_change JSON and build_ok from ninja.`,
    APPLY_SCHEMA)

  if (applied && applied.gate_pass === false) {
    log(`[루프] 회차 ${round}: ★ 한 변경 검문 불통과 — ${applied.gate_reason ?? ''} (되돌렸습니다)`)
  }
  if (applied && applied.build_ok === false) {
    await shell(`build-blocker-${round}`, 'Loop',
      `python3 "${PLUGIN}/scripts/record.py" "${workdir}" blocker code=BLOCKED_BUILD ` +
      `detail=${shq(`회차 ${round} 재빌드 실패`)}`,
      OK_SCHEMA)
    stopped = true; stopReason = 'BLOCKED_BUILD'
    break
  }

  roundLog.push({ round, goal, category: cls?.category, fixer: chosen, change_key: fix?.change_key })
}

const reachedAll = goalIndex >= goals.length

if (round >= ROUND_CAP && !reachedAll && !stopped) {
  log(`[루프] 런타임 회차 한계 ${ROUND_CAP} 에 도달했습니다. 목표 도달 불가 판정이 아니라 ` +
      `런타임 한계이며, 같은 명령을 다시 실행하면 이어서 진행됩니다.`)
}

// --- structurally unreachable: honest incomplete result -----------------------
if (stopped) {
  const summary = await shell('stop-report', 'Loop',
    `python3 "${PLUGIN}/scripts/stop_conditions.py" "${workdir}" --ladder "${ladderArg}"\n` +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
    `${shq(`정지: ${stopReason} — 구조상 목표 도달 불가. 재개 가능합니다.`)}`,
    {
      type: 'object',
      properties: {
        best_milestone: { type: ['string', 'null'] },
        tried_changes: { type: 'array' },
      },
    })
  log(`★ 정지 — ${stopReason}. 도달한 최고 마일스톤: ${summary?.best_milestone ?? '없음'}`)
  return {
    success: false, stopped: true, stop_reason: stopReason,
    rounds_run: round, goals, reached_goals: goals.slice(0, goalIndex),
    best_milestone: summary?.best_milestone ?? null,
    tried_changes: summary?.tried_changes ?? [],
    note: 'REAL 로 표기하지 마세요. 정직한 미완이며 같은 명령으로 재실행하면 이어서 진행됩니다.',
  }
}

if (!reachedAll) {
  return {
    success: false, stopped: false, stop_reason: 'RUNTIME_ROUND_CAP',
    rounds_run: round, goals, reached_goals: goals.slice(0, goalIndex),
    note: `런타임 회차 한계(${ROUND_CAP})입니다. 목표 도달 불가 판정이 아니며 재실행하면 이어집니다.`,
  }
}

// =============================================================================
// Phase 4 - Verify
// =============================================================================
phase('Verify')

const verifyCmd =
  `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" phase "Verify"\n` +
  `python3 "${PLUGIN}/scripts/verify.py" "${workdir}" --track ${track} --target ${target}` +
  (track === 1 ? ` --bl3 "${bootloader_path}" --surface ${surface}` : '')

const verifier = await agent(
  `This is stage 2 of the 5/5 verification.\n\n` +
  `1. Run stage 1 (the script measurement) first:\n\`\`\`bash\n${verifyCmd}\n\`\`\`\n` +
  `   It writes ${workdir}/verdict_script.json.\n` +
  `   For track 1 item 1 the script derives the expected PCs from STATIC.md; if it ` +
  `   reports it could not find them, re-run with explicit --pc values you read yourself.\n\n` +
  `2. Re-verify that measurement against the raw logs and bytes.\n` +
  `   - Lowering the verdict (REAL -> FORCED) is always yours to make. When in doubt, lower it.\n` +
  `   - Raising it (FORCED -> REAL) is only valid with byte-level evidence. Without ` +
  `     that evidence the script verdict stands and your override is void.\n\n` +
  `3. Write ${workdir}/VERIFICATION.md in natural Korean - the user reads it. ` +
  `   Show both the script verdict and yours, and when they differ say which won and why.\n\n` +
  `4. Finally record:\n` +
  `   python3 "${PLUGIN}/scripts/record.py" "${workdir}" metric phase=Verify ` +
  `event=verify_end tokens_total=${budget.spent()}`,
  { agentType: 'verifier', schema: VERIFIER_SCHEMA, label: 'verify', phase: 'Verify' }
)

const passes = verifier?.final_passes ?? 0
const verdict = verifier?.final_verdict ?? 'FORCED'
log(`[검증] 스크립트 ${verifier?.script_passes ?? '?'}/5 → 최종 ${passes}/5 (${verdict})`)

// =============================================================================
// Phase 5 - Package
// =============================================================================
phase('Package')

await agent(
  `Assemble the reproduction kit in ${workdir}/10_reproduce/.\n` +
  `Everything written here is user-facing: use natural Korean.\n\n` +
  `Include:\n` +
  `- README.md (INPUT.md summary, build and run steps, verdict ${passes}/5 ${verdict})\n` +
  (track === 1 ? `- bootloader/ (copy of ${bootloader_path})\n`
               : `- fw/ (Image.patched, *.dtb, initramfs reference)\n`) +
  `- machine/ (sources from 06_machine plus bypasses.md)\n` +
  `- scripts/ (setup_env.sh, build and run scripts)\n` +
  `- evidence/ (latest console and summary, VERIFICATION.md, PROGRESS.md, JOURNAL.md,\n` +
  `  metrics.jsonl, rounds.jsonl, verdict_script.json)\n\n` +
  (verdict === 'REAL'
    ? `The verdict is REAL. State it as "5/5 통과, REAL 판정" and nothing stronger.\n`
    : `The verdict is FORCED. Do not write "REAL" or "성공" anywhere in the README.\n`) +
  `Finally: bash "${PLUGIN}/scripts/journal.sh" "${workdir}" phase "Package 완료"`,
  { label: 'package', phase: 'Package' }
)

return {
  success: verdict === 'REAL',
  verdict,
  passes,
  track, target, goals,
  reached_goals: goals.slice(0, goalIndex),
  rounds_run: round,
  rounds_detail: roundLog,
  failed_items: verifier?.failed_items ?? [],
  override: verifier?.override ?? null,
  next_recommendation: verifier?.next_round_recommendation ?? null,
  reproduce_dir: `${workdir}/10_reproduce/`,
  records: {
    metrics: `${workdir}/metrics.jsonl`,
    rounds: `${workdir}/rounds.jsonl`,
    blockers: `${workdir}/blockers.jsonl`,
  },
  note: verdict === 'REAL'
    ? '5/5 통과, REAL 판정입니다.'
    : 'FORCED 입니다. 5/5 에 미달했으므로 REAL·성공으로 표기하지 마세요.',
}
