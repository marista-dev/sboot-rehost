# 일반화 표 — sboot-rehost 의 모든 의사결정의 기준

> 이 문서는 새 펌웨어 어떤 것이 와도 그대로 적용 가능한 표 A~M (+ G2/H2, 양 트랙).
> A~I 는 트랙 1 (sboot-shell), J~M 은 트랙 2 (kernel-storage). 플러그인의 모든
> 산출물이 이 표의 어느 행과 매핑되는지 명시.

---

## Table A — 트랙 1 단계 흐름 (마스터)

> 트랙 1 (sboot-shell) 의 0~10 단계. 트랙 2 (kernel-storage) 의 흐름은 Table J~M +
> [track2_kernel_storage.md](track2_kernel_storage.md) 참조.

| 단계 | 사용자가 프롬프트에 주는 입력 | LLM 산출물 | 도구 | 검증 | 정직성 위반 신호 |
|---|---|---|---|---|---|
| **0. 타겟 식별** | 모델·SoC·빌드·md5·아키텍처·등급 (A/B/C) | 분석 폴더, 빌드 고정 | (입력만) | md5 PROGRESS 0회차 박힘 | 빌드 도중 펌웨어 섞임 |
| **1. 환경** | OS·QEMU 버전 | 빌드 스크립트, 버전 검증 | apt/pip/configure/ninja | qemu --version, capstone import | 추측 버전 |
| **2. 펌웨어 추출** | sboot.bin 위치 | sboot.bin + md5 | lz4/tar/dd | 매직/크기/ASCII | carve 인데 full 이라 주장 |
| **3. 정적 분석** | 분석 스크립트 골격 | entry/linker/load/Δ/cmd/head/shell 7 값 | capstone + 패턴 | 디스어셈블 근거 첨부 | 다른 펌웨어 값 차용 |
| **4. 보조 분석** | (3 결과) | vtable/heap/handoff/timeout 4 값 | string xref + 함수 패턴 | 호출자 디스어셈블 첨부 | 이름만 적고 위치 미상 |
| **5. 최소 머신** | (3,4 결과) | sboot_<model>.c | C 코딩 | ninja + -M help 등록 | placeholder 만 채움 |
| **6. 첫 정지점** | (5 결과) | run_0.txt + 첫 fault 분류 | qemu -d int,in_asm | 트레이스 + FAR/ELR | 에러 무시 |
| **7. 회차 루프** | (정지점) | 한 줄 PROGRESS + 한 변경 | Table F | 다음 회차 fault 변경 | 한 회차 다중 변경 |
| **8. 셸 도달** | (트레이스에 shell PC) | console_N.txt | -serial file: | UART 에 ASCII 등장 | 머신이 자가주입 |
| **9. 검증** | (UART 파일) | 5/5 검증 보고서 | grep/diff/strings | 5 항목 통과 | 위반 은폐 |
| **10. 재현 키트** | (모든 결과) | 5 분 내 재현 폴더 | bash + diff | 별 환경 MATCH | "내 환경에서만" |

---

## Table B — 0 차 입력 (사용자 프롬프트의 첫 메시지 슬롯)

| 정보 | 형식 | 왜 필요 | 없으면 |
|---|---|---|---|
| 모델 식별자 | `SM-NNNNX` | 분석 폴더·산출물 경로 | 다른 모델 혼동 |
| SoC | 이름 + ARMv? | CPU type / has_el3 결정 | capstone 모드 오선택 |
| 빌드 ID | 문자열 | 같은 모델 다른 빌드 = 다른 주소 | 회차 값 안 맞음 |
| 펌웨어 md5 | 32 hex | 모든 주소의 anchor | 1 byte 변동 = 전 분석 무효 |
| 캐리어 | OKR/KOO/UNL | 다운로드 경로만 | (도출엔 무관) |
| 목표 등급 | A/B/C | 우회 vs 모델 비율 | 시간 낭비 |
| has_el3/el2 | 가설 (수정 가능) | reset hook + scr | 첫 회차 fault 오해 |
| 참조 자산 | 경로 목록 | 청사진 차용 | 30+ 회차 whack-a-mole |
| 작업 디렉터리 | 절대 경로 | 산출물 위치 | LLM 임의 위치 사용 |

---

## Table C — 정적 분석 7 종 (반드시 도출, 가정 금지)

