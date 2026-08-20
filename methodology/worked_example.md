> **대체됨 (v0.19.0)** — 이 문서는 트랙을 둘로 나누던 시기의 방법론이다.
> 현재 플로우는 통합 체인 하나이며 정본은 [CLAUDE.md](../CLAUDE.md) 와
> [docs/onboarding/](../docs/onboarding/README.md) 에 있다.
> 아래 내용은 도출 기법의 참고 자료로 남겨 두었으나, 트랙·등급·검증 항목 서술은
> 현재 구현과 다르다.

# Worked Example — SM-S921N (Exynos 2400) 의 `help` 도달 회상

> 이 플러그인이 어떻게 만들어졌는지의 실제 사례.
> 새 펌웨어 작업 중 막히면 이 문서를 참조해서 패턴을 빌릴 수 있다.

날짜: 2026-06-05 (회차 63 시점)
검증: REAL ([VERIFICATION_HELP_REAL.md](../examples/s921n-exynos2400/) 참조)

---

## 1. 입력 (Table B 슬롯)

| 슬롯 | 값 |
|---|---|
| model | SM-S921N |
| soc | Exynos 2400 (ARMv9) |
| build | S921NKSUEDZDR |
| md5 | 1bf5599c740632f6497122911dcdc529 |
| file_size | 8,401,712 bytes |
| carrier | OKR |
| target | A (help) |
| has_el3 | false |
| has_el2 | true |
| refs | 09_another_people_analyze/exynos2400_rehosting/qemu-exynos9820/qemu/hw/arm/sm_s921b.c |

---

## 2. 정적 분석 결과 (Table C)

| 슬롯 | 값 | 도출 방법 |
|---|---|---|
| entry_offset | 0x0 (BL3 본체 시작) | AArch64 부팅 패턴 score 8/10 |
| linker_base | 0xF467D000 | adrp+add 정합 |
| load_base | 0x90000000 | (사용자 명시 + 회차 1 fault) |
| **delta** | **0x9B983000** | (0x90000000 − 0xF467D000) mod 2^32 |
| cmd_table | 0x90394DB8 | "reset" file offset xref + 0x20 stride |
| cmd_list_head | 0x908A1270 | exec_command (0x90298944) 의 `ldr x22, [x8, #0x270]` |
| shell_func | 0x9021F3DC | "S-BOOT # " 의 adrp+add xref |
| NUM_CMDS | 19 | cmd 테이블 align 그룹 크기 |
| entry_format | `{name:0, help:8, handler:16, next:24}` | 4 슬롯 × 8 B = 32 B |

---

## 3. 보조 도출 (Table E)

| 슬롯 | 값 |
|---|---|
| vtable_base | 0x90377D70 |
| slot_getchar | +0x08 |
| slot_putchar | +0x10 |
| slot_haschar | +0x18 |
| heap_alloc_addr | 0x901DA234 |
| handoff_magic | (0x80000000, 0x66265999), (0x80000010, 0x77275999) |
| getline_timeout_branch | 0x901C7574 |

---

## 4. 머신 13 요소 (Table D 매핑)

```c
/* 1. CPU */ has_el3=false, has_el2=true, "cortex-a76"
/* 2. DRAM */ 0x80000000 + 512 MiB
/* 3. peri_lo */ 0x10000000 + 256 MiB (UART 0x10840000)
/* 4. peri_mid */ 0x20000000 + 256 MiB
/* 4. peri_hi */ 0x02000000 + 224 MiB
/* 5,6. UART + RX FIFO */ chr_fe_write_all 1 자리
/* 7. BL3 load */ memcpy(ram_ptr + (0x90000000 - 0x80000000), buf, sz)
/* 8. handoff */ wr32(0x80000000, 0x66265999); wr32(0x80000010, 0x77275999);
/* 9. heap */ 0x901DA234 → bump using 0x90900000+
/* 10. vtable */ wr64(0x90377D78, 0x90810014ULL); ... × 3
/* 11. shell-mode */ wr32(0x9021DB40, 0x52800020); wr32(0x9021DB44, 0xD65F03C0);
/* 12. entry redirect */ wr32(0x90000050, 0x1400003E); // B 0x90000148
/* 12. trampoline */ MOVZ X16,#0x908F LSL16 / ADD SP,X16,#0 / ... / BL shell / B .
/* 13. cmd reloc */ for(i<19){ ptr += 0x9B983000; } + next chain + head
/* 13. env reloc */ 94 ptrs at 0x9031BF28 + 0x9B983000
```

---

## 5. ★ 4 결정적 돌파

회차 63 에서 동시에 풀린 4 가지 — 이전 62 회차의 forced 출력을 진짜로 바꿈:

### 돌파 1 — Full BL3 발견 (8.4 MB)
- 이전 carve 는 2.5 MB. cmd 테이블 영역 내 분기 코드 누락
- 다른 분석가 자료의 `sboot_bl3.bin` (1bf5599c...) 이 진짜 full
- **교훈**: BL3 가 4 MB 이하면 carve 의심. 알려진 ASCII 3 개 이상 검증.

