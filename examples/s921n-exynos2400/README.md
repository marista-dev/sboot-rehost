# SM-S921N (Exynos 2400) — 참고 자료 (v0.20.0 이전 산출물)

> **통합 체인의 모델이 아니다.** 폐기된 트랙 1 이 도달했던 상태이며, BL3 를 carve 해
> 단독 적재하고(`has_el3=false`, 진입 = BL3) **UFS 를 모델하지 않은 채 스토리지 경로를
> 우회**한다. 현재 목표(BL1 부터 연속 실행 + 실제 매체 구동)와 방향이 반대다.
>
> 남겨둔 이유는 **실제로 동작한 유일한 머신 소스**이기 때문이다. Exynos UART 모델과
> 주소 도출값은 재사용할 수 있다. 아래 검증 5/5 는 당시 기준이며 현재는 6/6 이다.

## 파일

| 파일 | 내용 |
|---|---|
| [INPUT.md](INPUT.md) | Table B 9 슬롯의 채워진 입력값 |
| [EXPECTED_OUTPUT.txt](EXPECTED_OUTPUT.txt) | QEMU UART 의 308 byte 콘솔 출력 |
| [machine.c](machine.c) | 13 요소 채워진 머신 (454 줄) |

## 사용

`/sboot-rehost:rehost-setup` 의 인자/인테이크에서 본 INPUT.md 의 슬롯들이 대응 (트랙 1).

Phase 3 (회차 루프) 가 끝나면 `06_machine/machine.c` 가 본 폴더의 machine.c 와
일치해야 함 (구조적으로). 정확히 동일한 patch 시퀀스로 완료될 필요는 없음 —
도출값이 같으면 OK.

Phase 4 (5/5 검증) 후 console 이 EXPECTED_OUTPUT.txt 와 byte-identical 이어야
함. diff 가 비어있어야 통과.

## 검증

```bash
# QEMU 실행 후
diff -u EXPECTED_OUTPUT.txt /tmp/console.txt
# 출력 없으면 매치 (성공)
```

## 정직성

본 worked example 의 모든 출력 문자열은 BL3 ROM (sboot_bl3_full.bin,
md5 1bf5599c…) 안에 file offset 으로 존재. 머신 코드에는 동일 문자열 없음.
당시 기준 검증 5/5 통과 (현재 기준은 6/6 — 항목 4 양방향 검증과 항목 5 스토리지 이중 구동이 추가됐다).
