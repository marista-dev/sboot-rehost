/*
 * pipeline_kernel.js — 트랙 2 (커널 직부팅 + 진짜 벤더 스토리지 HCI) 파이프라인.
 * /sboot-rehost:rehost-kernel (트랙 2) 이 호출. methodology/track2_kernel_storage.md 를 따른다.
 *
 * Phase 1 Static  : 부팅 자산 확인 + kernel-boot-analyzer (DTB 골격 + 커널 게이트)
 * Phase 2 Machine : machine_kernel.c 생성 + QEMU 코어 3패치 + 커널 패치 + ninja
 * Phase 3 K1      : boot-fault-fixer 회차 -> 유저스페이스 (Run /init)
 * Phase 4 K2      : rootfs 마운트 (제네릭+fstab 또는 dm-linear)
 * Phase 5 K3      : storage-modeler 관찰 루프 -> 진짜 벤더 드라이버 파티션 구동
 * Phase 6 Verify  : reality-verifier (트랙 2 5/5, 커널 메시지 증거)
 * Phase 7 Package : 재현 키트
 *
 * args: { workdir, model, target(K1|K2|K3), max_iterations, ... }
 */
export const meta = {
  name: 'pipeline-kernel',
  description: '트랙 2 — 커널 직부팅 + 벤더 스토리지 HCI: 자산 -> 골격 -> K1 -> K2 -> K3 -> 검증',
  phases: [
    { title: 'Static',  detail: 'kernel-boot-analyzer (DTB 골격 + 커널 게이트)' },
    { title: 'Machine', detail: 'machine_kernel.c + 코어/커널 패치 + ninja' },
    { title: 'K1',      detail: 'boot-fault-fixer -> 유저스페이스' },
    { title: 'K2',      detail: 'rootfs 마운트' },
    { title: 'K3',      detail: 'storage-modeler 관찰 루프 (링크업→전원모드→SCSI→파티션)' },
    { title: 'K3-capstone', detail: 'super system/vendor 마운트 (dm-linear)' },
    { title: 'Verify',  detail: '트랙 2 5/5' },
    { title: 'Package', detail: '재현 키트' },
  ],
}

// K3 완전 UFS 컨트롤러 마일스톤 사다리 (2400 검증 도달점). 목표=partitions_up + (캡스톤)super_mounted.
// 부분 도달은 절대 "완료" 아님 — 최고 마일스톤을 정직히 보고.
const K3_LADDER = ['link_up', 'power_mode', 'scsi_attach', 'partitions_up']

const workdir  = args?.workdir
const model    = args?.model
const target   = (args?.target || 'K2').toUpperCase()   // K1 | K2 | K3
const MAXIT    = args?.max_iterations ?? 30
if (!workdir || !model) { log('ERROR: workdir/model 필요'); return { error: 'missing_args' } }
const machine = `${model.toLowerCase().replace(/[^a-z0-9]/g,'')}-kernel`
const want = { K1: 1, K2: 2, K3: 3 }[target] ?? 2

// ---- Phase 1: Static ----
phase('Static')
const st = await agent(
  `먼저 단계 기록: bash <PLUGIN>/scripts/journal.sh ${workdir} phase "Static (kernel-boot-analyzer)".
   그 다음 INPUT.md (${workdir}/INPUT.md) 의 부팅 자산 확인 + DTB 로 머신 골격 (cpu/dram/gic/uart/
   storage_hci_base/cmdline) 도출 + 커널 보안게이트 패치 사이트 (fips/defex/selinux/avb/
   early_module) 를 심볼·문자열 xref 로 도출. KERNEL_STATIC.md 작성. pre-image 검증. 미확정은 "미확정".`,
  { agentType: 'kernel-boot-analyzer', label: 'kanalyze', phase: 'Static',
    schema: { type:'object', properties:{
      assets_ok:{type:'boolean'}, storage_hci_base:{type:['string','null']},
      pkvm:{type:'boolean'}, gate_sites:{type:'integer'}, undefined_count:{type:'integer'} },
      required:['assets_ok'] } })
if (!st?.assets_ok) { log('★ 부팅 자산 미확보 — extract_boot_assets.sh 필요'); return { error:'assets_missing', st } }
log(`골격 도출 완료: gate_sites=${st.gate_sites}, pKVM=${st.pkvm}, HCI=${st.storage_hci_base ?? 'n/a'}`)

