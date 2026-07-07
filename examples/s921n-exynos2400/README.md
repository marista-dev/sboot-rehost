# SM-S921N (Exynos 2400) — 트랙 1 Worked Example

`/rehost-sboot` (트랙 1) 가 처음부터 끝까지 동작했을 때 도달하는 최종 상태.

## 파일

| 파일 | 내용 |
|---|---|
| [INPUT.md](INPUT.md) | Table B 9 슬롯의 채워진 입력값 |
| [EXPECTED_OUTPUT.txt](EXPECTED_OUTPUT.txt) | QEMU UART 의 308 byte 콘솔 출력 |
| [machine.c](machine.c) | 13 요소 채워진 머신 (454 줄) |

## 사용

`/rehost-init` 의 인테이크에서 본 INPUT.md 의 슬롯들이 그대로 사용자에게 묻는
질문의 답변으로 대응 (트랙 1 선택 후).

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
검증 5/5 통과. 자세한 내역은 [../../methodology/worked_example.md](../../methodology/worked_example.md).
