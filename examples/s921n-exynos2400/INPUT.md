# INPUT — sboot-rehost 0차 입력 (예시: SM-S921N)

> 이 INPUT.md 는 worked example 의 입력값. `/sboot-rehost:rehost-setup` 이 새 펌웨어로
> 워크스페이스에 동일 구조 파일을 자동 생성한다.

| 슬롯 | 값 |
|---|---|
| track | 1 |
| autonomous | true |
| model | SM-S921N |
| soc | Exynos 2400 (ARMv9) |
| build | S921NKSUEDZDR |
| md5 | 1bf5599c740632f6497122911dcdc529 |
| file_size | 8401712 |
| carrier | OKR |
| target | A (help) |
| bl3_path | /path/to/sboot_bl3_full.bin |
| workdir | /path/to/workdir |
| refs | (다른 분석가의 sm_s921b.c 경로) |
| has_el3_guess | false |
| has_el2_guess | true |
| qemu_dir | ~/qemu-build/qemu-10.2.2 |

## 참고

이 펌웨어로 셸 도달까지 풀이된 회상은
[../../methodology/worked_example.md](../../methodology/worked_example.md).

기대 결과는 [EXPECTED_OUTPUT.txt](EXPECTED_OUTPUT.txt) (308 bytes).

새 환경에서 처음부터 재현하려면:
1. 같은 md5 의 sboot_bl3_full.bin 확보 (samfw.com 의 본인 기기용 펌웨어)
2. `bl3_path` 와 `workdir` 를 본인 경로로 수정
3. 이 INPUT.md 를 `<workdir>/INPUT.md` 로 복사
4. Claude Code 에서 `/sboot-rehost:rehost-sboot` 호출 (트랙 1)