### 돌파 2 — Δ = 0x9B983000 발견
- linker 주소 0xF467D000 vs load 주소 0x90000000 차이 = 0x9B983000 (uint32 wrap)
- cmd 테이블의 모든 name/help/handler 포인터가 이 값을 더해야 런타임 유효
- **교훈**: BL3 가 linker ≠ load 면 모든 내부 ptr 에 Δ 적용. 첫 검증은 cmd
  엔트리의 name ptr + Δ → BL3 안 ASCII 매핑.

### 돌파 3 — Entry redirect 위치 = 0x90000050
- 0x90000000~0x9000004C: EL 셋업 (반드시 실행)
- 0x90000050: 첫 `bl 0x90000178` = device init 의 시작
- 이걸 트램폴린 0x90000148 로 점프 → device init 전체 스킵
- 트램폴린: SP=0x908F0000 + UFCON=1 + BL 0x9021F3DC + B .
- **교훈**: Entry redirect 의 최적 위치는 EL 셋업의 **바로 다음 명령**. 너무
  이르면 EL 미세팅, 너무 늦으면 init 일부가 실행되어 부작용.

### 돌파 4 — `memcpy(ram_ptr+off, ...)` 직접 (TCG sync)
- `cpu_physical_memory_write` 는 readback 은 OK 지만 TCG cache 가 stale 봄
- 패치 효과 없음 → fault 무한 반복
- `memcpy` 로 RAM backing 에 직접 쓰기로 해결
- **교훈**: QEMU 의 TCG 와 게스트 메모리 sync 함정. ram_ptr 직접 접근 필수.

---

## 6. 사용자 프롬프트의 결정적 역할

LLM 분석만으로는 63 회차에 도달 못 함. 사용자의 다음 프롬프트들이
방향 전환을 만듦:

| 프롬프트 | 효과 |
|---|---|
| "9820 instruction 그대로 적용" | 회차 0~12: 정직성 + 모델 카테고리 |
| "다른 분석가 자료 09_another_people_analyze 참고" | 회차 63: 8.4 MB BL3 + Δ + 청사진 |
| "help 정말 출력? 하드코딩 아니야?" | 회차 51~62 의 forced 인정 → 회차 63 진짜 풀이 |
| "페리페럴 + 9820 baseline 으로 하자고 안 했어?" | 회차 63: 깊은 init 스킵 + 진짜 cmd reloc |
| "다시 냉철하게 검증" | byte-match 검증 → REAL 판정 |

→ **돌파의 절반은 "지금까지 한 게 진짜인지" 를 사용자가 의심한 데서 나옴.**
→ critic agent 의 위기 5 신호가 이걸 자동화한 것.

---

## 7. 결과 (308 B 콘솔 출력)

```
autoboot aborted..
S-BOOT # help
Following commands are supported:
* dramtest
* reset
* usb
* upload
* findenv
* saveenv
* setenv
* printenv
* load_cp_header
* display
* uarten
* uartdis
* dprm
* check_nad_dram
* drawimg
* debore
* sod
* ufs_sod
* help
To get commands help, Type "help <command>"
S-BOOT #
```

검증 (Table G 5/5):
- ✅ #1 PC 트레이스: shell_func 0x9021f3dc + exec_command 0x90298944 등장
- ✅ #2 byte-match: 24 토큰 전부 BL3 안에 file offset 으로 존재
- ✅ #3 소스 negative: machine.c 에 동일 문자열 0 개
- ✅ #4 UART 단일: `qemu_chr_fe_write_all` 1 자리, off==UART_TX_OFF 조건
- ✅ #5 우회 목록: 13 우회 항목 × 4 항 (대상/이유/방법/부작용)

→ **5/5 = REAL**.

---

## 8. 새 펌웨어에 빌리는 패턴

본 사례에서 새 펌웨어 (S922N, S925N 등) 작업에 빌릴 만한 패턴:

1. **첫 회차 전에 carve 검증**. 4 MB 이하면 의심.
2. **linker base 와 load base 동시에 도출**, Δ 산출 즉시 검증.
3. **Entry redirect 는 EL 셋업 직후 첫 bl**. EL 셋업 이전 점프 금지.
4. **트램폴린은 SP 부터 세팅**. 그 다음 UFCON, BL shell, B 무한 루프.
5. **콘솔 vtable 슬롯 3 개**, 핸드오프 매직 2~N 쌍은 entry 첫 0x100 에 거의 있음.
6. **`memcpy` 직접**, 절대 `cpu_physical_memory_write` 안 쓰기.
7. **사용자가 의심하면 즉시 검증**. byte-match + 소스 negative 가 핵심.

이 패턴들은 9820 instruction.md 에 없거나 약했던 것. 이 플러그인이 이 사례에서
배운 5 가지를 항상 적용.
