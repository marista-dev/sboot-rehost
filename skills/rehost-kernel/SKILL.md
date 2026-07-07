---
name: rehost-kernel
description: 트랙 2 (kernel-storage) 본격 실행. INPUT.md(track 2) 가 있는 상태에서 workflows/pipeline_kernel.js 호출 → 부팅 자산 + DTB 골격 정적분석 → machine_kernel.c + 코어/커널 패치 + ninja → K1(유저스페이스) → K2(rootfs 마운트) → K3(진짜 벤더 스토리지 HCI 관찰 루프) → 5/5 검증 → 재현 키트. /rehost-init(트랙 2) 선행. 진짜 커널·벤더 드라이버를 QEMU 에서 실행.
---

당신은 트랙 2 (커널 직부팅 + 진짜 벤더 스토리지 HCI) 실행 오케스트레이터.
`/rehost-kernel` 호출 시 **workflows/pipeline_kernel.js 를 호출**해 자산→골격→K1→K2→K3→
검증→재현 키트를 자동 진행. (트랙 1 은 `/rehost-sboot`.)
방법론: methodology/track2_kernel_storage.md.

---

## Step 0 — 선행 조건 검사

1. **INPUT.md 존재 + `track: 2`**:
   - 없으면: "/rehost-init 을 먼저 호출하세요" 안내 후 종료
   - `track: 1` 이면: "이 펌웨어는 트랙 1 입니다. `/rehost-sboot` 을 호출하세요" 안내 후 종료
2. **부팅 자산**: `fw/Image`(+dtb, initrd) 존재. 없으면 `scripts/extract_boot_assets.sh` 안내.
   - target=K2/K3 이면 `super_path` (rootfs) 도 확인.
   - target=K3 이면 `storage_driver_ko` (벤더 .ko) 필수 — 빈칸이면 "K3 은 벤더 드라이버
     필수. K2 로 낮추거나 .ko 확보 후 재호출" 안내 (critic 신호 4).
3. **의존성 OK**: `which qemu-system-aarch64`, `python3`, `dtc`/`fdtdump`. 미설치면 안내.

---

## Step 0.5 — JOURNAL 세션 시작 (필수, CLAUDE.md 실행 기록)

선행 조건 통과 즉시:
```
bash <PLUGIN>/scripts/journal.sh <workdir> session-start "/rehost-kernel" "track 2, target <K1/K2/K3>"
```
pipeline_kernel.js 는 각 phase 를 `phase`, 매 K1/K3 회차(정지점/벽)를 `try-start`/`try-end`
(원인/분석/해결) 로 기록. 명령이 끝나면 반드시 `session-end`.

---

## Step 1 — workflows/pipeline_kernel.js 호출

```
Workflow({
  scriptPath: '<PLUGIN_DIR>/workflows/pipeline_kernel.js',
  args: {
    workdir: '<INPUT.md workdir>', model: '<INPUT.md model>',
    target: '<INPUT.md target K1/K2/K3>', max_iterations: 30,
  }
})
```

pipeline_kernel.js phase (등급까지만 진행):

### Phase Static — kernel-boot-analyzer
- 부팅 자산 확인 + DTB 로 머신 골격 (cpu/dram/gic/uart/storage_hci_base/cmdline) 도출
- 커널 보안게이트 사이트 (fips/defex/selinux/avb/early_module) 심볼 xref + pre-image 검증
- 결과: KERNEL_STATIC.md

### Phase Machine
- templates/machine_kernel.c.tmpl 채움 → 06_machine/machine_kernel.c
- patch_qemu_core.py (SMC 코어 3패치, 멱등) + patch_kernel.py (게이트 사이트)
- (K3) storage_hci.c.tmpl 도 등록. QEMU 통합 + ninja. 빌드 에러 그대로 보고.

### Phase K1 — 유저스페이스 (boot-fault-fixer)
- run_kernel.sh 회차. 정지점 (panic/smc/gic/unmapped/rootfs) 분류 → 한 변경.
- `Run /init` 도달 시 다음. target=K1 이면 여기서 검증.

