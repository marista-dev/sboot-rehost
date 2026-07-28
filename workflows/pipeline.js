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
// Backslashes in a Windows path are escape characters to bash, so every path we
// interpolate into a command is normalised to forward slashes first. Both Git
// Bash and WSL accept that form, and wsl_bridge.sh translates C:/... to /mnt/c.
function posix(value) {
  return typeof value === 'string' ? value.replace(/\\/g, '/') : value
}

const workdir   = posix(args?.workdir)
const track     = Number(args?.track ?? 1)
const model     = args?.model
// bl3_path is the pre-0.10 name. BL3 is ARM/Exynos wording and reads wrong for a
// MediaTek LK image, so the slot is bootloader_path now; both are accepted.
const bootloader_path = posix(args?.bootloader_path ?? args?.bl3_path)
const target    = String(args?.target ?? (track === 1 ? 'A' : 'K2')).toUpperCase()
const socFamily = String(args?.soc_family ?? 'generic').toLowerCase()
const arch      = String(args?.arch ?? 'arm64').toLowerCase()
const PLUGIN    = posix(args?.plugin_dir) ?? '${CLAUDE_PLUGIN_ROOT}'
const ROUND_CAP = Number(args?.runtime_round_cap ?? 120)

// One accumulating record per firmware. The analyst appends to it, the
// classifier and the fixers read it. Everything derived about this target lives
// here so a finding made in round 5 is still available in round 40.
const staticDoc = `${workdir}/${track === 2 ? 'KERNEL_STATIC.md' : 'STATIC.md'}`

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

// The ladder is a function of the surface, because static-analyzer may correct
// the surface after this point and the goals must follow that correction rather
// than force a re-run.
//
// Track 1 grades are depth of real bootloader function, and the first rung is
// the interactive surface this firmware actually has - not "shell" by
// assumption. The rungs above it mean the same thing on every surface:
//   A  reach the surface and run its listing command  (help / getvar)
//   B  other command handlers actually do their work
//   C  the bootloader proceeds with its normal boot flow (autoboot)
function goalsFor(surfaceName) {
  const ladders = {
    1: {
      A: [surfaceName],
      B: [surfaceName, 'commands'],
      C: [surfaceName, 'commands', 'autoboot'],
    },
    2: {
      K1: ['userspace'],
      K2: ['userspace', 'rootfs'],
      K3: ['userspace', 'link_up', 'power_mode', 'scsi_attach', 'partitions_up']
            .concat(hasSuper ? ['super_mounted'] : []),
    },
  }
  return (ladders[track] || {})[target] || ladders[1].A
}

let activeSurface = surface
let goals = goalsFor(activeSurface)
let ladderArg = goals.join(',')
// Fixers are per track. Track 1 stops at the bootloader's interactive surface;
// a vendor storage controller is track 2's goal and has no business being
// selected here. Without this filter the classifier could rank fixer-storage on
// a track 1 round - the tables and the registry it reads describe both tracks -
// and a bootloader run would drift into UFS work the grade never asked for.
const FIXERS_BY_TRACK = {
  1: ['fixer-memory', 'fixer-el3', 'fixer-bootflow'],
  2: ['fixer-memory', 'fixer-el3', 'fixer-bootflow', 'fixer-kernel', 'fixer-storage'],
}
const KNOWN_FIXERS = FIXERS_BY_TRACK[track] ?? FIXERS_BY_TRACK[1]

// Knowledge tables follow the same split, so the classifier is not offered stop
// points that belong to the other track.
const KNOWLEDGE = track === 2
  ? 'knowledge/faults_kernel.md, knowledge/faults_storage.md, knowledge/kernel_gates.md'
  : 'knowledge/faults_bootloader.md'

// Last resort. Not in KNOWN_FIXERS: it is reached only after a specialist has
// declined, never by ranking, so that the widest scope stays the exception.
const GENERAL_FIXER = 'fixer-general'

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

/* The last-resort fixer, reached two ways: the supervisor sends a stop point here
 * when no implemented fixer covers it, or a specialist it picked declined. Both
 * mean the same thing - the fault has no owner - so both carry the supervisor's
 * treatment plan, which is more useful here than anywhere else because this fixer
 * has no table telling it where to look. */
function runGeneralFixer(round, goal, why, plan, obs, cls, derivedTable) {
  return agent(
    `Round ${round}, goal ${goal}, track ${track}. You are the last resort.\n` +
    `${why}\n` +
    `Classification: ${cls?.category ?? 'unknown'}   ` +
    `Evidence: ${JSON.stringify(cls?.evidence ?? {})}\n` +
    `Fingerprint: ${fingerprintText(obs)}\n` +
    `Console: ${obs?.console}\nSummary: ${obs?.summary}\nFull trace: ${obs?.trace}\n` +
    `Derived facts: ${staticDoc}\nStop points derived so far:\n${derivedTable}\n` +
    (plan ? `Supervisor's treatment plan: ${plan}\n` : '') +
    `Machine sources: ${workdir}/06_machine/   Bypasses: ${workdir}/06_machine/bypasses.md\n` +
    `Already attempted: ${workdir}/rounds.jsonl - never repeat an existing change_key\n` +
    `Build (BOTH commands, in this order - editing the workspace source alone ` +
    `leaves the QEMU tree compiling the previous version):\n` +
    `  bash "${PLUGIN}/scripts/sync_machine.sh" "${workdir}" ${machine}\n` +
    `  cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64\n\n` +
    `Treat ONE mechanism. You may touch several places only if they are parts of ` +
    `one cause, and you must say in one sentence why they are one.\n` +
    `Then rebuild, and report build failures verbatim.\n` +
    `Append the four-field bypass entry to bypasses.md, and record what you did ` +
    `in ${workdir}/fixer_candidates.md so a real specialist can be written later - ` +
    `that record is half the job, not an afterthought.\n` +
    `If the mechanism is not understood, do not guess: answer no_new_change=true ` +
    `and the run goes back to derivation. You have the widest scope here, so that ` +
    `answer is what stands between an honest stop and an endless run.`,
    { agentType: GENERAL_FIXER, schema: GENERAL_SCHEMA, model: 'opus', effort: 'high',
      label: `general-${round}`, phase: 'Loop' })
}

/* The fingerprint as the classifier and the fixers should see it.
 * The originating exception comes first because it is the stop point; the last
 * FAR in the trace is only where a nested abort ran out of time, and leading
 * with it sent round after round chasing an address that was a symptom of the
 * recursion rather than its cause. */