| # | 도출 대상 | 입력 | 도구 | 출력 | 검증 |
|---|---|---|---|---|---|
| 1 | BL3 entry 파일 오프셋 | sboot.bin | capstone + AArch64 부팅 패턴 | hex + 첫 0x40 디스어셈블 | 4 KB 정렬 + EL setup |
| 2 | Linker 베이스 주소 | sboot.bin + entry | adrp+add 정합 점수 | hex + score | 상위 5 ptr 자기 참조 |
| 3 | Load 베이스 주소 | 가설 + 회차 1 fault | qemu Data Abort FAR | hex | 회차 1 FAR 일치 |
| 4 | Δ = (load−linker) mod 2^32 | 2, 3 | 산술 | uint32 | name+Δ 가 유효 ASCII |
| 5 | Cmd 테이블 + 포맷 | 알려진 명령 ASCII | string xref | 시작 + 크기 + 오프셋 | 모든 엔트리 name+Δ 유효 |
| 6 | Cmd list head | 5, exec_command | exec_command 첫 0x20 디스어셈블 | hex | 그 주소 채우면 help 동작 |
| 7 | Shell 함수 | 프롬프트 문자열 | string xref + bl chain | hex + 첫 0x40 디스어셈블 | readline/prompt 패턴 |

---

## Table D — 머신 `.c` 13 요소

| # | 요소 | 일반 형식 | 입력 | 새 펌웨어 |
|---|---|---|---|---|
| 1 | CPU + EL | `object_new(...)`; has_el3/el2 | Table B | 다름 |
| 2 | DRAM | `add_subregion(sysmem, BASE, ram)` | Table B + C #3 | 다름 |
| 3 | peri_lo (UART) | `init_io 0x10000000+256MB` 등 | 회차 1 fault | 다름 |
| 4 | peri_mid/hi | 동일, read 0 / write 흡수 | 회차 2~N fault | 다름 |
| 5 | UART MMIO | `if(off == UTXH) chr_fe_write` | Exynos UART 표준 | 대부분 같음 |
| 6 | RX FIFO + chardev | `set_handlers(rx_recv,...)` | 동일 | 동일 |
| 7 | BL3 로드 | `memcpy(ram_ptr+off, buf, sz)` ★ cpu_physical_memory_write 금지 | C #3 | LOAD 만 다름 |
| 8 | 핸드오프 매직 | `wr32(MAGIC_ADDR, MAGIC_VAL)` × N | Table E | 다름 |
| 9 | Heap stub | bump allocator 인코딩 | Table E | 다름 |
| 10 | 콘솔 vtable | `wr64(slot, our_stub)` × 3 | Table E | 다름 |
| 11 | Shell-mode 강제 | `MOV W0,#1; RET` | Table E | 다름 |
| 12 | Entry redirect | EL setup 직후 첫 bl → `B trampoline` | C #7 + 분석 | 위치 다름 |
| 13 | Cmd/Env reloc | `for(i;i<N;i++){ptr+=Δ;}` + next + head | C #4,5,6 | 다름 |

---

## Table E — 보조 도출 (4 값)

| 대상 | 도출 방법 | 형식 | 사용처 |
|---|---|---|---|
| 콘솔 vtable | 콘솔 객체 호출 site → `ldr [vtable, #imm]` | vtable + 3 슬롯 오프셋 | Table D #10 |
| Heap allocator | free-list traversal (loop with ldr/cmp/ldr) | 함수 주소 | Table D #9 |
| BL2 핸드오프 매직 | entry 첫 0x100 의 `ldr literal/cmp #magic` | (addr, val) 페어 | Table D #8 |
| getline timeout | shell 함수 안 `b.ls/b.gt` 시간 비교 | 분기 명령 주소 | Table D #11 보강 |

---

## Table F — 회차 처치 (정지점 → 일반 처치)

| 신호 | 트리거 | 처치 | PROGRESS 한 줄 형식 |
|---|---|---|---|
| Data Abort FAR=X (unmapped) | X 의 GB 영역 미모델 | peri 윈도우 추가 | `run N \| Data Abort FAR=X \| peri 0x... 추가` |
| 무한 폴링 0x... | X 카운트 매 회차 증가 | X → 0xffffffff | `run N \| 무한 폴링 0x... \| ready bit 모델` |
| Undefined smc | EL3 모니터 부재 | smc → MOV X0,#0 | `run N \| smc undef ELR=X \| 0x52800000` |
| PFA FAR=0 ELR=0 | NULL ret (uninit fn ptr) | caller → entry redirect | `run N \| PFA ELR=0 \| entry 0x... → trampoline` |
| 콘솔 멈춤 | log buffer 라우팅 | 출력 콜백 재작성 | `run N \| console silent \| printf cb → UART` |
| FPU/SVE trap | CPACR 미세팅 | CPACR_EL1.FPEN | `run N \| FPU trap ELR=X \| CPACR FPEN on` |
| 셸 즉시 종료 | getline timeout=0 | timeout 분기 → 무조건 loop | `run N \| shell exit \| getline timeout 0x... → B` |

---

## Table G — 검증 5/5 (정직성 §11)