// ---- Phase 2: Machine ----
phase('Machine')
await agent(
  `먼저 단계 기록: bash <PLUGIN>/scripts/journal.sh ${workdir} phase "Machine (build + patches)".
   templates/machine_kernel.c.tmpl 의 슬롯을 KERNEL_STATIC.md 값으로 채워
   ${workdir}/06_machine/machine_kernel.c 작성 (machine "${machine}").
   그 후:
   1. python3 scripts/patch_qemu_core.py  (SMC->EXCP_SMC 코어 3패치, 멱등)
   2. python3 scripts/patch_kernel.py fw/Image fw/Image.patched <KERNEL_STATIC 사이트 json>
   3. machine_kernel.c 를 ~/qemu-build/qemu-10.2.2/hw/arm/ 로, meson.build 등록
   4. ${want>=3 ? 'templates/storage_hci.c.tmpl 로 <hci>.c 도 함께 등록 (K3)' : '(K3 아님, HCI 생략)'}
   5. cd build && ninja qemu-system-aarch64. 빌드 에러 시 그대로 보고 (추측 수정 금지)
   6. -M help | grep ${machine} 로 등록 확인`,
  { label: 'kmachine-build', phase: 'Machine' })

// ---- Phase 3: K1 (유저스페이스) ----
phase('K1')
let reached = false
for (let i = 1; i <= MAXIT; i++) {
  const run = await agent(
    `회차 K1-${i}:
     1) 시작 기록 (필수): bash <PLUGIN>/scripts/journal.sh ${workdir} try-start k1-${i} "K1 회차 ${i} 부팅"
     2) bash <PLUGIN>/scripts/run_kernel.sh ${workdir} ${machine} ${i} 실행 후 (console=·summary= 로컬,
        trace= WSL 출력) 07_logs/kboot_${i}.txt + summary 확인. faults + 'Run /init' 등장 여부 한 줄 보고.`,
    { label:`k1-run-${i}`, phase:'K1' })
  log(`K1-${i}: ${run}`)
  const fix = await agent(
    `회차 K1-${i} 정지점 분류 + 한 변경. 입력(로컬): 07_logs/kboot_${i}.txt + kboot_${i}.summary.txt,
     KERNEL_STATIC.md, 06_machine/machine_kernel.c (전체 트레이스는 run_kernel.sh 의 trace= 경로(WSL)).
     유저스페이스 도달 시 category="reached_userspace".
     ★ 분류 직후 완료 기록 (필수):
       bash <PLUGIN>/scripts/journal.sh ${workdir} try-end k1-${i} \\
         "<원인=category+fault>" "<분석=rationale>" "<해결=patch_desc, reached_userspace 이면 '유저스페이스 도달'>" \\
         "07_logs/kboot_${i}.summary.txt (로컬); 전체 트레이스 WSL"`,
    { agentType:'boot-fault-fixer', label:`k1-fix-${i}`, phase:'K1',
      schema:{ type:'object', properties:{ category:{type:'string'},
        one_line_progress:{type:'string'}, patch_type:{type:'string'} }, required:['category'] } })
  if (!fix) { log('boot-fault-fixer 결과 없음, 중단'); break }
  if (fix.category === 'reached_userspace') { reached = true; log(`★ K1-${i}: 유저스페이스 도달`); break }
  await agent(
    `회차 K1-${i} 패치 적용: ${fix.patch_type} / ${fix.one_line_progress}. machine_kernel.c 또는
     patch_kernel.py 사이트 또는 smc_handler 수정 -> 재빌드 (필요 시). PROGRESS.md 한 줄 + 우회목록.`,
    { label:`k1-apply-${i}`, phase:'K1' })
}
if (want === 1) return { success: reached, stopped_at: 'K1', reached_userspace: reached }
if (!reached)   return { error: 'K1_not_reached' }

// ---- Phase 4: K2 (rootfs 마운트) ----
phase('K2')
const k2 = await agent(
  `rootfs 마운트 (target ${target}).
   시작 기록: bash <PLUGIN>/scripts/journal.sh ${workdir} try-start k2 "rootfs 마운트".
   §6.1 제네릭+DT fstab 또는 §6.2 dm-linear supermount 중 INPUT.md 방식으로. run_kernel.sh 로
   부팅 -> 커널 메시지 'erofs: (device dm-N): mounted' (system+vendor) 확인. 안 되면
   boot-fault-fixer 로 category=rootfs_mount 회차. 결과 보고.
   완료 기록: bash <PLUGIN>/scripts/journal.sh ${workdir} try-end k2 \\
     "<원인: rootfs 미마운트 사유 또는 '해당없음'>" "<분석: 방식/정지점>" \\
     "<해결: 마운트 성공 방식 또는 미해결>" "07_logs/kboot_최근.summary.txt (로컬)"`,
  { agentType:'boot-fault-fixer', label:'k2', phase:'K2',
    schema:{ type:'object', properties:{ mounted:{type:'boolean'}, evidence:{type:'string'} } } })
