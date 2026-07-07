/*
 * iter-loop.js — sboot-rehost 의 회차 루프 워크플로우
 *
 * 매 회차: qemu 실행 → fault 분류 → 패치 적용 → critic 점검 → 다음
 * 한 회차 한 변경 (instruction.md §7.3) 규칙 준수.
 *
 * args: { n: 회차 수, workdir: 작업 디렉터리, machine_name: QEMU -M 이름,
 *         bl3: BL3 파일 절대 경로, cmd: -append 명령 (default "help") }
 */

export const meta = {
  name: 'iter-loop',
  description: 'sboot-rehost 회차 루프 N 회 — qemu 실행 → fault 분류 → 패치 → critic 점검',
  phases: [
    { title: 'Iterate', detail: '회차마다 한 변경, 정직성 자가체크 7 항' },
  ],
}

const N = args?.n ?? 10
const workdir = args?.workdir
const machine_name = args?.machine_name
const bl3 = args?.bl3
const cmd = args?.cmd ?? 'help'

if (!workdir || !machine_name || !bl3) {
  log('ERROR: iter-loop requires args.workdir, args.machine_name, args.bl3')
  return { error: 'missing_args' }
}

phase('Iterate')

const FIX_SCHEMA = {
  type: 'object',
  properties: {
    category: { type: 'string' },
    fault_info: { type: 'object' },
    patch_type: { type: 'string' },
    patch_description: { type: 'string' },
    patch_target: { type: 'string' },
    patch_bytes: { type: ['string', 'null'] },
    rationale: { type: 'string' },
    one_line_progress: { type: 'string' },
    bypass_doc: { type: 'object' },
  },
  required: ['category', 'one_line_progress'],
}

const CRITIC_SCHEMA = {
  type: 'object',
  properties: {
    signal: { type: 'integer' },
    triggered: { type: 'boolean' },
    message: { type: 'string' },
    recommended_action: { type: 'string' },
  },
}

const results = []
let reached_shell = false

for (let i = 0; i < N; i++) {
  const run_n = await agent(
    `회차 ${i + 1}/${N} 실행.
     workdir=${workdir}, machine=${machine_name}, bl3=${bl3}, cmd="${cmd}".
     1) 회차 시작 기록 (필수, CLAUDE.md 실행 기록):
        bash <PLUGIN>/scripts/journal.sh ${workdir} try-start ${i + 1} "회차 ${i + 1} 실행"
     2) scripts/run_qemu.sh 호출:
        bash <PLUGIN>/scripts/run_qemu.sh ${workdir} ${machine_name} ${bl3} "${cmd}" ${i + 1}
     실행 후 ${workdir}/07_logs/console_${i + 1}.txt 와 run_${i + 1}.log 확인.
     예외 개수 + 콘솔 크기를 한 줄로 보고.`,
    { label: `run-${i + 1}`, phase: 'Iterate' }
  )

  log(`회차 ${i + 1}: ${run_n}`)

  const fix = await agent(
    `회차 ${i + 1} 의 fault 를 분류하고 한 변경 패치 제안.
     입력: ${workdir}/07_logs/run_${i + 1}.log
           ${workdir}/07_logs/console_${i + 1}.txt
           ${workdir}/STATIC.md, STUBS.md, PROGRESS.md
           ${workdir}/06_machine/machine.c
     출력: schema 형식.
     fault 없음 (0 예외 + 콘솔에 의미있는 ASCII) 이면 category="reached_shell".
     ★ 분류 직후 회차 완료 기록 (필수, CLAUDE.md 실행 기록):
       bash <PLUGIN>/scripts/journal.sh ${workdir} try-end ${i + 1} \\
         "<원인=category+fault_info>" "<분석=rationale>" "<해결=patch_description, reached_shell 이면 '셸 도달'>" \\
         "07_logs/run_${i + 1}.log"
     (원인/분석/해결 문자열은 큰따옴표로 감싸고 내부 따옴표는 이스케이프.)`,
    {
      agentType: 'fault-fixer',
      schema: FIX_SCHEMA,
      label: `fix-${i + 1}`,
      phase: 'Iterate',
    }
  )

  if (!fix) {
    log(`회차 ${i + 1}: fault-fixer 결과 없음. 중단.`)
    break
  }

  if (fix.category === 'reached_shell' || fix.category === 'none') {
    log(`★ 회차 ${i + 1}: 셸 도달 후보. fault 없음.`)
    reached_shell = true
    results.push({ iter: i + 1, ...fix })
    break
  }

  await agent(
    `회차 ${i + 1} 의 패치를 machine.c 에 적용:
     - patch_description: ${fix.patch_description}
     - patch_target: ${fix.patch_target}
     - patch_bytes: ${fix.patch_bytes ?? 'N/A (소스 수정)'}
     - rationale: ${fix.rationale}

     작업:
     1. ${workdir}/06_machine/machine.c 수정 (또는 wr32 패치 라인 추가)
     2. ${workdir}/PROGRESS.md 끝에 한 줄 추가: ${fix.one_line_progress}
     3. ${workdir}/06_machine/우회_패치_목록.md 에 bypass_doc 4 항 추가
     4. ~/qemu-build/qemu-10.2.2/build 에서 ninja qemu-system-aarch64 재빌드
     5. 빌드 에러 시 그대로 보고 (추측 수정 금지)`,
    { label: `apply-${i + 1}`, phase: 'Iterate' }
  )

  const cry = await agent(
    `회차 ${i + 1} 끝. 위기 5 신호 점검.
     workdir=${workdir}.`,
    {
      agentType: 'critic',
      schema: CRITIC_SCHEMA,
      label: `critic-${i + 1}`,
      phase: 'Iterate',
    }
  )

  if (cry?.triggered) {
    log(`${cry.message}\n  → ${cry.recommended_action}`)
  }

  results.push({ iter: i + 1, ...fix, critic: cry })
}

return {
  iterations_run: results.length,
  reached_shell,
  last_category: results[results.length - 1]?.category ?? 'unknown',
  results,
}
