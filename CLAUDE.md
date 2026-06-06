# sboot-rehost — 항상 로드되는 컨텍스트

이 파일은 sboot-rehost 플러그인 작업 중 Claude Code 가 항상 컨텍스트에
로드한다. 모든 회차·도출·검증이 이 규칙에 따른다.

---

## 정직성 규칙 7 항 (어기는 변경은 무효)

1. **추측 stub 금지**. 특히 적응형 토글 (예: "12회 read=0, 그 뒤
   0xFFFFFFFF/0 교대"). 펌웨어를 잘못된 분기로 보내 "우연한 통과" 로 끝남.
2. **우회는 우회로 명시**. 펌웨어 패치를 정상 모델처럼 표현 금지. 매 우회는
   `[대상 / 이유 / 방법 / 알려진 부작용]` 4 항으로 문서화.
3. **모든 주소·구조·바이트열은 분석으로 도출**. 도구는 둘뿐:
   - 디스어셈블 (capstone)
   - 실행관찰 (`qemu -d exec,int,unimp,guest_errors`)
   - 도출하지 않은 값을 분석 결과처럼 쓰지 말 것.
4. **하드코딩을 분석처럼 위장 금지**. 미확정 값은 "미확정 — N단계에서 확정"
   으로 표기.
5. **못 간 지점은 못 갔다고 기록**. 가짜 통과 금지.
6. **성공은 실제 트레이스/콘솔/메모리 캡처로만 판정**. 문자열 regex 매칭
   단독 = 불인정.
7. **머신 안 입력 자가주입 금지** (예: TX 카운트 보고 RX 에 명령을 넣어주는
   식). 머신이 입력과 명령을 다 만들면 "동작 확인" 이 순환검증.

---

## 검증 5/5 (Table G — 셸 도달 보고 전 필수)

| # | 항목 | 통과 조건 |
|---|---|---|
| 1 | PC 트레이스 | shell 함수 + exec_command 진입 PC 가 `-d in_asm` 로그에 등장 |
| 2 | 출력 byte-match | 콘솔 출력 모든 토큰이 BL3 binary 에 file offset 으로 존재 |
| 3 | 소스 negative | 머신 C 소스에 동일 출력 문자열 0 개 |
| 4 | UART 단일 경로 | `qemu_chr_fe_write_all` 호출 단 1 자리, "BL3 가 UTXH 에 쓸 때만" |
| 5 | 우회 목록 | `[대상/이유/방법/부작용]` 4 항으로 N 개 우회 기재 |

5/5 = REAL. 4/5 이하 = FORCED (성공 표시 금지).

---

## 위기 5 신호 (critic agent 가 자동 발화)

| # | 트리거 | 발화 메시지 |
|---|---|---|
| 1 | 누적 회차 ≥ 30 + 마지막 5 fault 동일 카테고리 | "방향 맞아? entry redirect 위치를 더 앞으로 옮길지 검토." |
| 2 | UART 에 BL3 ASCII ≥ 3 토큰 + 5/5 검증 미실행 | "/rehost 다음 호출에서 자동 5/5 검증 예정." |
| 3 | STATIC.md 또는 STUBS.md 의 "미확정" ≥ 5 개 | "참조 자산 (INPUT.md refs) 보강 검토." |
| 4 | bl3-analyzer 의 found_strings 비었거나 알려진 ASCII 없음 | "BL3 가 full 인지 carve 인지 재확인 필요." |
| 5 | target=A 인데 패치에 UFS/PMIC 키워드 출현 | "A 등급은 entry redirect 우회로 충분. UFS 모델 불필요." |

---

## 사용 가능한 슬래시 명령

- **`/rehost`** — 상태 자동 감지 → 다음 단계 1 개 실행 (사용자가 이거 하나만 반복)
- **`/rehost-status`** — INPUT/STATIC/STUBS/PROGRESS/VERIFICATION 요약

---

## 작업 디렉터리 표준 구조

`/rehost` 가 S1 단계에서 작업 디렉터리에 만드는 표준 8 폴더:

```
<workdir>/
├── INPUT.md                       Table B 9 슬롯
├── STATIC.md                      bl3-analyzer 출력 (8 도출)
├── STUBS.md                       stub-locator 출력 (4 보조)
├── PROGRESS.md                    회차별 한 줄 이력
├── VERIFICATION.md                reality-verifier 출력 (5/5)
├── 01_firmware/                   원본 펌웨어 (사용자 제공)
├── 02_unpacked/                   lz4 해제 등
├── 03_bl3/                        BL3 본체 (sboot_bl3.bin)
├── 04_static-analysis/            도출 스크립트 출력
├── 05_qemu/                       QEMU 빌드 디렉터리 심볼릭링크
├── 06_machine/                    machine.c 및 우회 목록
├── 07_logs/                       회차별 console/run 로그
├── 08_docs/                       추가 분석 메모
└── 10_reproduce/                  S7 단계에서 생성되는 재현 키트
```

---

## 회차 기록 형식 (PROGRESS.md)

```
| run N | <정지점 신호> | <한 변경> |
```

예:
```
| run 12 | Data Abort FAR=0x12860010 | peri_lo 0x10000000 + 256MB 추가 |
| run 13 | Prefetch Abort FAR=0 ELR=0 | entry 0x90000050 → trampoline 0x90000148 |
```

한 회차 = 한 변경 = 한 줄. 여러 변경 묶기 금지 (instruction.md §7.3).

---

## 사용자 의도 파악

사용자가 다음을 말하면:

- "다시 검증해줘 / 진짜야?" → reality-verifier 즉시 호출
- "방향 맞아?" → critic 즉시 호출, 전략 재평가
- "9820 / 다른 분석가 자료 참고" → methodology/worked_example.md 재읽기

사용자가 명시적으로 다른 명령을 주지 않는 한 `/rehost` 의 상태 머신을 따른다.