log(`K2: rootfs mounted=${k2?.mounted}`)
if (want === 2) {
  // Verify + Package (K2)
} else if (!k2?.mounted) {
  log('K2 미마운트 — K3 진행 전 rootfs 필요할 수 있음 (경로 A 는 무관)')
}

// ---- Phase 5: K3 (진짜 벤더 스토리지 HCI — 완전 컨트롤러) ----
// 목표: 관찰 루프가 링크업→전원모드→SCSI→진짜 GPT 파티션(sda1..)까지 구동 (K3a),
//       그리고 캡스톤(super system/vendor 마운트)까지 (K3b). 부분 도달은 "완료" 아님.
let k3best = null, partitions = false, superMounted = false
if (want >= 3) {
  phase('K3')
  // K3a: 컨트롤러 구동 관찰 루프 (마일스톤 사다리 — partitions_up 까지 계속)
  for (let i = 1; i <= MAXIT; i++) {
    const run = await agent(
      `회차 K3-${i}:
       1) 시작 기록: bash <PLUGIN>/scripts/journal.sh ${workdir} try-start k3-${i} "K3 회차 ${i} 벤더 .ko 부팅"
       2) EUFS_LU_IMAGE/EUFS_LBS 세팅 후 진짜 벤더 .ko 부팅 (storage/run_exynos_ufs_clk.sh 상당).
          07_logs/kboot_${i}.txt + summary 확인. 도달 최고 마일스톤 보고 (사다리):
          link_up(=scsi host0: ufshcd) < power_mode(=Power mode change) <
          scsi_attach(=[sda] Attached) < partitions_up(=sda: sda1..).`,
      { label:`k3-run-${i}`, phase:'K3' })
    log(`K3-${i}: ${run}`)
    const w = await agent(
      `회차 K3-${i} 스토리지 벽 분류 (§7.3 함정표) + 한 변경 관찰. 입력(로컬): 07_logs/kboot_${i}.txt +
       kboot_${i}.summary.txt (전체 트레이스는 WSL trace= 경로). 로그로 안 보이면 .ko 역어셈블.
       milestone_reached = 이번 부팅의 최고 마일스톤 (link_up|power_mode|scsi_attach|partitions_up|none).
       ★ try-end 기록:
         bash <PLUGIN>/scripts/journal.sh ${workdir} try-end k3-${i} \\
           "<원인=wall_category>" "<분석=observation>" "<해결=change_desc; milestone_reached>" \\
           "07_logs/kboot_${i}.summary.txt (로컬); 전체 트레이스 WSL"`,
      { agentType:'storage-modeler', label:`k3-obs-${i}`, phase:'K3',
        schema:{ type:'object', properties:{ wall_category:{type:'string'},
          milestone_reached:{type:['string','null']}, one_line_progress:{type:'string'} },
          required:['wall_category'] } })
    if (!w) break
    if (w.milestone_reached && K3_LADDER.indexOf(w.milestone_reached) > K3_LADDER.indexOf(k3best ?? 'none'))
      k3best = w.milestone_reached
    if (w.milestone_reached === 'partitions_up') { partitions = true; log(`★ K3-${i}: 진짜 GPT 파티션 sda1..`); break }
    await agent(
      `회차 K3-${i} 스토리지 모델 한 변경 적용: ${w.one_line_progress}. <hci>.c 또는 .ko 우회
       수정 -> 재빌드. PROGRESS.md 한 줄 + 우회목록. 추측/토글 금지.`,
      { label:`k3-apply-${i}`, phase:'K3' })
  }
  log(`K3a: 최고 마일스톤=${k3best ?? 'none'}, partitions=${partitions}`)

  // ★ 파티션 미도달 = UFS 컨트롤러 미완성 → 정직 부분 보고 (여기서 종료, "완료"·success 금지)
  if (!partitions) {
    await agent(`bash <PLUGIN>/scripts/journal.sh ${workdir} decision "K3 완료여부" "미완(부분)" "최고 마일스톤 ${k3best ?? '링크 이전'}, 진짜 파티션 미도달"`,
      { label:'k3-partial', phase:'K3' })
    return { success:false, partial:true, phase_completed:'K3', highest_milestone:k3best, partitions:false,
      note:`★ UFS 컨트롤러 미완성 — 최고 도달 '${k3best ?? '링크 이전'}', 진짜 파티션(sda1..) 미도달. "완료" 아님. §7.3 다음 벽 처치 또는 max_iterations 올려 재실행 필요.` }
  }

  // K3b 캡스톤: super system/vendor 마운트 (dm-linear, storage/run_path2_supermount.sh 상당)
  phase('K3-capstone')
  const cap = await agent(
    `K3 캡스톤 (진짜 컨트롤러가 실제 파일시스템까지 구동): supermount(dm-linear) init 으로 super 의
     system/vendor 를 EROFS 마운트. 커널 메시지 'erofs: (device dm-0): mounted' + '(dm-4): mounted' +
     'supermount: SUCCESS' 확인. 안 되면 storage-modeler 로 비동기 프로브 타이밍(§7.3 8번) 회차 (max ${MAXIT}).
     시작·완료 기록 (journal try-start/try-end k3cap).`,
    { agentType:'storage-modeler', label:'k3-capstone', phase:'K3-capstone',
      schema:{ type:'object', properties:{ mounted:{type:'boolean'}, evidence:{type:'string'} } } })
  superMounted = !!cap?.mounted
  log(`K3 캡스톤 super mount=${superMounted}`)
  await agent(`bash <PLUGIN>/scripts/journal.sh ${workdir} decision "K3 캡스톤" "${superMounted?'super 마운트 성공':'super 마운트 미완'}" "erofs dm-0/dm-4 + supermount SUCCESS"`,
    { label:'k3-cap-journal', phase:'K3-capstone' })
}