### Phase K2 — rootfs 마운트
- 제네릭+DT fstab (§6.1) 또는 dm-linear supermount (§6.2). 커널 메시지
  `erofs: (device dm-N): mounted` (system+vendor) 확인.

### Phase K3 — 진짜 벤더 스토리지 HCI (storage-modeler)
- EUFS_LU_IMAGE/EUFS_LBS 세팅 후 진짜 벤더 .ko 부팅. 관찰 루프 (§7.3 함정표):
  회차마다 벽 분류 + 한 변경 (로그로 안 보이면 .ko 역어셈블). `sda: sda1…` +
  `Power mode change` 도달 시 완료.

### Phase Verify / Package
- reality-verifier 트랙 2 5/5 (커널 메시지 증거). 5/5 = REAL → 10_reproduce/ 생성.

---

## Step 1.5 — JOURNAL 세션 종료 (필수)

파이프라인이 끝나면 (등급 도달 / FORCED / 에러 무관):
```
bash <PLUGIN>/scripts/journal.sh <workdir> session-end "/rehost-kernel" "<결과: 예 K3 partitions_up + system/vendor mounted, 회차 N>"
```

---

## Step 2 — 진행 보고

pipeline_kernel.js 가 phase/회차 전환마다 log. 그대로 사용자에게 (`[Phase K1] kboot 3: smc undef → PSCI 셤` 등).

## Step 3 — critic / 프론티어 (자율 자동 결정)

INPUT.md `autonomous: true` (기본) 이면 `AskUserQuestion` 없이 CLAUDE.md 자율 정책으로:
- 위기 5 신호 (트랙 2): 기본 **계속** + `recommended_action` 적용. **하드 블로커** (신호 4
  target=K3 인데 `.ko` 부재) → 중단 + 보고. `journal.sh decision` 기록.
- **TEE 프론티어** (`/data`·vold·Keymint·TEEGRIS): 자동으로 **미달로 정직 기록** 후 도달 등급까지
  마무리 (시큐어월드 에뮬은 범위 밖). `journal.sh decision "TEE 프론티어" "미달 기록 후 마무리" "범위 밖"`.
- `autonomous: false` 면 보고 + AskUserQuestion.

## Step 4 — 5/5 미달 (자율 자동 결정)

reality-verifier FORCED 판정 시:
- **자율 모드**: K1~K3 회차가 max 까지 돌았으면 **FORCED 로 마무리** (10_reproduce 생성,
  **REAL 표기 금지**). 실패 항목 보고 + `journal.sh decision "verification" "FORCED 마무리" "max 회차 소진"`.
- **interactive 모드**: AskUserQuestion ("추가 회차 / 항목 수정 / 마무리").

---

## 정직성

- 커널·벤더 드라이버는 **진짜 실행**. 모델은 환경 (페리페럴/SMC/HVC/HCI) 만.
- 성공은 **커널이 찍은 줄** (`erofs: (dm-N): mounted` / `sda1` / `Power mode change`) 로만.
  머신 `qemu_log` 문자열 불인정.
- 커널·`.ko` 패치는 pre-image 검증 + `[대상/이유/방법/부작용]`. 적응형 토글 금지.
- `kvm-arm.mode=protected` 시 HVC 는 커널 내장 pKVM — 셤이 가로채면 안 됨.
- pipeline_kernel.js 에러 시 traceback 그대로.

## 에이전트 (pipeline_kernel.js)

| Agent | Phase | 역할 |
|---|---|---|
| kernel-boot-analyzer | Static | DTB 골격 + 커널 게이트 사이트 도출 |
| boot-fault-fixer | K1/K2 | 커널 정지점 (panic/smc/gic/rootfs) → 한 변경 |
| storage-modeler | K3 | 벤더 스토리지 HCI 관찰 루프 (§7.3, .ko 역어셈블) |
| reality-verifier | Verify | 트랙 2 5/5 (커널 메시지 증거) |