function fingerprintText(obs) {
  return JSON.stringify({
    origin: { type: obs?.origin_type, esr: obs?.origin_esr,
              far: obs?.origin_far, elr: obs?.origin_elr },
    exceptions: obs?.exceptions,
    console_bytes: obs?.console_bytes, console_uniq: obs?.console_uniq,
    last_far_in_trace: obs?.far, last_elr_in_trace: obs?.elr,
  }) + (obs?.origin_block ? `\n최초 예외 블록: ${obs.origin_block}` : '') +
  `\n(last_far/last_elr 는 storm 의 마지막 지점입니다. 진단은 origin 으로 하세요.)`
}

function recordRoundCmd(round, goal, fp, category, fixer, changeKey, effect, analystFacts, noNewChange) {
  const fields = [
    `round=${round}`,
    `goal=${shq(goal)}`,
    `fp_exc=${Number(fp?.exceptions ?? 0)}`,
    `fp_far=${shq(fp?.far ?? 'none')}`,
    `fp_elr=${shq(fp?.elr ?? 'none')}`,
    // Identity of the stop point. Recorded separately from the trailing FAR so
    // the stop conditions can compare rounds by what actually happened.
    `fp_origin_esr=${shq(fp?.origin_esr ?? 'none')}`,
    `fp_origin_far=${shq(fp?.origin_far ?? 'none')}`,
    `fp_origin_elr=${shq(fp?.origin_elr ?? 'none')}`,
    `fp_milestone=${shq(fp?.milestone ?? 'none')}`,
    `fp_bytes=${Number(fp?.console_bytes ?? 0)}`,
    `fp_uniq=${Number(fp?.console_uniq ?? 0)}`,
    `category=${shq(category ?? 'none')}`,
    `fixer=${shq(fixer ?? 'none')}`,
    `change_key=${shq(changeKey ?? 'none')}`,
    `effect=${shq(effect)}`,
    `analyst_new_facts=${Number(analystFacts)}`,
    `fixer_no_new_change=${noNewChange === true}`,
    `tokens_total=${budget.spent()}`,
  ].join(' ')
  return `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" round ${fields}`
}

function journalTryEnd(round, cause, analysis, fix, evidence) {
  return `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" try-end ${round} ` +
         `${shq(cause)} ${shq(analysis)} ${shq(fix)} ${shq(evidence)}`
}

const OK_SCHEMA = { type: 'object', properties: { ok: { type: 'boolean' } } }

// --- schemas -----------------------------------------------------------------
const DERIVED_SCHEMA = {
  type: 'object',
  properties: {
    total: { type: 'integer' },
    new: { type: 'integer' },
    new_signatures: { type: 'array' },
    stop_points: { type: 'array' },
  },
  required: ['total', 'new'],
}

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
    run_error: { type: 'string' },
    milestone: { type: 'string' },
    milestones_reached: { type: 'array' },
    injected: { type: 'boolean' },
    exceptions: { type: 'integer' },
    console_bytes: { type: 'integer' },
    console_uniq: { type: 'integer' },
    origin_type: { type: 'string' },
    origin_esr: { type: 'string' },
    origin_far: { type: 'string' },
    origin_elr: { type: 'string' },
    origin_block: { type: 'string' },
    timeout_bound: { type: 'boolean' },
    probe_console_bytes: { type: 'integer' },
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
    best_progress: { type: 'object' },
    tried_changes: { type: 'array' },
    futile_changes: { type: 'integer' },
    needs_layer_review: { type: 'boolean' },
  },
  required: ['milestone', 'stop'],
}