// ---- Phase 6: Verify ----
phase('Verify')
const k3req = want >= 3
  ? `★ K3 목표이므로 5/5 는 진짜 파티션(sda: sda1..) + 드라이버 진짜 구동(UTRD/Query/SCSI) 이
     필수. 캡스톤 super 마운트(erofs dm-0/dm-4)까지 있으면 완전. 이 증거가 없으면 K1/K2 만으로
     통과 처리 금지 (그건 UFS 컨트롤러 미완).`
  : ``
const v = await agent(
  `${workdir} 최근 07_logs 콘솔 + 06_machine 소스를 트랙 2 5/5 로 검증 (CLAUDE.md 트랙 2 표).
   커널 메시지 증거 (Run/init / erofs dm-N / sda1 / Power mode) + 소스 negative + 드라이버 진짜 구동 +
   우회 목록. VERIFICATION.md 작성. 등급 도달=${target}. ${k3req}`,
  { agentType:'reality-verifier', label:'verify', phase:'Verify',
    schema:{ type:'object', properties:{ passes:{type:'integer'}, verdict:{type:'string'},
      failed_items:{type:'array'} }, required:['passes','verdict'] } })
log(`검증: ${v?.passes ?? '?'}/5 (${v?.verdict ?? '?'})`)
if (!v || v.passes < 5) return {
  success:false, phase_completed:'Verify', verify:v, target,
  highest_milestone: want>=3 ? k3best : target, partitions, super_mounted:superMounted,
  note:'FORCED/미완 — 5/5 미통과. "완료" 아님. REAL 금지.' }

// ---- Phase 7: Package ----
phase('Package')
await agent(
  `${workdir}/10_reproduce/ 생성: README + fw 자산 참조 + machine_kernel.c(+<hci>.c) 복사 +
   scripts (patch_qemu_core/patch_kernel/run_kernel) 복사 + evidence (콘솔 + VERIFICATION.md).`,
  { label:'package', phase:'Package' })

// 완료 보고 — K3 는 파티션까지 필수, 캡스톤(super 마운트)은 있으면 "완전"
const k3done = want < 3 || partitions
return {
  success: k3done, track:2, target, verify:v,
  partitions, super_mounted:superMounted,
  ufs_controller: want>=3 ? (superMounted ? 'complete (partitions + super mount)'
                              : partitions ? 'partitions only (캡스톤 super 마운트 미완)'
                              : 'incomplete') : 'n/a',
  reproduce_dir:`${workdir}/10_reproduce/` }