| 항목 | 통과 조건 | 도구 | 실패 의미 |
|---|---|---|---|
| PC 트레이스 | shell_func + exec_command PC 가 `-d in_asm` 에 등장 | `grep "^0xSHELL_PC:"` | 셸 도달 안 함 |
| 출력 byte-match | 콘솔 모든 토큰이 BL3 안에 file offset 으로 존재 | `data.find(token)` for all | 텍스트 주입됨 |
| 소스 negative | 머신 C 에 동일 출력 문자열 0 개 | `grep -F "TOKEN" *.c` | 머신이 직접 텍스트 |
| UART 단일 경로 | `qemu_chr_fe_write_all` 호출 1 자리, "BL3 가 UTXH 에 쓸 때만" | `grep -n chr_fe_write` | 머신이 주입 가능 |
| 우회 목록 | `[대상/이유/방법/부작용]` 4 항 × N 개 | 우회_패치_목록.md 존재 | 우회를 모델로 위장 |

5/5 = REAL. 4/5 = FORCED. 3/5 이하 = 가짜.

---

## Table H — 위기 5 신호 (critic agent 자동 발화)

| # | 트리거 | LLM 응답 |
|---|---|---|
| 1 | 회차 30+ + 마지막 5 fault 같은 카테고리 | 전략 재평가: entry redirect 더 앞으로 / BL3 이미지 검토 |
| 2 | UART 의미있는 텍스트 등장 + 검증 미실행 | Table G 5/5 자가 수행 → 보고 |
| 3 | "미확정" 도출 5 개 이상 | 참조 자산 재읽기, 청사진 차용 |
| 4 | BL3 안 알려진 ASCII 없음 / carve 의심 | 다시 carve, 크기·entropy·ASCII 비교 |
| 5 | target=A 인데 UFS/PMIC 우회 시도 중 | A 등급은 entry redirect 우회로 충분 |

---

## Table I — 프롬프트 슬롯 (13)

| 슬롯 | 형식 | 변하는가 |
|---|---|---|
| `[모델]` | SM-XXXXX | ★ 변함 |
| `[SoC + ARMv?]` | 이름 + 아키텍처 | ★ 변함 |
| `[빌드 ID + md5 + 크기]` | hex + bytes | ★ 변함 |
| `[캐리어]` | OKR/KOO/... | ★ 변함 |
| `[목표 등급]` | A/B/C | ★ 변함 |
| `[has_el3/el2 가설]` | bool/bool | ★ 변함 |
| `[참조 자산 경로]` | 콤마 구분 리스트 | ★ 변함 |
| `[작업 디렉터리]` | 절대 경로 | ★ 변함 |
| `[QEMU 버전 + 빌드 경로]` | 10.x.x + path | ★ 변함 |
| `[정직성 규칙 7]` | instruction §1 | 변하지 않음 (CLAUDE.md) |
| `[작업 순서 0~10]` | Table A | 변하지 않음 (CLAUDE.md) |
| `[검증 5/5]` | Table G | 변하지 않음 (reality-verifier agent) |
| `[위기 5 신호]` | Table H | 변하지 않음 (critic agent) |

앞 9 슬롯 = 펌웨어마다 새로 채움. 뒤 4 슬롯 = 플러그인이 항상 강제.

---

## 플러그인 산출물 ↔ Table 매핑

| 산출물 | 매핑 |
|---|---|
| `CLAUDE.md` | 정직성 7 + Table G/G2 + Table H/H2 + 트랙 개념 |
| `skills/rehost-init/SKILL.md` | 설치 후 1회: 작업 루트 + `_inbox/` 생성 + 의존성 |
| `skills/rehost-setup/SKILL.md` | 펌웨어 드롭 후: 격리 워크스페이스 + 트랙 프롬프트 + INPUT.md |
| `hooks/hooks.json` + `scripts/ensure_inbox.ps1` | SessionStart 훅: `_inbox/` 자동 생성 (CLI/web; 확장에선 `/rehost-init`) |
| `skills/rehost-sboot/SKILL.md` | 트랙 1 실행 (pipeline.js) |
| `skills/rehost-kernel/SKILL.md` | 트랙 2 실행 (pipeline_kernel.js) |
| `skills/rehost-status/SKILL.md` | 워크스페이스 목록/상태 |
| `skills/rehost-export/SKILL.md` + `scripts/make_export.sh` | 완료 후 "빌드 없이 실행" 키트 (rehost_exports/<fw>/track<N>/, gitignore) |
| `agents/bl3-analyzer.md` | Table C (정적 7) + carve 판정 (트랙 1) |
| `agents/stub-locator.md` | Table E (보조 4) (트랙 1) |
| `templates/machine.c.tmpl` | Table D (머신 13 요소) (트랙 1) |
| `agents/fault-fixer.md` | Table F (정지점 처치) (트랙 1) |
| `agents/reality-verifier.md` | Table G / G2 (검증 5/5) |
| `agents/critic.md` | Table H / H2 (위기 5 신호) |
| `workflows/iter-loop.js` / `pipeline.js` | 트랙 1 회차 루프 / 파이프라인 |
| `agents/kernel-boot-analyzer.md` | Table J (부팅 자산 + DTB 골격 + 게이트) (트랙 2) |
| `agents/boot-fault-fixer.md` | Table L (커널 정지점 처치) (트랙 2) |
| `agents/storage-modeler.md` | Table M (스토리지 HCI 함정) (트랙 2) |
| `templates/machine_kernel.c.tmpl` / `storage_hci.c.tmpl` | Table K (트랙 2 머신 요소) |
| `workflows/pipeline_kernel.js` | 트랙 2 파이프라인 (Static→K1→K2→K3→Verify) |