const SUPERVISOR_SCHEMA = {
  type: 'object',
  properties: {
    route: { type: 'string' },
    layer: { type: ['string', 'null'] },
    build_change: { type: ['object', 'null'] },
    // { round, reason } - withdraw a bypass whose mechanism has been disproven
    revert: { type: ['object', 'null'] },
    treatment_plan: { type: ['string', 'null'] },
    prescribed_fixer: { type: ['string', 'null'] },
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

const GENERAL_SCHEMA = {
  type: 'object',
  properties: {
    fixer: { type: 'string' },
    no_new_change: { type: 'boolean' },
    mechanism: { type: ['string', 'null'] },
    change_key: { type: ['string', 'null'] },
    changes: { type: 'array' },
    build_ok: { type: ['boolean', 'null'] },
    build_error: { type: ['string', 'null'] },
    bypass_doc: { type: 'boolean' },
    candidate_doc: { type: 'boolean' },
    one_line_progress: { type: ['string', 'null'] },
    rationale: { type: ['string', 'null'] },
  },
  required: ['no_new_change'],
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
    // Did the edited source actually reach the tree ninja compiles?
    sync_ok: { type: 'boolean' },
    sync_reason: { type: ['string', 'null'] },
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

// Precondition: can this shell run the work at all?
//
// On native Windows the agent's Bash tool is Git Bash, which cannot see /mnt/c
// or run a Linux QEMU. Every round would then fail for the same reason while
// the loop treats it as an ordinary stop point and burns its whole round
// budget. A shell that cannot execute the work is not a goal judgement - check
// it once, up front, and stop with something the user can act on.
const env = await shell('check-env', 'Analyze',
  `bash "${PLUGIN}/scripts/check_env.sh" "${workdir}" ${track}`,
  {
    type: 'object',
    properties: {
      ok: { type: 'boolean' },
      os: { type: 'string' },
      problems: { type: 'array' },
      hint: { type: 'string' },
    },
    required: ['ok'],
  })

if (!env || env.ok !== true) {
  const problems = (env.problems ?? []).join(' / ')
  await shell('record-env-blocker', 'Analyze',
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_ENV ` +
    `detail=${shq(problems)} 2>/dev/null || true\n` +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
    `${shq(`환경 블로커: ${problems}`)} 2>/dev/null || true`,
    OK_SCHEMA)
  log(`★ 정지 — BLOCKED_ENV (${env.os ?? '?'}): 실행 환경이 준비되지 않았습니다.`)
  ;(env.problems ?? []).forEach(p => log(`    · ${p}`))
  return {
    success: false, stopped: true, stop_reason: 'BLOCKED_ENV',
    os: env.os, problems: env.problems ?? [],
    note: (env.hint || '실행 환경을 갖춘 뒤 다시 시도하세요.') +
          ' 이것은 목표 도달 판정이 아니라 실행 환경 문제이며, 환경만 갖추면 ' +
          '같은 명령으로 그대로 재개됩니다 (워크스페이스·INPUT.md 재사용).',
  }
}

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
      `"none" is a hard blocker - say so rather than inventing a route.\n\n` +
      `DERIVE TWO MORE THINGS BEFORE THE BUILD - both cost rounds if left to the loop:\n` +
      `  1. ENTRY PC. If the image is a container (TOC header + EPBL/BL2/BL33\n` +
      `     segments), parse the header and give the BL33 segment's load and entry.\n` +
      `     File offset 0 is the header, not code.\n` +
      `  2. THE AUTOBOOT GATE'S INPUT PATTERN. The gate polls the console and\n` +
      `     counts a run of one byte (usually CR, 0x0d) before it hands over to\n` +
      `     the shell; miss it and the surface is unreachable no matter what else\n` +
      `     is right. Disassemble the gate (the shell function's first bl) and\n` +
      `     write ${workdir}/input_plan.json:\n` +
      `       {"autoboot_interrupt": {"bytes": "\\r", "count": <N>,\n` +
      `        "gate_addr": "0x...", "evidence": "<disassembly line + bytes>"}}\n` +
      `     If you cannot derive N, write no file - the harness then uses a\n` +
      `     documented default and says it was a default.\n`
    : '') + `\n` +
  `First record the phase:\n` +
  `  bash "${PLUGIN}/scripts/journal.sh" "${workdir}" phase "Analyze (static-analyzer prior)"\n` +
  `  bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" start analyze\n\n` +
  (track === 1
    ? `Work through the track 1 checklist (carve verdict first) and write STATIC.md.`
    : `Work through the track 2 checklist (assets, DTB skeleton, security gate sites) ` +
      `and write KERNEL_STATIC.md.`) +
  `\nAnything you cannot derive stays "미확정" with a confirm plan. Never borrow ` +
  `values from another device or build.\n\n` +
  `Write STATIC.md / KERNEL_STATIC.md in natural Korean - the user reads them.\n\n` +
  `When finished:\n` +
  `  bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" metric phase=Analyze ` +
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
// Adopt the derived surface and keep going - stopping to ask the user to edit
// INPUT.md would break the autonomy contract, and a corrected goal is a derived
// fact, not a structural impossibility.
const derivedSurface = String(prior?.bl_surface ?? '').toLowerCase()
if (track === 1 && SURFACES.includes(derivedSurface) && derivedSurface !== activeSurface) {
  const before = activeSurface
  activeSurface = derivedSurface
  goals = goalsFor(activeSurface)
  ladderArg = goals.join(',')
  log(`[분석] 표면 정정: 힌트 "${before}" → 도출 "${activeSurface}". ` +
      `목표 사다리를 ${goals.join(' → ')} 로 바꿔 계속합니다.`)
  await shell('surface-correction', 'Analyze',
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
    `${shq('부트로더 인터랙티브 표면')} ${shq(activeSurface)} ` +
    `${shq(`setup 힌트는 ${before} 였으나 static-analyzer 가 입력 경로를 도출해 정정`)}`,
    OK_SCHEMA)
}

if (blockers.length) {
  const [code, detail] = blockers[0]
  await shell('record-blocker', 'Analyze',
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=${code} detail=${shq(detail)}\n` +
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

/* Build the machine. Called once before the loop, and again when the supervisor
 * judges that the stop point lives in this layer rather than in the loop.
 *
 * A fixer may only change one place in the existing machine sources, so a wrong
 * machine-level premise (entry EL, has_el3, load address, memory skeleton)
 * cannot be repaired from inside the loop - the loop can only stack band-aids on
 * the symptom. `diagnosis` is the supervisor's finding that sends us back here. */
async function buildMachine(diagnosis) {
  const again = diagnosis != null
  return agent(
  (again
    ? `REBUILD. The loop could not fix this from inside, so the machine premise ` +
      `itself is under review.\n` +
      `Supervisor diagnosis: ${diagnosis.reason}\n` +
      `Machine-level change to make: ${diagnosis.change}\n` +
      `Apply exactly that change and rebuild. Keep every other derived value as ` +
      `it is - this is a premise correction, not a rewrite. Append the four-field ` +
      `bypass entry to bypasses.md if the change is a bypass.\n\n`
    : '') +
  `Generate the machine source, integrate it into QEMU and build.\n` +
  `track=${track}, model=${model}, machine name=${machine}\n\n` +
  `1. Record the phase: bash "${PLUGIN}/scripts/journal.sh" "${workdir}" phase ${again ? '"Rebuild"' : '"Build"'}\n` +
  (track === 1 && arch === 'arm32'
    ? `★ This bootloader is AArch32. templates/machine.c.tmpl models an AArch64\n` +
      `   machine and would produce a wrong machine rather than a failure, so do\n` +
      `   NOT use it. Author the machine for AArch32 from the derived facts\n` +
      `   (exception-vector entry, CP15 MMU/cache setup, 16550-style UART at the\n` +
      `   derived base, DRAM covering the load address). If you cannot do that\n` +
      `   from derived facts alone, report build_ok=false saying an AArch32\n` +
      `   machine template is missing - do not guess.\n`
    : '') +
  (track === 1
    ? `★ ENTRY_PC is not LOAD_BASE. A vendor image is usually a container (TOC\n` +
      `   header + EPBL/BL2/BL33 segments) that is loaded whole, so file offset 0\n` +
      `   is the header: entering there executes the header as data and traps on\n` +
      `   the first word. Use the BL33 reset entry derived in STATIC.md. If it is\n` +
      `   undetermined, report build_ok=false and say so - do NOT fall back to the\n` +
      `   load address, which costs several rounds and two rebuilds to undo.\n` +
      `★ The machine must not create console input. No function may fill the RX\n` +
      `   buffer except the chardev receive callback; the interrupt pattern and\n` +
      `   the command come from scripts/uart_harness.py outside QEMU.\n`
    : '') +
  `2. Fill the template ` +
  `${track === 1 ? (arch === 'arm32' ? '(no AArch32 template yet - see above)' : 'templates/machine.c.tmpl')
                 : 'templates/machine_kernel.c.tmpl' + (target === 'K3' ? ' (plus templates/storage_hci.c.tmpl)' : '')} ` +
  `with values derived in ${track === 1 ? 'STATIC.md' : 'KERNEL_STATIC.md'} and write ` +
  `${workdir}/06_machine/${track === 1 ? 'machine.c' : 'machine_kernel.c'}.\n` +
  `   Never invent a value that was not derived. Mark undetermined slots with a ` +
  `   comment instead of guessing.\n` +
  (track === 2
    ? `3. bash "${PLUGIN}/scripts/py.sh" patch_qemu_core.py  (idempotent SMC core patch)\n` +
      `   bash "${PLUGIN}/scripts/py.sh" patch_kernel.py ${workdir}/fw/Image ${workdir}/fw/Image.patched\n` +
      `   patch_kernel.py refuses to apply on a pre-image mismatch - report that as is.\n`
    : '') +
  `4. Copy it into the QEMU tree as hw/arm/${machine.replace(/-/g, '_')}.c and register\n` +
  `   it in hw/arm/meson.build. That exact name matters: every later round syncs\n` +
  `   the workspace source to the tree with scripts/sync_machine.sh, which finds\n` +
  `   the target by that name. Then\n` +
  `   bash "${PLUGIN}/scripts/sync_machine.sh" "${workdir}" ${machine}\n` +
  `   cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64\n` +
  `5. A build error must be reported verbatim with build_ok=false. Never guess a fix.\n` +
  `6. Confirm registration: qemu-system-aarch64 -M help | grep ${machine}\n` +
  `7. Ensure ${workdir}/06_machine/bypasses.md exists (header only is fine).\n` +
  `   That file is user-facing: write it in natural Korean.\n` +
  `8. bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" metric phase=Build ` +
  `event=build_end tokens_total=${budget.spent()}`,
  { schema: BUILD_SCHEMA, label: again ? `rebuild-${diagnosis.round}` : 'build',
    phase: again ? 'Loop' : 'Build' }
  )
}

const built = await buildMachine(null)

if (built && built.build_ok === false) {
  await shell('record-build-blocker', 'Build',
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD detail=${shq('ninja 빌드 실패')}`,
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
    (track === 1 ? ` ${shq(bootloader_path)} help ${shq(activeSurface)}` : '') + `\n` +
    `\n# This prints ONE observation document, also saved to ${workdir}/observation.json.\n` +
    `# Relay it as-is. Do not merge, re-derive or adjust any field - above all\n` +
    `# stop and stop_reason, which the pipeline enforces against your route.`,
    RUN_SCHEMA)

  // A round that did not actually run is not evidence about the firmware. Left
  // as an ordinary round it produces a perfectly stable all-zero fingerprint,
  // which the stop conditions correctly read as a stall and then as EXHAUSTED -
  // "structurally unreachable" - about a QEMU that never started. Eight rounds
  // of the S921N log died exactly this way, so this is a stop, not a log line.
  if (obs?.run_ok === false) {
    log(`[루프] 회차 ${round}: ★ 실행 자체가 실패했습니다 — ${obs?.run_error ?? 'fingerprint.json 없음'}`)
    await shell(`run-blocker-${round}`, 'Loop',
      `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_ENV ` +
      `detail=${shq(`회차 ${round} QEMU 실행 실패: ${obs?.run_error ?? 'fingerprint.json 미생성'}`)}\n` +
      `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
      `${shq(`실행 실패로 정지 (회차 ${round}) — 펌웨어 판정이 아니라 하네스/환경 문제입니다`)}`,
      OK_SCHEMA)
    stopped = true; stopReason = 'BLOCKED_ENV'
    break
  }

  log(`[루프] 회차 ${round} (목표 ${goal}) — 마일스톤 ${obs?.milestone ?? '?'}, ` +
      `콘솔 고유 ${obs?.console_uniq ?? 0} 줄, 예외 ${obs?.exceptions ?? '?'} 건, ` +
      `최초 ${obs?.origin_type ?? 'none'}@${obs?.origin_elr ?? 'none'}, ` +
      `정체 ${obs?.stall_count ?? 0} 회` +
      (obs?.injected ? ' ★ 자가주입 감지' : '') +
      (obs?.timeout_bound ? ' ★ 타임아웃 한계 (더 돌리면 더 나옴)' : ''))

  // Everything derived about this firmware so far. Read before the supervisor,
  // because judging the layer means comparing the machine's premises against the
  // derived facts - and read again after an escalation, which may add rows.
  let analystNewFacts = -1
  let derived = await shell(`derived-peek-${round}`, 'Loop',
    `bash "${PLUGIN}/scripts/py.sh" derived_facts.py "${workdir}" --track ${track} --peek`,
    DERIVED_SCHEMA)
  let derivedRows = (derived?.stop_points ?? [])
  const renderDerived = rows => rows.length
    ? rows.map(r => `- ${r.signature}: ${r.observation} → ${r.mechanism} ` +
                    `[담당 ${r.fixer}] 시도: ${r.treatment}`).join('\n')
    : '(아직 도출된 정지점 없음)'
  let derivedTable = renderDerived(derivedRows)

  // The mechanical routes (stop / verify / next_goal) are already decided by
  // measurement, and the pipeline enforces them below. What is genuinely left to
  // judgement is the LAYER question: can this stop point be fixed by one change
  // inside the machine sources, or is a machine-level premise wrong? A script
  // cannot answer that - it needs someone to read the sources against the
  // derived facts. So the supervisor gets the evidence and a stronger model
  // rather than a lookup table.
  const recent = roundLog.slice(-6)
  const sup = await agent(
    `Round ${round}, current goal "${goal}" (ladder: ${ladderArg}).\n` +
    `Fingerprint file: ${workdir}/fingerprint.json\n` +
    `Fingerprint: ${fingerprintText(obs)}\n` +
    `Stop conditions: ${JSON.stringify({
      stop: obs?.stop, stop_reason: obs?.stop_reason, stall_count: obs?.stall_count,
      escalate_to_analyst: obs?.escalate_to_analyst,
      suspect_prior_bypass: obs?.suspect_prior_bypass,
      best_milestone: obs?.best_milestone,
      best_progress: obs?.best_progress,
      futile_changes: obs?.futile_changes,
      needs_layer_review: obs?.needs_layer_review,
    })}\n` +
    `Observed milestone: ${obs?.milestone}, provenance gate injected: ${obs?.injected}\n` +
    `Boot depth this round: ${obs?.console_uniq ?? 0} distinct console lines ` +
    `(best so far ${obs?.best_progress?.uniq ?? 0} in round ${obs?.best_progress?.round ?? '-'}). ` +
    `On a one-rung ladder this is the only measure of forward motion - a milestone ` +
    `of "none" does not mean the boot went nowhere.\n` +
    (obs?.timeout_bound
      ? `★ A longer run produced MORE console (${obs?.console_bytes}B → ` +
        `${obs?.probe_console_bytes}B). This wall is the run timeout, not the ` +
        `firmware. Do not send a fixer after a stop point that is our own clock.\n`
      : '') +
    `Recent rounds: ${JSON.stringify(recent)}\n` +
    `Derived stop points (${staticDoc}):\n${derivedTable}\n` +
    `Machine sources: ${workdir}/06_machine/   Bypasses: ${workdir}/06_machine/bypasses.md\n` +
    `Machine premises in force: has_el3, entry EL, entry PC, load address, ` +
    `memory skeleton - all set at Build time, none of them reachable by a fixer.\n` +
    `Fixers implemented on this track: ${KNOWN_FIXERS.join(', ')} ` +
    `(domains in fixers/registry.yaml - read it before prescribing).\n` +
    `If the mechanism is understood but no implemented fixer covers it, route ` +
    `"${GENERAL_FIXER}" with a treatment_plan; it has no domain boundary and may ` +
    `edit, build and run. Do not force a fit onto a specialist whose domain does ` +
    `not contain the fault - that produces a decline and wastes the round.\n\n` +
    (obs?.needs_layer_review
      ? `★ ${obs?.futile_changes} changes have been applied and the fingerprint did ` +
        `not move. Treating the symptom is not working. READ the machine sources ` +
        `and the derived facts and judge the layer before routing anywhere.\n`
      : '') +
    `A bypass is a hypothesis about the hardware, and some of them turn out to be ` +
    `wrong. When a round's evidence CONTRADICTS the mechanism an earlier bypass ` +
    `assumed - not merely "it did not help" - route "revert" with ` +
    `revert={round, reason}. Everything after that round stays; only that change ` +
    `comes out. Leaving a disproven bypass in place makes every later change rest ` +
    `on a model you know is false, and it corrupts the bypass list that ` +
    `verification reports.\n` +
    `Choose a route. If stop is true you may only answer route="stop".\n` +
    `Round count and elapsed time are not stop reasons: when stop is false, keep going.`,
    { agentType: 'supervisor', schema: SUPERVISOR_SCHEMA, label: `supervisor-${round}`,
      phase: 'Loop', model: 'opus', effort: obs?.needs_layer_review ? 'high' : 'medium' }
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

  // The supervisor judged that no implemented fixer covers this mechanism, so it
  // goes straight to the fixer with no domain boundary. Skipping classification
  // is the point: naming a category no fixer owns only spends a round.
  if (route === GENERAL_FIXER) {
    log(`[루프] 회차 ${round}: supervisor 판단 — 담당 fixer 없음, fixer-general 로 직행`)
    const gen = await runGeneralFixer(round, goal,
      `The supervisor found no implemented fixer whose domain contains this stop point.`,
      sup?.treatment_plan, obs, null, derivedTable)

    if (!gen || gen.no_new_change || !gen.change_key) {
      log(`[루프] 회차 ${round}: fixer-general 도 새로 시도할 변경이 없습니다.`)
      await shell(`general-decline-${round}`, 'Loop',
        journalTryEnd(round, 'unowned', 'fixer-general 도 시도할 변경 없음',
                      '도출로 이관', obs?.summary ?? '') + `\n` +
        recordRoundCmd(round, goal, obs, 'unowned', GENERAL_FIXER, null,
                       'stall', analystNewFacts, true),
        OK_SCHEMA)
      continue
    }
    if (gen.build_ok === false) {
      await shell(`general-build-blocker-${round}`, 'Loop',
        `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
        `detail=${shq(`회차 ${round} fixer-general 재빌드 실패`)}`,
        OK_SCHEMA)
      stopped = true; stopReason = 'BLOCKED_BUILD'
      break
    }
    log(`[루프] 회차 ${round}: ★ fixer-general 이 처리 — ${gen.mechanism ?? ''}`)
    await shell(`general-record-${round}`, 'Loop',
      `echo ${shq(gen.one_line_progress ?? '')} >> "${workdir}/PROGRESS.md"\n` +
      journalTryEnd(round, 'unowned', gen.rationale ?? gen.mechanism ?? '',
                    (gen.changes ?? []).map(c => `${c.file}: ${c.what}`).join(' / '),
                    obs?.summary ?? '') + `\n` +
      recordRoundCmd(round, goal, obs, 'unowned', GENERAL_FIXER, gen.change_key,
                     'applied', analystNewFacts, false),
      OK_SCHEMA)
    roundLog.push({ round, goal, category: 'unowned', fixer: GENERAL_FIXER,
                    change_key: gen.change_key })
    continue
  }

  // Withdraw a bypass whose mechanism this round disproved. Until now the loop
  // could only add: `suspect_prior_bypass` asked the classifier to be
  // suspicious, but nothing could take the wrong model back out, so later
  // changes kept stacking on top of it and the bypass list stopped being an
  // honest account of the machine.
  if (route === 'revert') {
    const target = Number(sup?.revert?.round ?? 0)
    const key = `revert:${target}`
    if (!target || (obs?.tried_changes ?? []).includes(key)) {
      log(`[루프] 회차 ${round}: 되돌리기 대상이 없거나 이미 되돌린 회차라 분류로 보냅니다.`)
      route = 'fault-classifier'
    } else {
      log(`[루프] 회차 ${round}: ★ 회차 ${target} 우회 철회 — ${sup?.revert?.reason ?? ''}`)
      const rev = await shell(`revert-${round}`, 'Loop',
        `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
        `${shq(`supervisor 회차 ${round}`)} ${shq(`회차 ${target} 우회 철회`)} ` +
        `${shq(sup?.revert?.reason ?? '')}\n` +
        `bash "${PLUGIN}/scripts/revert_change.sh" "${workdir}" ${target} ` +
        `${shq(sup?.revert?.reason ?? '')}; REV=$?\n` +
        `if [ $REV -eq 0 ]; then\n` +
        `  bash "${PLUGIN}/scripts/sync_machine.sh" "${workdir}" ${machine} && ` +
        `(cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64)\n` +
        `fi\n` +
        `# Report reverted/reason from the revert_change.sh JSON, build_ok from ninja.`,
        {
          type: 'object',
          properties: {
            reverted: { type: 'boolean' },
            reason: { type: ['string', 'null'] },
            build_ok: { type: ['boolean', 'null'] },
          },
          required: ['reverted'],
        })

      if (!rev || rev.reverted !== true) {
        // A refusal is a real answer: a later round edited the same place, so
        // the two changes interact and the interaction is what needs treating.
        log(`[루프] 회차 ${round}: 되돌리기 불가 — ${rev?.reason ?? ''} · 분류를 계속합니다.`)
        route = 'fault-classifier'
      } else {
        if (rev.build_ok === false) {
          await shell(`revert-build-blocker-${round}`, 'Loop',
            `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
            `detail=${shq(`회차 ${round} 우회 철회 후 재빌드 실패`)}`,
            OK_SCHEMA)
          stopped = true; stopReason = 'BLOCKED_BUILD'
          break
        }
        await shell(`revert-record-${round}`, 'Loop',
          `echo ${shq(`| run ${round} | 회차 ${target} 우회 철회 | ${sup?.revert?.reason ?? ''} |`)} ` +
          `>> "${workdir}/PROGRESS.md"\n` +
          journalTryEnd(round, 'bypass_revert', sup?.revert?.reason ?? '',
                        `회차 ${target} 변경 제거`, obs?.summary ?? '') + `\n` +
          recordRoundCmd(round, goal, obs, 'bypass_revert', 'supervisor', key,
                         'applied', analystNewFacts, false),
          OK_SCHEMA)
        roundLog.push({ round, goal, category: 'bypass_revert', fixer: 'supervisor',
                        change_key: key })
        continue
      }
    }
  }

  // The loop's own exit for stop points it cannot reach. A fixer edits one place
  // in an existing machine; it cannot correct a premise the machine was built on
  // (has_el3, entry EL, entry PC, load address, memory skeleton). Without this
  // route a wrong premise can only ever collect band-aids, which is exactly how a
  // run spends sixty rounds on one unchanging fingerprint.
  if (route === 'rebuild') {
    const key = sup?.build_change?.change_key
    const tried = (obs?.tried_changes ?? [])
    if (!key || !sup?.build_change?.change) {
      log(`[루프] 회차 ${round}: rebuild 를 요청했지만 구체적 변경이 없어 분류로 되돌립니다.`)
      route = 'fault-classifier'
    } else if (tried.includes(key)) {
      // Same rebuild twice is not a new move. Letting it through would make
      // "rebuild" an unlimited supply of moves and exhaustion unreachable.
      log(`[루프] 회차 ${round}: rebuild ${key} 는 이미 시도한 변경이라 거부하고 분류로 보냅니다.`)
      route = 'fault-classifier'
    } else {
      log(`[루프] 회차 ${round}: ★ 층 판정 — ${sup?.layer ?? 'build'} 층 문제로 판단, 머신 재생성`)
      log(`         근거: ${sup?.build_change?.reason ?? sup?.decision_note ?? ''}`)
      await shell(`rebuild-decision-${round}`, 'Loop',
        `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
        `${shq(`supervisor 회차 ${round}`)} ${shq(`머신 재생성 (${key})`)} ` +
        `${shq(sup?.build_change?.reason ?? '')}`,
        OK_SCHEMA)

      const rebuilt = await buildMachine({
        round, reason: sup?.build_change?.reason ?? sup?.decision_note ?? '',
        change: sup?.build_change?.change,
      })

      if (rebuilt && rebuilt.build_ok === false) {
        await shell(`rebuild-blocker-${round}`, 'Loop',
          `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
          `detail=${shq(`회차 ${round} 머신 재생성 실패`)}`,
          OK_SCHEMA)
        stopped = true; stopReason = 'BLOCKED_BUILD'
        break
      }

      await shell(`rebuild-record-${round}`, 'Loop',
        journalTryEnd(round, 'build_layer',
                      sup?.build_change?.reason ?? '',
                      sup?.build_change?.change ?? '', obs?.summary ?? '') + `\n` +
        recordRoundCmd(round, goal, obs, 'build_layer', 'build', key,
                       'applied', analystNewFacts, false),
        OK_SCHEMA)
      roundLog.push({ round, goal, category: 'build_layer', fixer: 'build',
                      change_key: key })
      continue
    }
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

  if (route === 'static-analyzer' || obs?.escalate_to_analyst) {
    const esc = await agent(
      `Run in mode=escalation. Round ${round}, goal ${goal}.\n` +
      `The run is stalled or the stop point is unrecognised.\n` +
      `Fingerprint: ${fingerprintText(obs)}\n` +
      `Originating exception block: ${obs?.origin_block}\n` +
      `Summary log: ${obs?.summary}\nFull trace: ${obs?.trace}\n\n` +
      `Start from the ORIGINATING exception, not from the last FAR in the trace. ` +
      `Under a nested abort the handler faults on its own context save and FAR ` +
      `walks for millions of iterations; that address is a consequence of the ` +
      `recursion, and deriving a mechanism for it produces a stop point that ` +
      `cannot be fixed because it was never the cause.\n` +
      `Derive what is actually executing at that address, who called it, or where ` +
      `the value comes from. Disassemble; do not guess.\n\n` +
      `THEN WRITE WHAT YOU FOUND DOWN. Append a row to the "## 도출된 정지점" table ` +
      `in ${staticDoc} - one accumulating record for this firmware. A finding that ` +
      `stays in your answer reaches nobody: the classifier and the fixers read that ` +
      `table, so an unwritten fact is the same as no fact.\n` +
      `Columns: signature | observation | mechanism with evidence | owning fixer | ` +
      `change to try. Owning fixer must be one of ${KNOWN_FIXERS.join(', ')}.\n` +
      `If the mechanism is still undetermined, write no row. A row without a ` +
      `derived mechanism is a guess, and a guessed row sends a fixer down a wrong ` +
      `branch - honesty rule 1.`,
      { agentType: 'static-analyzer', schema: ANALYST_SCHEMA, label: `escalate-${round}`, phase: 'Loop' }
    )
    // Measure what was actually written rather than trusting the reported count.
    // A self-reported number cannot be contradicted, so re-deriving the same
    // address would count as "new" every round and exhaustion never arrives.
    const measured = await shell(`derived-${round}`, 'Loop',
      `bash "${PLUGIN}/scripts/py.sh" derived_facts.py "${workdir}" --track ${track}\n` +
      `# Move old evidence prose to 08_docs/ once the record gets large, keeping\n` +
      `# every derived ROW in the table. The analyst re-reads this file each\n` +
      `# escalation, so unbounded growth makes every later round cost more.\n` +
      `bash "${PLUGIN}/scripts/py.sh" static_rotate.py "${workdir}" --track ${track} >/dev/null 2>&1 || true`,
      DERIVED_SCHEMA)
    derived = measured
    derivedRows = (measured?.stop_points ?? derivedRows)
    derivedTable = renderDerived(derivedRows)
    analystNewFacts = measured?.new ?? 0
    log(`[루프] 도출 에스컬레이션 — 기록된 새 정지점 ${analystNewFacts} 개 ` +
        `(누적 ${measured?.total ?? 0}개)` +
        (esc?.new_facts_count > 0 && analystNewFacts === 0
          ? ' · 분석가는 새 사실을 주장했지만 표에 추가된 줄이 없어 0 으로 셉니다'
          : ''))
  }

  // Accumulated stop points for this firmware, whether or not we escalated this
  // round. This is the wiring that was missing: derivation used to end in a
  // counter, so the classifier saw identical input every round and answered
  // "unknown" every round.
  const cls = await agent(
    `Round ${round}, goal ${goal}, track ${track}.\n` +
    `Fingerprint: ${fingerprintText(obs)}\n` +
    `(full file: ${workdir}/fingerprint.json, provenance gate injected=${obs?.injected})\n` +
    `Originating exception block: ${obs?.origin_block}\n` +
    `Match on the ORIGIN. A storm's trailing FAR walks with every run and is not ` +
    `the stop point; naming it produces a category no fixer can act on.\n` +
    `Console: ${obs?.console}\nSummary: ${obs?.summary}\nFull trace if needed: ${obs?.trace}\n` +
    `Registry: fixers/registry.yaml - only these fixers exist on this track: ` +
    `${KNOWN_FIXERS.join(', ')}\n` +
    `Knowledge tables for this track: ${KNOWLEDGE}. Do not match against the ` +
    `other track's tables; a stop point that belongs to another track's goal is ` +
    `not this run's fault.\n` +
    `Derived stop points for THIS firmware (accumulated in ${staticDoc}):\n` +
    `${derivedTable}\n` +
    `Match against these as well as the knowledge tables - they were derived from ` +
    `this exact target, so they outrank a generic signature.\n` +
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

  // A stop point the analyst already derived for this firmware names its own
  // owner, so an unrecognised category is not automatically a dead end.
  const derivedOwner = derivedRows
    .map(r => r.fixer)
    .find(f => KNOWN_FIXERS.includes(f))

  if (ranked.length === 0 && !derivedOwner) {
    // Nobody to ask. Record that honestly - and do NOT claim the fixers are out
    // of moves, because none of them was asked. fixer_no_new_change is an input
    // to the exhaustion condition; asserting it here would let a round where no
    // fixer ran count as a round where every fixer gave up.
    log(`[루프] 회차 ${round}: 분류 불가(unknown)이고 도출된 담당도 없습니다 — 재도출로 넘깁니다.`)
    await shell(`unknown-${round}`, 'Loop',
      journalTryEnd(round, 'unknown',
                    cls?.novelty?.why ?? '기존 분류와 시그니처가 맞지 않음',
                    'static-analyzer 재도출로 이관', obs?.summary ?? '') + `\n` +
      recordRoundCmd(round, goal, obs, cls?.category ?? 'unknown', null, null,
                     'stall', analystNewFacts, false),
      OK_SCHEMA)
    continue
  }

  // Prefer the classifier's ranking; fall back to the owner named in the derived
  // table. An unknown category with a derived owner still gets a real attempt -
  // the fixer can answer not_mine, and that answer is a fact we can record,
  // unlike a round where nobody was asked at all.
  // The supervisor prescribes first: it read the machine sources and the derived
  // facts this round, which the classifier does not do. Its pick only counts if
  // the fixer exists on this track.
  const prescribed = KNOWN_FIXERS.includes(sup?.prescribed_fixer)
    ? sup.prescribed_fixer : null

  // The whole candidate list, in order of authority: the supervisor's
  // prescription (it read the sources and the derived facts this round), then
  // the classifier's ranking, then the owner named in the derived table.
  // Only rank 1 used to be asked, so a ranking of three was decoration and one
  // decline ended the round. Ranks 2 and 3 exist precisely because the first
  // guess about ownership can be wrong.
  const candidates = []
  const addCandidate = f => {
    if (f && KNOWN_FIXERS.includes(f) && !candidates.includes(f)) candidates.push(f)
  }
  addCandidate(prescribed)
  ranked.forEach(r => addCandidate(r?.fixer))
  addCandidate(derivedOwner)

  if (prescribed) {
    log(`[루프] 회차 ${round}: supervisor 처방 — ${prescribed}`)
  } else if (!ranked.length) {
    log(`[루프] 회차 ${round}: 분류는 unknown 이지만 도출표가 ${candidates[0]} 를 담당으로 지목 — 넘깁니다.`)
  }

  let fix = null
  let chosen = candidates[0]
  const declined = []
  for (const candidate of candidates.slice(0, 3)) {
    chosen = candidate
    const attempt = await agent(
      `Round ${round}, goal ${goal}. Classification: ${cls?.category}\n` +
      `Evidence: ${JSON.stringify(cls?.evidence ?? {})}\n` +
      `Fingerprint: ${fingerprintText(obs)}\n` +
      `Originating exception block: ${obs?.origin_block}\n` +
      `Derived facts: ${staticDoc}  (read it - the analyst appends there every round)\n` +
      `Stop points derived for this firmware:\n${derivedTable}\n` +
      `If one of these matches the fingerprint, apply its "시도할 변경" - it was ` +
      `derived from this exact target with evidence attached.\n` +
      (declined.length
        ? `Already declined this round: ${declined.join('; ')}. You are next in the ` +
          `ranking, so read the mechanism yourself before assuming it is not yours.\n`
        : '') +
      (sup?.treatment_plan
        ? `Supervisor's treatment plan: ${sup.treatment_plan}\n` +
          `That is a direction, not a patch. If it does not hold up against what you ` +
          `read, say so - you own this change, and you are the one who answers ` +
          `no_new_change.\n`
        : '') +
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
      { agentType: candidate, schema: FIXER_SCHEMA, label: `${candidate}-${round}`, phase: 'Loop' }
    )
    if (attempt && !attempt.not_mine && !attempt.no_new_change && attempt.change) {
      fix = attempt
      break
    }
    declined.push(`${candidate}(not_mine=${attempt?.not_mine === true}, ` +
                  `no_new_change=${attempt?.no_new_change === true})`)
    log(`[루프] 회차 ${round}: ${candidate} 반려 ` +
        `(담당아님=${attempt?.not_mine === true}, 새 시도 없음=${attempt?.no_new_change === true})`)
  }

  if (!fix) {
    // Every ranked specialist declined, so the fault has no owner among the
    // domains. The general fixer takes it instead: it has no domain boundary and
    // may edit, build and run, so a mechanism that crosses what the domains
    // split apart can be treated in one round.
    //
    // It is reached only here, never by ranking, so the widest scope stays the
    // exception rather than the default.
    const gen = await runGeneralFixer(round, goal,
      `Every ranked specialist declined this stop point (${declined.join('; ')}), ` +
      `so it has no owner among the specialists.`,
      sup?.treatment_plan, obs, cls, derivedTable)

    if (!gen || gen.no_new_change || !gen.change_key) {
      log(`[루프] 회차 ${round}: fixer-general 도 새로 시도할 변경이 없습니다.`)
      await shell(`decline-${round}`, 'Loop',
        journalTryEnd(round, cls?.category ?? 'unknown',
                      `전문가 전원 반려(${declined.join('; ')}) 후 fixer-general 도 시도할 변경 없음`,
                      '도출로 이관', obs?.summary ?? '') + `\n` +
        recordRoundCmd(round, goal, obs, cls?.category, GENERAL_FIXER, null,
                       'stall', analystNewFacts, true),
        OK_SCHEMA)
      continue
    }

    if (gen.build_ok === false) {
      await shell(`general-build-blocker-${round}`, 'Loop',
        `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
        `detail=${shq(`회차 ${round} fixer-general 재빌드 실패`)}`,
        OK_SCHEMA)
      stopped = true; stopReason = 'BLOCKED_BUILD'
      break
    }

    log(`[루프] 회차 ${round}: ★ fixer-general 이 처리 — ${gen.mechanism ?? ''}`)
    await shell(`general-record-${round}`, 'Loop',
      `echo ${shq(gen.one_line_progress ?? '')} >> "${workdir}/PROGRESS.md"\n` +
      journalTryEnd(round, cls?.category ?? 'unknown',
                    gen.rationale ?? gen.mechanism ?? '',
                    (gen.changes ?? []).map(c => `${c.file}: ${c.what}`).join(' / '),
                    obs?.summary ?? '') + `\n` +
      recordRoundCmd(round, goal, obs, cls?.category, GENERAL_FIXER, gen.change_key,
                     'applied', analystNewFacts, false),
      OK_SCHEMA)
    roundLog.push({ round, goal, category: cls?.category, fixer: GENERAL_FIXER,
                    change_key: gen.change_key })
    continue
  }

  const applied = await shell(`apply-${round}`, 'Loop',
    `# 1) One-change gate. On violation the edit is rolled back and the round is void.\n` +
    `bash "${PLUGIN}/scripts/check_change.sh" "${workdir}" verify; GATE=$?\n` +
    `if [ $GATE -ne 0 ]; then bash "${PLUGIN}/scripts/check_change.sh" "${workdir}" restore; fi\n` +
    `# 2) Carry the edit into the tree ninja compiles. The fixer edits\n` +
    `#    06_machine/machine.c; hw/arm/ holds the copy that is actually built.\n` +
    `#    Without this the round rebuilds and runs the PREVIOUS binary, the\n` +
    `#    fingerprint does not move, and a fix that was never in the image is\n` +
    `#    recorded as futile.\n` +
    `bash "${PLUGIN}/scripts/sync_machine.sh" "${workdir}" ${machine}; SYNC=$?\n` +
    `# 3) Rebuild. Report build errors verbatim; never guess a fix.\n` +
    `if [ $SYNC -eq 0 ]; then cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64; ` +
    `else echo "SYNC FAILED - 빌드를 건너뜁니다 (sync_ok=false 로 보고하세요)"; fi\n` +
    `# 4) Human-readable one-line history\n` +
    `echo ${shq(fix?.one_line_progress ?? '')} >> "${workdir}/PROGRESS.md"\n` +
    `# 5) Journal entry\n` +
    journalTryEnd(round, cls?.category ?? '', fix?.rationale ?? '',
                  fix?.change?.description ?? '', obs?.summary ?? '') + `\n` +
    `# 6) Machine-readable round record - exactly one line per round.\n` +
    `#    The branch is bash, not a judgement call: recording both would put two\n` +
    `#    identical fingerprints in rounds.jsonl and fake a stall.\n` +
    `if [ $GATE -eq 0 ]; then\n` +
    `  ` + recordRoundCmd(round, goal, obs, cls?.category, chosen, fix?.change_key,
                          'applied', analystNewFacts, false) + `\n` +
    `else\n` +
    `  ` + recordRoundCmd(round, goal, obs, cls?.category, chosen, fix?.change_key,
                          'reverted', analystNewFacts, false) + `\n` +
    `fi\n` +
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" metric phase=Loop round=${round} ` +
    `event=apply_end tokens_total=${budget.spent()}\n` +
    `\n# Report gate_pass from the check_change JSON, sync_ok from the ` +
    `sync_machine.sh JSON (synced/unmapped), and build_ok from ninja.`,
    APPLY_SCHEMA)

  if (applied && applied.gate_pass === false) {
    log(`[루프] 회차 ${round}: ★ 한 변경 검문 불통과 — ${applied.gate_reason ?? ''} (되돌렸습니다)`)
  }
  if (applied && applied.sync_ok === false) {
    // The edit never reached the tree that gets compiled, so the next round
    // would measure the previous binary and read the fix as futile. That is a
    // setup fault, not a firmware verdict - stop and say so.
    await shell(`sync-blocker-${round}`, 'Loop',
      `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
      `detail=${shq(`회차 ${round} 머신 소스를 QEMU 트리로 반영하지 못했습니다: ${applied.sync_reason ?? ''}`)}`,
      OK_SCHEMA)
    log(`★ 정지 — 머신 소스가 QEMU 트리에 반영되지 않았습니다 (${applied.sync_reason ?? ''}). ` +
        `이 상태로 계속하면 고쳐도 이전 바이너리를 측정합니다.`)
    stopped = true; stopReason = 'BLOCKED_BUILD'
    break
  }
  if (applied && applied.build_ok === false) {
    await shell(`build-blocker-${round}`, 'Loop',
      `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
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
    `bash "${PLUGIN}/scripts/py.sh" stop_conditions.py "${workdir}" --ladder "${ladderArg}"\n` +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
    `${shq(`정지: ${stopReason} — 구조상 목표 도달 불가. 재개 가능합니다.`)}`,
    {
      type: 'object',
      properties: {
        best_milestone: { type: ['string', 'null'] },
        best_progress: { type: 'object' },
        tried_changes: { type: 'array' },
      },
    })
  // A one-rung ladder leaves best_milestone null even after the boot walked a
  // long way, so the depth measure is reported alongside it. Saying only "최고
  // 마일스톤: 없음" about a run that got the firmware through PMIC and into
  // storage init is accurate and still misleading.
  const depth = summary?.best_progress ?? {}
  log(`★ 정지 — ${stopReason}. 도달한 최고 마일스톤: ${summary?.best_milestone ?? '없음'}` +
      (depth?.uniq ? ` · 최고 부팅 깊이: 콘솔 고유 ${depth.uniq} 줄 (회차 ${depth.round ?? '-'})` : ''))
  return {
    success: false, stopped: true, stop_reason: stopReason,
    rounds_run: round, goals, reached_goals: goals.slice(0, goalIndex),
    best_milestone: summary?.best_milestone ?? null,
    best_progress: depth,
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
  `bash "${PLUGIN}/scripts/py.sh" verify.py "${workdir}" --track ${track} --target ${target}` +
  // The command the harness types. Item 4 fails if the machine sources contain
  // it, on either surface: a machine that supplies its own input is verifying
  // itself, whether the surface is a UART shell or a USB dispatcher.
  (track === 1
    ? ` --bl3 "${bootloader_path}" --surface ${activeSurface} ` +
      `--input-token ${shq(activeSurface === 'fastboot' ? 'getvar:' : 'help')}`
    : '')

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
  `   bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" metric phase=Verify ` +
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