---

# 트랙 2 표 (J~M) — kernel-storage

> 트랙 2 는 커널 EL1 진입점부터 진짜 실행. 값은 대상 DTB/커널/드라이버 도출.
> 상세: [track2_kernel_storage.md](track2_kernel_storage.md).

## Table J — 부팅 자산 + 정적 도출

| # | 도출 대상 | 입력 | 도구 | 검증 |
|---|---|---|---|---|
| 1 | 부팅 자산 (Image/DTB/initrd/super) | boot.img/super.img | 표준 언팩 | 매직 (Image 헤더 / 0xd00dfeed / EROFS) |
| 2 | 머신 골격 (cpu/dram/gic/uart/HCI base) | DTB | fdtdump/libfdt | fdt 노드 근거 |
| 3 | cmdline (earlycon/pKVM/root) | DTB `/chosen` | fdt | `kvm-arm.mode=protected` → HVC 커널 |
| 4 | 커널 게이트 사이트 (fips/defex/selinux/avb) | Image | 심볼·문자열 xref | pre-image 워드 확인 |
| 5 | 스토리지 HCI base + SPI | DTB storage 노드 | fdt | K3 시작점 |

## Table K — 트랙 2 머신 요소

| # | 요소 | 도출 | 함정 |
|---|---|---|---|
| 1 | CPU (코어/수, has_el2) | DTB cpus | mp-affinity cluster.core |
| 2 | DRAM | DTB memory | — |
| 3 | GICv3 + arch-timer PPI | DTB gic | ★ PPI 풀 INTID (상대번호 금지) |
| 4 | UART | DTB uart | accept_input 필수 |
| 5 | catch-all MMIO | overlap 낮은 prio | fail-loud 1 회 보고 |
| 6 | EL3 SMC 셤 | PSCI/eFuse/SiP | psci_conduit=SMC (DISABLED 금지) |
| 7 | QEMU 코어 3 패치 | SMC→EXCP_SMC | interrupt_handler 게이트 |
| 8 | DT 주입 (fstab/pcie) | libfdt | 셀 수 (reg/ranges/interrupt-map) |
| 9 | 스토리지 HCI (K3) | storage_hci.c.tmpl | §7.3 함정표 |

## Table L — 트랙 2 커널 정지점 처치 (K1/K2)

| 신호 | 처치 |
|---|---|
| kernel_oops / security_gate | patch_kernel.py 사이트 (pre-image 검증) |
| smc_undef / psci_suspend | SMC 셤 + 코어 패치, psci_conduit=SMC |
| gic_ppi (assert) | arch-timer PPI 풀 INTID 배선 |
| unmapped_mmio | DTB 로 페리페럴/RAM 추가 |
| rootfs_mount | 제네릭+DT fstab (§6.1) 또는 dm-linear (§6.2) |
| hvc_pkvm | 셤에서 HVC 가로채기 제거 (커널 내장) |

## Table M — 트랙 2 스토리지 HCI 함정 (K3, 관찰 루프)

| 벽 | 원인 | 처치 |
|---|---|---|
| poll_stall | 벤더 창 0 반환 | 완료비트 오프셋 all-1 (상수, 토글 금지) |
| desc_addr_corrupt | `ldl_le_p` 부호확장 | `(uint32_t)` 캐스트 |
| pwrmode_timeout | UIC opcode 오인 (DME_SET=0x02) | opcode 정정 + 완료 IRQ |
| gear_source | mmio read (로그 안 보임) | `.ko` 역어셈블로 주소 확정 |
| upiu_field_off | LUN/EDTL 오프셋 | LUN=byte2, EDTL=byte12-15 |
| block_size | 512 vs 4096 | `EFI PART` 시그니처 위치 |
| vendor_telemetry_null | 플랫폼 텔레메트리 null | `.ko` 그 함수 조기 리턴 |

## Table G2 / H2 — 트랙 2 검증 5/5 + 위기 5 신호

CLAUDE.md 의 "검증 5/5 — 트랙 2" 및 "위기 5 신호 — 트랙 2" 표 참조.
