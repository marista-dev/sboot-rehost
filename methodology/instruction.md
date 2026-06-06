# S-Boot 리호스팅 — 분석 방법론 (노베이스용)

> 이 문서는 "답"을 주지 않는다. 펌웨어를 받아 직접 분석하면서 머신 `.c`
> 를 회차마다 업데이트하는 **방법론**을 적는다. 주소·오프셋·우회 목록은
> 적지 않는다 — 당신이 도출한다. 도출 못 하면 도달도 못 한다.
>
> 환경 구성과 펌웨어 다운로드 (§2, §3) 만은 재현 가능해야 하므로 구체적
> 으로 적는다. 그 이후 (정적분석부터) 는 기법만 적는다.
>
> 마지막 갱신: 2026-05-26

---

## 0. 이 문서의 사용법

이건 체크리스트가 아니라 **사고 절차**다. 매 단계에서:

1. **무엇을 관찰하는가** (어떤 도구로 어떤 출력을)
2. **어떻게 도출하는가** (관찰에서 결론으로의 추론)
3. **어떻게 검증하는가** (다른 관찰로 교차 확인)
4. **무엇을 하면 안 되는가** (분석을 우회하는 지름길)

펌웨어가 다르면 모든 주소가 다르다. SoC 가 다르면 페리페럴 맵이 다르다.
S-Boot 버전이 다르면 init 테이블 구조·셸 함수 위치가 다르다. **이
문서의 어떤 분석값도 가정으로 가져다 쓰지 말 것** (환경 설정·다운로드
명령은 그대로 써도 된다 — 그건 답이 아니라 셋업).

---

## 1. 정직성 규칙 (Playbook ch.11)

이 규칙을 어기는 변경은 결과가 어떻게 나오든 무효.

1. **추측 stub 금지.** 특히 적응형 토글 (예: "12회 read=0, 그 뒤
   0xFFFFFFFF/0 교대"). 펌웨어를 잘못된 분기로 보내 "우연한 통과" 로 끝남.
2. **우회는 우회로 명시.** 펌웨어 패치를 정상 모델처럼 표현 금지.
   매 우회는 `[대상 / 이유 / 방법 / 알려진 부작용]` 으로 문서화.
3. **모든 주소·구조·바이트열은 분석으로 도출.** 도구는 둘뿐:
   - 디스어셈블 (예: capstone)
   - 실행관찰 (qemu `-d exec,int,unimp,guest_errors`)
   - 도출하지 않은 값을 분석 결과처럼 쓰지 말 것.
4. **하드코딩을 분석처럼 위장 금지.** 미확정 값은 "미확정 — N단계에서
   확정" 으로 표기.
5. **못 간 지점은 못 갔다고 기록.** 가짜 통과 금지.
6. **성공은 실제 트레이스/콘솔/메모리 캡처로만 판정.** 문자열 regex
   매칭 단독 = 불인정.
7. **`-icount` 금지** (`cpu_io_recompile` 무한루프).
8. **머신 안에서 입력 자가주입 금지** (예: TX 카운트 보고 RX 에 명령을
   넣어주는 식). 머신이 입력과 명령을 다 만들면 "동작 확인" 이 순환검증.
   입력은 반드시 외부 (테스트 하니스 / 키보드) 에서.

---

## 2. 환경 구성 (구체적 — 그대로 따라할 것)

실제로 작업한 구성: **WSL2 Ubuntu on Windows + LLM** 의 하이브리드.
무거운 실행 (빌드·런·트레이스) 은 WSL2, 분석·.c 작성·로그 해석은 LLM,
다리는 Windows 측 작업폴더 (WSL 에서 `/mnt/c/...` 로 접근).

### 2.1 WSL2 + Ubuntu 설치

Windows PowerShell (관리자):

```powershell
wsl --install -d Ubuntu-22.04
```

설치 후 WSL 진입, 한 번 업데이트:

```bash
sudo apt update && sudo apt upgrade -y
```

### 2.2 필수 패키지

```bash
sudo apt install -y \
    build-essential ninja-build pkg-config \
    libglib2.0-dev libpixman-1-dev libslirp-dev \
    python3 python3-pip python3-venv \
    socat unzip wget curl tar lz4 file
# meson 의 apt 버전은 낡았을 수 있어 pip 권장
pip3 install --break-system-packages meson capstone lz4
# pip 설치 위치를 PATH 에 추가 (한 번)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

검증:

```bash
meson --version          # 1.0 이상
ninja --version          # 1.10 이상
python3 -c "import capstone; print(capstone.__version__)"   # 5.x
python3 -c "import lz4.frame; print('lz4 ok')"
```

### 2.3 QEMU 소스 빌드

실제 사용·검증된 버전 = **QEMU 10.2.2** (최신 안정 stable 도 가능하지만
머신 `.c` 의 API 시그니처가 약간 다를 수 있다 — `CharBackend`/`CharFrontend`
같은 것).

```bash
mkdir -p ~/qemu-build && cd ~/qemu-build
wget https://download.qemu.org/qemu-10.2.2.tar.xz
tar xf qemu-10.2.2.tar.xz
cd qemu-10.2.2
mkdir build && cd build
../configure \
    --target-list=aarch64-softmmu \
    --disable-werror --disable-docs --disable-tools \
    --disable-guest-agent --disable-vnc --disable-sdl --disable-gtk
ninja qemu-system-aarch64
```

첫 빌드는 8~20분. 빌드 산출물:
`~/qemu-build/qemu-10.2.2/build/qemu-system-aarch64` (~108 MiB).

검증:
```bash
./qemu-system-aarch64 --version
./qemu-system-aarch64 -M help | head    # 머신 리스트 확인
```

### 2.4 머신 `.c` 등록

자작 머신은 `hw/arm/` 에 두고 같은 폴더의 `meson.build` 끝에 등록:

```bash
# 머신 파일 배치
cp /mnt/c/Users/<you>/.../06_machine/sboot_g977n.c \
   ~/qemu-build/qemu-10.2.2/hw/arm/

# meson.build 등록 (예: 마지막 줄 즈음에)
echo "arm_ss.add(files('sboot_g977n.c'))" \
  >> ~/qemu-build/qemu-10.2.2/hw/arm/meson.build
```

재빌드:
```bash
cd ~/qemu-build/qemu-10.2.2/build
ninja qemu-system-aarch64
```

빌드가 새 머신을 알아보는지 검증:
```bash
./qemu-system-aarch64 -M help | grep <your-machine-name>
```

### 2.5 작업폴더 구조 (Windows 측, WSL 에서 mount 로 접근)

Windows 의 사용자가 보기 좋도록 `C:\Users\<you>\<폴더>\new_rehosting\`
같은 위치를 만들고 WSL 에서:

```bash
WS="/mnt/c/Users/<you>/<폴더>/new_rehosting"
mkdir -p $WS/{01_firmware,02_unpacked,03_bl3,04_static-analysis,05_qemu,06_machine,07_logs,08_docs}
cd $WS
```

권장 구조:

```
new_rehosting/
├── 01_firmware/                  # samfw 다운로드 원본 .zip / .tar.md5
├── 02_unpacked/                  # 압축해제 결과 (sboot.bin, PIT 등)
├── 03_bl3/                       # BL3 본체 carve (bl3_full.bin)
├── 04_static-analysis/           # find_bl3.py 등 분석 스크립트 + 리포트
├── 05_qemu/                      # 빌드된 QEMU 바이너리 (또는 심볼릭링크)
├── 06_machine/                   # ★ sboot_g977n.c + harness.py + 우회목록
├── 07_logs/                      # 실행 증거 (run logs, shell evidence)
├── 08_docs/                      # 이 문서 등
├── GOAL.md
└── PROGRESS.md
```

QEMU 바이너리는 빌드 위치에서 심볼릭링크로 작업폴더에 노출:
```bash
ln -sf ~/qemu-build/qemu-10.2.2/build/qemu-system-aarch64 \
       $WS/05_qemu/qemu-system-aarch64-sboot
```

### 2.6 디스크 보호 (실수 자주 함)

`-d exec` 트레이스는 **5~10초에 1 GiB**. 매 회차 끝에 즉시 삭제하지
않으면 디스크가 차서 작업이 멈춘다.

규칙:
- 모든 실행은 `timeout N` 으로 감싼다.
- 로그는 `/tmp/` 또는 Linux 측 ext4 에 두고, virtiofs 마운트
  (`/mnt/c/...`) 에 두지 않는다 (속도+안정성).
- 끝나면 `rm -f`.
- 매 회차 끝에 `df -h .` 로 잔여 용량 확인.

```bash
# 매 실행 템플릿
timeout 12 ~/qemu-build/qemu-10.2.2/build/qemu-system-aarch64 \
    -M <machine> -bios <bl3.bin> \
    -serial stdio -display none -nographic \
    -d int,unimp,guest_errors -D /tmp/run.log \
    < /dev/null > /tmp/console.txt 2>&1
# … 분석 …
rm -f /tmp/run.log /tmp/console.txt
df -h ~
```

### 2.7 환경 검증 체크리스트

머신 분석에 들어가기 전 한 번 모두 ✓:

- [ ] WSL2 Ubuntu 22.04+ 진입 가능
- [ ] `meson --version`, `ninja --version`, `capstone` import 모두 OK
- [ ] QEMU `--version` 이 10.2.2 (또는 같은 계열) 보고
- [ ] `qemu-system-aarch64 -M help` 에 자작 머신 이름이 나옴 (등록 후)
- [ ] `df -h ~` 잔여 ≥ 10 GiB
- [ ] 작업폴더 8개 하위 디렉터리 존재
- [ ] `socat` 또는 `nc -U` 로 unix socket 접속 가능 (모니터용)

---

## 3. 펌웨어 확보 (구체적 — 그대로 따라할 것)

### 3.1 모델·캐리어·빌드 결정

당신 작업의 정확한 **모델 / 캐리어 / 빌드**를 고정한다. 빌드가 다르면
주소도 다르다.

실제 작업에 사용·검증된 펌웨어 (참고용):
- 모델: **SM-G977N** (Galaxy S10 5G, 한국 내수)
- 캐리어: **KOO** (Korea Open)
- 빌드: **`G977NKSU6HWD3`**

다른 모델/캐리어/빌드를 쓸 거면 §3.3 이후의 파일 이름은 거기에 맞춰
바꾸되 구조는 동일.

### 3.2 다운로드 소스

두 가지 경로 — 둘 다 검증됨:

**(a) samfw.com** (브라우저, 가장 간단):
1. `https://samfw.com/firmware/SM-G977N/KOO` 같은 URL 로 이동.
2. 원하는 빌드 (예: `G977NKSU6HWD3`) 의 "Download" 클릭.
3. 다운로드 받은 `.zip` 을 작업폴더 `01_firmware/` 에 둔다.

samfw 는 **부분 펌웨어** (BL+CSC 만, AP 제외) 도 제공한다 — 셸 도달엔
충분.

**(b) samloader** (CLI, 자동화 가능):
```bash
pip3 install --break-system-packages samloader
cd 01_firmware
samloader -m SM-G977N -r KOO checkupdate         # 최신 빌드 확인
samloader -m SM-G977N -r KOO -v G977NKSU6HWD3 download
samloader decrypt ...                            # .enc4 해제 안내대로
```

### 3.3 필수 파일 (★ 셸 도달용 — AP 는 불요)

samfw `.zip` 또는 samloader 결과물 안에 들어있는 `.tar.md5` 들:

| 파일 (예시명) | 안의 핵심 파일 | 용도 | 필수? |
|---|---|---|---|
| `BL_G977NKSU6HWD3_*.tar.md5` | `sboot.bin.lz4` | **BL3 본체 (lz4 압축)** | ★ 필수 |
| `CSC_*G977N*.tar.md5` | `BEYONDX_KOR_SINGLE.pit` | UFS 파티션 테이블 | 권장 (분석용) |
| `AP_*.tar.md5` | `boot.img.lz4`, `system.img.lz4` 등 | 커널·rootfs | 셸엔 불요 |

> ★ **PIT 의 위치 자주 틀림**: AP tar 가 아니라 **CSC tar** 안에 있다.
> 이건 모델·빌드에 무관한 Samsung 펌웨어 패키징 규칙.

다운로드 받은 zip 풀기:
```bash
cd 01_firmware
unzip SM-G977N_*_G977NKSU6HWD3_*.zip
# 안에 BL_*.tar.md5, CSC_*.tar.md5, (AP_*.tar.md5) 가 있다
ls -la *.tar.md5
```

### 3.4 BL3 본체 추출 (sboot.bin)

`sboot.bin.lz4` 를 BL tar 에서 꺼내 lz4 해제:

```bash
cd 01_firmware
# BL tar 안의 파일 목록 확인
tar -tf BL_G977NKSU6HWD3_*.tar.md5

# sboot.bin.lz4 만 추출
tar -xf BL_G977NKSU6HWD3_*.tar.md5 sboot.bin.lz4

# lz4 해제 → 4 MiB sboot.bin
lz4 -d sboot.bin.lz4 ../02_unpacked/sboot.bin
rm sboot.bin.lz4
```

검증:
```bash
ls -la ../02_unpacked/sboot.bin
# 크기 정확히 4,194,304 B (4 MiB) 여야 함 — Samsung 의 4 MiB 컨테이너 규칙
stat -c '%s' ../02_unpacked/sboot.bin
# 4194304

# md5 sanity check (이 빌드: G977NKSU6HWD3)
md5sum ../02_unpacked/sboot.bin
# fa4b7d91c2027cabe488125b8d02c653
```

크기가 4,194,304 가 아니거나 md5 가 다르면 다른 빌드를 받은 것 — 다시.

### 3.5 PIT 추출 (BEYONDX_KOR_SINGLE.pit)

```bash
cd 01_firmware
# CSC tar 안의 .pit 파일 확인
tar -tf CSC_*G977N*.tar.md5 | grep '\.pit$'

# 추출
tar -xf CSC_*G977N*.tar.md5 BEYONDX_KOR_SINGLE.pit
mv BEYONDX_KOR_SINGLE.pit ../02_unpacked/
```

검증 (PIT 매직 확인):
```bash
xxd -e -g4 -l4 ../02_unpacked/BEYONDX_KOR_SINGLE.pit
# 첫 4바이트: 12349876 — Samsung PIT 매직
```

매직이 다르면 잘못된 파일.

### 3.6 (옵션) AP 파티션 — 셸엔 불요

`boot.img`, `system.img` 같은 파티션 이미지는 셸 도달에 필요 없다.
정직성 규칙 §5 의 "UFS 모델은 동작 핸드셰이크까지만, LU 이미지는
불요" 와 일치. 디스크 절약 차원에서 AP 는 다운로드 자체를 안 해도 됨.

만약 분석을 위해 받았다면:
```bash
tar -xf AP_*.tar.md5    # 매우 큼 (수 GiB)
# 필요한 파티션만 lz4 -d
```

### 3.7 펌웨어 디렉터리 최종 상태

```bash
$ ls -la 02_unpacked/
sboot.bin                       4194304   (4 MiB)
BEYONDX_KOR_SINGLE.pit          ~수십 KB
```

이 둘이면 분석 시작에 충분.

### 3.8 펌웨어 정직성 메모

- 받은 펌웨어는 **암호화/서명되지 않은 raw 바이너리** (Samsung 의 일반 배포 형식).
- BL3 본체는 `sboot.bin` 안에 **여러 서브이미지 + 패딩** 의 형태로 들어있다 —
  어느 오프셋부터가 BL3 본체인지는 §4 정적분석에서 도출.
- "당연히 0x... 부터일 것" 같은 가정은 금지. 디스어셈블로 도출.

---

## 4. 정적분석 — 펌웨어 → BL3 → 적재주소 → 진입점

답을 적지 않는다. 기법만 적는다.

### 4.1 펌웨어 → BL3 본체 carve

`sboot.bin` 은 컨테이너 — 여러 서브이미지 + 패딩. BL3 본체 carve 절차:

1. **패딩 경계 찾기.** 일정 정렬 (보통 0x1000 또는 0x4000) 에서 0 패딩이
   끝나고 코드가 시작되는 지점 후보를 모은다.
   ```python
   data = open("02_unpacked/sboot.bin","rb").read()
   # 4KB 정렬에서 직전 0x100 가 0 인 위치를 후보로
   for off in range(0, len(data), 0x1000):
       if off >= 0x100 and data[off-0x100:off] == b'\x00'*0x100:
           print(f"candidate: 0x{off:x}")
   ```
2. **AArch64 부팅 코드 패턴 검색.** 후보 오프셋의 첫 ~30 개 명령에 다음
   이 보이면 부팅 진입점 후보:
   - `mrs xN, currentel` + EL 분기
   - `msr scr_elN/vbar_elN, xN`
   - `msr daifset` / `msr sctlr_elN`
   - 짧은 unconditional `b` 로 메인부 점프
3. **디스어셈블 sanity check.** capstone 으로 그 후보 오프셋부터
   0x100 바이트 디스어셈블. 의미있는 명령 흐름인가? (랜덤 바이트면
   `udf` 가 많이 나옴.)
4. **carve 후 크기 결정.** §4.2 의 적재주소 도출 부산물로 이미지 크기를
   알 수 있다.

### 4.2 적재주소 도출

BL3 는 보통 PIC (PC-상대) 라 적재주소가 코드에 명시되지 않는다.
도출 후보:

- **리터럴풀 분석.** 진입부 근처 (예: 진입+0x80 ~ +0x200) 의 8 바이트
  정렬 영역에 64-bit 절대주소가 들어있다 — 흔히 BSS_start, BSS_end,
  스택 top, 디버그 영역 등. 이 값들의 LSB 와 alignment 로 적재주소
  라운드 값 추정.
- **basefind 류 알고리즘.** 코드 내 분기/콜 타겟이 가장 많이 정합되는
  base 후보 찾기. 라이브러리: `basefind` (Python), 또는 자작.
- **교차검증 (필수).** 도출한 base 가 맞다면, 코드 내 절대주소 (포인터
  배열 등) 가 `[base, base+image_size)` 범위에 들어맞아야 한다. 한두
  개가 아니라 다수가 명중해야 확정.

**금지**: 추측한 적재주소를 그대로 머신에 박는 것. 반드시 교차검증을
거친 값만 사용.

### 4.3 init 디스패처 · init 테이블 · 셸 함수

S-Boot 같은 부트로더의 일반적 구조:
1. 진입 → 초기화 함수 1~2개 호출 → main / dispatcher 로 점프.
2. dispatcher 는 함수 포인터 테이블을 NULL 종료까지 순회 (`blr` 으로 각
   슬롯 호출).
3. 셸은 그 테이블의 한 슬롯 — 콘솔 프롬프트를 출력하고 readline 후
   명령 인터프리터로 디스패치.

도출 절차:

1. **dispatcher 식별.** 진입부에서 `b/bl` 로 도착하는 함수가 dispatcher.
   디스어셈블에서 다음 루프 패턴 찾기:
   ```
   loop:
     ldr xN, [xM, ...]      ; 슬롯 함수 포인터 로드
     cbz xN, end             ; NULL 이면 종료
     blr xN                  ; 슬롯 호출
     add xM, xM, #8          ; 다음 슬롯
     b loop
   ```
2. **테이블 주소 = 디스패처의 첫 ldr 의 베이스.** 그 주소부터 8 바이트씩
   슬롯을 덤프. NULL 까지가 테이블.
3. **각 슬롯 함수 식별 = 함수 시작부 디스어셈블.** 어느 슬롯이 무슨 일을
   하는지는 디스어셈블 + 그 함수가 출력하는 문자열로 식별.
4. **셸 함수 식별.** 프롬프트 문자열 (`#`, `>` 등 부트로더 흔한 패턴) 을
   바이너리에서 grep → 그 주소를 가리키는 코드 찾기 (adrp+add 또는
   literal pool ldr). 그 코드가 들어있는 함수 = 셸 함수. 셸 함수가
   슬롯 테이블 중 어느 인덱스인지 확인.

**금지**: 테이블 주소나 셸 함수 인덱스를 "그쯤일 거다" 로 박는 것.
디스패처의 ldr 베이스를 디스어셈블로 도출.

### 4.4 셸·autoboot 게이트 구조

대부분의 S-Boot 변종에서:
- 셸 함수는 autoboot 게이트를 먼저 호출.
- 게이트는 콘솔 RX 를 폴링해서 특정 입력 패턴 (보통 CR 연타) 이 있으면
  셸 진입, 없으면 autoboot 진행 (커널 부트).
- 게이트의 입력 폴링 timeout 은 셸 함수가 인자로 넘긴다 (0 이면 즉시
  종료, 즉 one-shot).

도출:
- 셸 함수 디스어셈블 → 첫 `bl` 대상 = 게이트.
- 게이트 디스어셈블 → 입력 폴링 루프 패턴 (`bl tstc; cbz; bl getc;
  cmp count, N; b.ne loop`) + 마지막 N글자 검사 (대개 CR `0x0d`).
- 셸 진입 조건: 그 검사 통과 시 비-0 반환 → 셸 함수의 `cbnz w0, ...`
  분기로 셸 루프.

### 4.5 분석 산출물

`04_static-analysis/정적분석_리포트.md` 에 표 형태로 도출한 값과
**각각의 근거**를 적는다:

```markdown
| 값 | 결과 | 도출 근거 |
|---|---|---|
| BL3 진입 오프셋 | 0x… | 0x… 부터 EL 판별 코드 + 앞 0 패딩 |
| 적재주소 | 0x… | 리터럴풀의 BSS_start − 이미지크기, init 테이블 N/N 교차검증 |
| init 테이블 | 0x… | dispatcher 의 첫 ldr 베이스 |
| 셸 함수 슬롯 | #N | "S-BOOT # " 문자열 참조 함수 = 슬롯 #N |
| autoboot 게이트 | 0x… | 셸 함수의 첫 bl 대상 |
```

근거가 없는 값은 적지 않는다.

---

## 5. 머신 `.c` — 최소 시작 (Minimal Viable Machine)

처음부터 모든 페리페럴을 모델링하지 않는다. **최소한**으로 시작해서
정지점이 가르쳐 주는 대로 확장한다.

### 5.1 1차 머신에 들어가야 할 것

- **CPU**: 정확한 코어 (cortex-aXX). **`has_el3 = false`** 가 보통
  안전 (이유 §10 참조). `max_cpus = 1`.
- **`ignore_memory_transaction_failures = false`** — 미매핑 접근이 진짜
  Data Abort 로 드러나야 정지점이 보인다.
- **DRAM**: BL3 적재주소를 포함하는 큰 RAM 영역.
- **페리페럴 윈도우 (register-file)**: 해당 SoC 의 알려진 페리페럴 주소
  범위 한두 개. register-file 의미는 §6.
- **UART (TX 만이라도)**: 콘솔 출력을 보기 위해. 레지스터 offset 은
  SoC 문서 또는 디스어셈블 (RX 폴링 코드가 어느 주소를 읽는지) 로 도출.
- **펌웨어 적재**: `rom_add_blob_fixed(buf, len, 적재주소)`. 펌웨어
  패치는 0개로 시작.

### 5.2 1차에 넣지 말 것

- **타이머·UFS·기타 페리페럴의 동작 모델** — 나중에 필요할 때.
- **펌웨어 패치** — 첫 정지점이 어디인지부터 보고.
- **추측 stub** — 절대.

### 5.3 1차 머신 빌드·실행 → 첫 정지점

빌드하고 짧게 실행 (`timeout 10 qemu ... -d int,unimp -D /tmp/run.log
-serial stdio`). 거의 확실하게 첫 정지점이 나온다. 그게 분석의 출발.

**첫 정지점이 안 나오면** (예: 콘솔에 부팅로그만 흐르고 종료) 머신 설정
이 어딘가 너무 관대한 것 (`ignore_memory_transaction_failures = true`
같은). 다시 확인.

---

## 6. 정직한 모델·우회 — 일반 형식

### 6.1 모델 종류

**register-file** (기본·가장 흔함): 미지의 MMIO 레지스터에 적용.
- write: 값을 저장
- read: 마지막으로 쓴 값 (없으면 0)
- "쓴 값을 기억" — 펌웨어의 합법적 동작
- 미초기화 0 은 "초기화 안 된 페리페럴" 의 정직한 모델
- 진단 로깅: 같은 주소를 N회 이상 read 하면 1회 로그 (행동은 바꾸지
  않음 — 그저 폴링 핫스팟 가시화)

**RAM 영역**: 메모리처럼 쓰이는 영역 (SRAM, 로그버퍼)
- `memory_region_init_ram` 으로 정직한 RAM
- 페리페럴 윈도우와 겹치면 `add_subregion_overlap` 으로 우선순위 ↑

**동작 모델 (behavioral)**: 페리페럴이 단순 register-file 로 안 풀릴
때만 — 특정 비트의 set/clear 가 외부 이벤트로 일어나야 하는 경우.
- 예: 핸드셰이크 (커맨드 발행 → 완료 비트 set), PLL lock 비트
- "필요한 비트만" set. 다른 비트는 register-file 기본값.
- 동작 모델은 페리페럴 표준 (UFSHCI 등) 이나 디스어셈블로 정당화.

### 6.2 우회 (펌웨어 패치)

펌웨어 패치는 **반드시** 우회로 분류. 다음을 반드시 적는다:

```
[대상]   함수 또는 명령 주소
[이유]   왜 우회 불가피한가
         (에뮬할 수 없는 의존성: 보안 모니터/배터리/eFuse/iROM 등)
[방법]   바이트 단위 변경 (mov w0,#0; ret 같은 구체적 명령)
[부작용] 이 우회가 다른 동작에 미치는 알려진 영향 (있다면)
```

우회의 정당한 사유 (예시 — 당신 케이스가 맞는지는 당신이 분석):
- 에뮬레이션 환경에 없는 별도 바이너리에 의존 (보안 모니터, BL31 등)
- 에뮬레이션 환경에 없는 하드웨어 의존 (배터리·연료게이지·OTP 등)
- 일회성 하드웨어 동작 (HW 카운터, 트림 등)

부당한 사유 (이걸로 우회하면 정직성 위반):
- "분석이 귀찮아서"
- "에뮬할 수 있지만 시간이 걸려서"
- "정지점을 통과시키기 위해" (이유 분석 없이)

### 6.3 우회의 범위

- **타깃**: 한 명령 또는 한 함수만. 예측가능.
- **일괄**: 한 클래스의 명령 전부를 같은 이유로 패치 (예: 모든 `smc`).
  단, **같은 근본원인** 이 모든 인스턴스에 적용됨을 트레이스/분석으로
  입증한 뒤. "그냥 다 패치하니까 통과" 는 .bak 에이전트의 길.

### 6.4 ★ SM-G977N (`G977NKSU6HWD3`) 가 필요로 하는 모델 — 카테고리

> ⚠️ **이건 카테고리 체크리스트지 답이 아니다.** 각 항목의 정확한 주소·
> 크기·세부 동작은 §4 (정적분석) 와 §7 (반복 루프) 가 가르치는 대로
> 당신이 직접 도출한다. 이 표는 "어떤 종류의 모델이 결국 필요해질지" 의
> 사전 안내일 뿐.

#### 6.4.1 CPU·머신 설정 (값이 아닌 결정)

| 결정 | 어떻게 결정하나 |
|---|---|
| **CPU 코어** | Exynos 9820 의 대표 코어와 호환되는 cortex-aXX 선택. SoC 스펙 또는 BL3 가 사용하는 ARMv8 기능 (capstone 디스어셈블로 확인) 기반 |
| **EL3 활성 여부** | BL3 진입스텁을 디스어셈블해 EL 분기 로직 확인. EL3/EL2/EL1 각 경로가 vbar 를 어떻게 설정하나? 그 중 정상으로 보이는 (vbar 를 의미있는 주소로 설정하는) 경로의 EL 을 선택. (실측 결과: EL3 경로의 vbar 설정이 비정상이므로 **EL3 비활성화 + EL2 리셋이 정답**) |
| **`max_cpus`** | 1. 보조 CPU 코어를 모델링하지 않으므로 → §6.5 우회 #1 과 짝 |
| **`ignore_memory_transaction_failures`** | **반드시 `false`**. silent 통과시키면 미매핑 페리페럴이 안 드러나서 정지점 안 보임 |

#### 6.4.2 RAM 영역 (3 카테고리)

| 카테고리 | 무엇 / 왜 필요 | 어떻게 발견·확정 |
|---|---|---|
| **DRAM** | BL3 의 적재주소·BSS·스택이 들어가는 큰 RAM | 적재주소는 §4.2 (리터럴풀 분석) 로 도출. 크기는 부팅로그의 `xxxxMB` 메시지 + SoC 사양으로 확정 |
| **iRAM/SRAM** | 이전 부트 스테이지가 채워 둔 작은 SRAM (칩 정보·클럭 정보 등) | 첫 회차에서 그 영역을 읽는 Data Abort 의 FAR 로 발견. 후속 회차의 FAR 들로 영역 확장 |
| **로그/디버그 SRAM** | BL3 가 로그 디스크립터 (매직 + 버퍼 ptr) 를 기록하고 `stp`/memcpy 로 로그를 누적하는 SRAM | Data Abort 의 FAR 가 어느 매직 (예: `"LOGM"`) 근처의 SRAM-스러운 주소면 이 카테고리. 보통 8B `ldp/stp` 가 떨어짐 → register-file ops 의 `valid.max=8` 결정적 |

#### 6.4.3 페리페럴 윈도우 (register-file, 2~3개)

| 카테고리 | 무엇 / 왜 필요 | 어떻게 발견·확정 |
|---|---|---|
| **메인 페리페럴 윈도우** | SoC 의 주된 페리페럴 (UART/타이머/CMU/PMU/I2C/UFS 등) 이 모인 주소 범위 | SoC 데이터시트 또는 디스어셈블에서 가장 자주 등장하는 base address. 보통 단일 큰 윈도우 |
| **보조 페리페럴 윈도우** | 일부 SoC 는 보조 페리페럴 (디버그 SRAM·보안영역) 을 별도 고주소 윈도우에 둠 | 반복 루프에서 Data Abort 의 FAR 가 메인 윈도우 밖이면 새 윈도우 발견 → register-file 윈도우 추가 |

register-file ops 의 핵심 설정 (★ 누락 시 결정적 함정):
```c
.valid.min_access_size = 1, .valid.max_access_size = 8,  // ldp/stp 허용
.impl.min_access_size  = 1, .impl.max_access_size  = 4,  // QEMU 가 4B 로 분할
```

`valid.max = 4` 만 두면 8B `ldp`/`stp` 가 거부되어 로그버퍼 memcpy 가
폴트 (실측 함정).

#### 6.4.4 실모델 페리페럴 (페리페럴 윈도우 위 overlap, prio 1)

| 페리페럴 | 왜 register-file 로 안 풀리나 | 어떻게 위치 도출 |
|---|---|---|
| **UART** | 외부 입력 흐름제어가 필요. 입력 echo·polling 같은 동작이 단순 read/write 로 안 됨 | RX 폴링 코드가 어느 주소를 읽는지 디스어셈블. 그 주소가 UART 의 status register. SoC 의 UART 패밀리 표준 (Exynos UART) 의 레지스터 셋 따르기 |
| **타이머** | 자유진행 카운터가 필요. register-file 은 시간이 안 흐름 → mdelay 무한 폴링 | mdelay/udelay 함수를 디스어셈블. 어느 주소를 어떻게 읽어 시간을 계산하나? 전형적 패턴: `count = *(reg_A) - *(reg_B)` |
| **UFS HCI** | UFSHCI 표준 핸드셰이크 — 단순 register-file 로는 링크업 안 됨 | 반복 루프에서 UFS 의 IS 레지스터 무한 폴링으로 발견. UFSHCI 2.1 표준의 IS/HCS/UICCMD/도어벨 동작 구현 |

##### UART 의 핵심 (가장 흔히 빠지는 함정)

- TX 측: 콘솔 putc → `qemu_chr_fe_write_all`.
- RX 측: 내부 ring buffer + chardev `can_receive`/handlers 등록.
- **URXH 같은 RX read 후 반드시 `qemu_chr_fe_accept_input(&chr)` 호출**.
  누락하면 외부 입력이 한 번 차고 끊긴다. **결정적 버그.**
- QEMU 10.x 의 chardev 타입은 `CharFrontend` (옛 예제의 `CharBackend`
  아님).

##### 타이머

자유진행 다운카운터 패턴. 그 페리페럴이 사용하는 시간 단위·rate 는 BL3 의
mdelay 계산식을 디스어셈블해서 도출 (예: `(devfreq/1000) * ms` → ticks 의
rate 결정).

##### UFS HCI 동작모델

UFSHCI 2.1 표준의 정상적 핸드셰이크만 구현하면 충분:
- UIC 명령 발행 → IS 의 UCCS 비트 set.
- 전송 도어벨 write → IS 의 UTRCS 비트 set, 도어벨 자동 클리어.
- IS write → write-1-to-clear.
- HCS read → 모든 ready 비트 set.

SCSI/UPIU 데이터는 처리하지 않음 (LU 이미지 없음 — 셸엔 불요).

### 6.5 ★ SM-G977N (`G977NKSU6HWD3`) 가 필요로 하는 우회 — 3 카테고리

> ⚠️ 동일 경고. 이 3 카테고리가 정답표가 아니다. §7 의 반복 루프가
> 가르치는 정지점들이 결과적으로 이 3종으로 수렴해야 한다. **우회를
> 미리 박지 말고, 정지점이 가리키면 그제서야 추가한다.** 우회마다
> `[대상 / 이유 / 방법 / 부작용]` 을 우회목록 문서에 적는다.

#### 우회 카테고리 #1 — SMP sync 대기 NOP (단일 명령)

| 항목 | 내용 |
|---|---|
| **무엇을** | 보조 CPU 코어가 set 해야 하는 동기화 변수를 무한 대기하는 `cbz`/loop 한 군데 |
| **왜** | `max_cpus=1` — 보조코어 미모델링 → sync 변수 영원히 0. 셸은 주코어 동작이므로 SMP 불요 |
| **어떻게** | 해당 `cbz` → `nop`. 단일 명령 타깃 패치 |
| **언제 발견되나** | 부팅 도중 콘솔이 멈춤. PC 트레이스의 hot loop 가 `cbz w0, #-N` 한 명령 — 그 명령이 대상 |
| **부작용** | 없음. PSCI + 다중 CPU 모델을 도입하면 제거 가능 (대안) |
| **도출 절차** | (1) 콘솔 멈춤 정지점 → 짧은 `-d exec` 트레이스 → hot PC. (2) 그 PC 의 명령이 `cbz`/짧은 back-edge → 디스어셈블로 대기 변수 확인. (3) 대상 = 그 `cbz` 명령 한 개 |

#### 우회 카테고리 #2 — `smc` 일괄 패치 (단일 근본원인)

| 항목 | 내용 |
|---|---|
| **무엇을** | BL3 내 **모든** `smc` 명령 (감지 마스크 §6.6) |
| **왜** | S-Boot 은 EL2 동작이며 모든 smc 는 별도 바이너리인 EL3 보안 모니터 (BL31 류) 를 호출. 리호스트 펌웨어에 그 모니터 부재 → EL2 에서 smc → Undefined 트랩 → S-Boot 가 BOOTLOADER UPLOAD(E_SYNC) 진입. 같은 근본원인이 모든 smc 인스턴스에 적용됨 |
| **어떻게** | 모든 smc 를 `mov x0, #0` (SMCCC_SUCCESS) 로 치환. `hvc` 는 그대로 |
| **언제 발견되나** | 부팅 도중 Undefined Instruction 예외 → BOOTLOADER UPLOAD(E_SYNC). ELR 디스어셈블 → smc |
| **부작용** | 모든 secure call 이 SUCCESS 로 보임. OTP·anti-rollback 같은 보안 검사는 통과처럼 보이지만 그 분기는 셸 도달과 무관 |
| **일괄 전환의 정당화** | 처음엔 단일 smc 만 패치. 다음 회차의 정지점이 또 smc — 같은 패턴 → 트레이스로 같은 근본원인 (모두 EL3 모니터 부재) 확인 후 일괄로 전환. "그냥 다 패치하니까 통과" 는 금지 |
| **도출 절차** | (1) Undefined ELR 디스어셈블로 smc 확인. (2) S-Boot 의 EL3 vbar 설정이 정상인지 확인 (보통 비정상 → 모니터 부재). (3) 첫 회차엔 그 smc 만 패치. (4) 다음 회차에 또 smc 면 일괄 전환 |

#### 우회 카테고리 #3 — 보드 init 함수 스텁 (단일 init 슬롯)

| 항목 | 내용 |
|---|---|
| **무엇을** | 보드 환경 의존 검사가 모인 init 슬롯 한 항목 (전형적 이름: `mach_board_main` 또는 비슷한 보드/플랫폼 init) |
| **왜** | 그 함수의 서브트리에 다수의 환경 의존 검사: ① 배터리전압 검사 → 임계 미만이면 `board_power_off(PO_VOLTAGE_LOW)`. ② UFS 프로비저닝 → LU 이미지 없는 환경에서 NULL 역참조. ③ cmdline 무결성 등. 리호스트엔 배터리·PMIC·UFS LU 이미지가 없어 각각 정상적으로 실패한다. 셸은 바로 다음 슬롯 |
| **어떻게** | 슬롯의 함수 본체 첫 두 명령을 `mov w0, #0` + `ret` 로 치환. 단일 init 슬롯 타깃 |
| **언제 발견되나** | BOOTLOADER UPLOAD(PO_*) 또는 UPLOAD(E_SYNC) reason 으로 발견. `board_power_off` 같은 함수에 어느 reason 코드가 들어가는지 역추적 |
| **부작용** | ★ **이 슬롯이 printf-콘솔 (UART) 라우팅도 설정한다.** 스텁하면 셸의 서식 출력 (프롬프트·명령목록) 이 UART 콘솔 대신 S-Boot 로그버퍼로 라우팅됨. UART 에는 입력 에코만. §11 검증은 로그버퍼 `pmemsave` 로. 정직히 명시 |
| **대안** | 서브트리의 각 검사를 개별로 스텁 (battery + UFS-prov + cmdline + …) — whack-a-mole. 단일 슬롯 스텁이 운영상 합리적. 부작용만 정직히 |
| **도출 절차** | (1) UPLOAD reason 확인. (2) `board_power_off` 류 함수 위치 (콘솔 문자열 추적). (3) 그 함수의 호출자 역추적으로 어느 검사가 실패했는지 확인. (4) 그 검사가 어느 init 슬롯의 서브트리에 있는지 — `bl` 호출 그래프로. (5) 단일 슬롯 스텁 결정 → 부작용 (콘솔 라우팅) 확인 → 정직히 기록 |

#### 우회 식별 절차 요약 (반복 루프와의 연결)

1. §7 의 반복 루프에서 정지점 분류 (Data Abort / Undefined / 무한폴링 /
   UPLOAD / 멈춤).
2. 각 정지점이 카테고리 #1~#3 중 어디 속하는지 판단:
   - **콘솔 멈춤 + hot PC 가 짧은 back-edge** → #1 후보.
   - **Undefined + ELR=smc** → #2 후보.
   - **UPLOAD reason** → #3 후보 (또는 모델 부족).
3. 해당 카테고리의 도출 절차로 정확한 주소·범위 도출.
4. 우회목록 문서에 `[대상 / 이유 / 방법 / 부작용]` 으로 기록.
5. 다음 회차에 다른 정지점으로 이동했는지 트레이스로 확인 (효과 검증).

### 6.6 패치 인코딩 빠른 참조 (AArch64 little-endian)

| 의도 | 인코딩 (LE 32-bit) | 비고 |
|---|---|---|
| `mov w0, #0` | `0x52800000` | MOVZ w0, #0 |
| `ret` (= `ret x30`) | **`0xD65F03C0`** | ★ 함정: `0xD65F03E0` 은 `ret xzr` (0번지 점프) — 절대 쓰지 말 것 |
| `nop` | `0xD503201F` | HINT #0 |
| `smc #0` (감지용) | mask `0xFFE0001F` == `0xD4000003` | imm5 무시 |
| `hvc #0` (감지용) | mask `0xFFE0001F` == `0xD4000002` | |

패치 바이트를 만든 뒤 **capstone 으로 reverse-disassemble 해서 의도한
명령인지 한 번 확인**.

---

## 7. 반복 리호스팅 루프 — 정지점 → 처치 일반론

매 회차 = 정지점 1개 = 변경 1개 = `PROGRESS.md` 1줄.

### 7.1 한 회차의 표준 절차

```bash
# 1) 빌드
cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64

# 2) 짧게 실행 (정직한 모드)
cd $WS
timeout 12 05_qemu/qemu-system-aarch64-sboot \
    -M <your-machine> -cpu <cpu> -bios 03_bl3/<bl3.bin> \
    -serial stdio -display none -nographic \
    -d int,unimp,guest_errors -D /tmp/run.log \
    </dev/null > /tmp/console.txt 2>&1

# 3) 분류 (다음 절)

# 4) 분석 → 변경

# 5) 정직성 자가체크 (§9)

# 6) PROGRESS.md 한 줄 추가
echo "| run N | <정지점> | <대응> |" >> PROGRESS.md

# 7) 디스크 정리
rm -f /tmp/run.log /tmp/console.txt
df -h ~
```

### 7.2 정지점 분류와 처치 일반론

#### (a) Data Abort + FAR=X

질문:
- X 가 어떤 종류의 주소인가?
  - 메모리·SRAM·로그버퍼 같은 영역: RAM 추가 후보
  - SoC 페리페럴 윈도우 안: register-file 윈도우 확장 또는 새 윈도우 추가
  - SoC 페리페럴 윈도우 밖이지만 의미있는 영역: 미지의 페리페럴 윈도우 발견
- ELR 의 명령은? `ldr w/x`/`stp`/`str` — 크기와 의도 (스칼라 vs 16B 페어, RW 등)
- ESR 의 DFSC 비트 (0x10 = external abort, 0x21 = alignment) 로 원인 좁히기

처치:
- 영역이 RAM 처럼 쓰이면 → `memory_region_init_ram`
- MMIO 처럼 쓰이면 → register-file 윈도우
- 8B `ldp/stp` 가 거부됐다면 → ops 의 `valid.max_access_size` 를 늘려야

#### (b) Undefined Instruction + ELR=X

ELR 의 명령을 디스어셈블로 확인:
- **`smc`**: 보통 EL3 보안 모니터 호출. 에뮬 환경에 보안 모니터가 없으면
  Undefined 로 트랩 → S-Boot 의 sync 핸들러가 보통 panic/upload.
  - 정당한 우회: 보안 모니터가 별도 바이너리로 부재함을 확인.
  - 처치: 그 smc 만 패치할지, 같은 근본원인이 모든 smc 에 적용되는지
    트레이스로 판단 (예: 모든 smc 가 같은 모니터를 호출).
- **`hvc`**: 비슷. EL2 hypervisor 호출.
- **기타 undef**: CPU feature 미지원? 코드 손상? 잘못된 분기? 케이스별.

#### (c) 무한 폴링 (register-file 의 read 카운트 로그)

질문:
- 어느 주소가 64+/1024+/65k+ 회 폴링됐는가?
- 그 주소를 읽는 코드를 찾고 (디스어셈블에서 그 주소를 만드는 mov+movk
  검색, 또는 base register + offset 패턴 분석), 코드 문맥 파악:
  - 어떤 비트를 검사하나? (`tbnz`/`tbz`/`cbz` + 즉시값)
  - 어떤 동작 직후의 폴링인가? (방금 어떤 레지스터를 썼는지)
- 그 페리페럴 종류는? (SoC 페리페럴 맵 + 표준 — UFSHCI/USB/CMU 등)

처치:
- 페리페럴 표준이 있는 경우 (예: UFSHCI 의 IS 레지스터): 표준 동작
  모델 (커맨드 → 완료비트 set).
- 사설 페리페럴이고 폴링이 "단순 ready" 비트면: read 시 그 비트만 set.
- 폴링이 의미있는 핸드셰이크면: 동작 모델 작성 (어느 비트를 어떤 조건에
  set 하는지).

**금지**: read 카운트로 분기 (12회 0, 그 뒤 0xFFFF/0 교대 같은) —
적응형 토글 stub. 펌웨어가 잘못된 분기로 갈 수 있음.

#### (d) BOOTLOADER UPLOAD / panic / reset

콘솔에 reason 코드가 있나? S-Boot 은 보통 reason 문자열을 출력:
- `E_SYNC` / `E_PABT` / `E_DABT`: 동기 예외. 그 직전 회차에 어떤 예외가
  있었는지 트레이스 (`-d int`) 로 확인. 보통 §7.2 (b) 의 처치로 해결.
- `PO_LOW_BATTERY` / `PO_INVALID_CMDLINE` / `PO_CHARGER_*` 등: 환경 의존
  검사 실패. 어느 검사가 실패했는지 디스어셈블로 역추적:
  1. `board_power_off` 같은 함수 식별 (문자열 + 호출 trace).
  2. 그 함수의 인자 (reason 코드) 가 어디서 결정되는지 역추적.
  3. 결정 지점 = 환경 의존 검사. 이 검사가 우회 정당한지 판단:
     - 배터리/PMIC: 에뮬 환경에 없으면 정당.
     - cmdline 무결성: 데이터 의존이면 정당 (LU 이미지 부재).
- `PROMPT_NOISE`: 셸 진입 후 일정 시간 안에 실명령 미입력. 입력 패턴
  문제 — 머신 잘못이 아님.

처치 시 주의:
- 그 환경검사 한 함수만 스텁할 것인가, 그 검사를 부르는 init 슬롯 전체를
  스텁할 것인가? 후자가 단순하지만 **부작용** (그 슬롯이 다른 정상 동작
  도 한다면) 을 정직히 명시.

#### (e) 콘솔 멈춤 (예외도 폴링도 없음)

펌웨어가 CPU 에서 무한 루프 중. 정지점이 어디?

```bash
# 짧은 PC 트레이스
timeout 4 qemu-system-aarch64 ... -d exec -D /tmp/exec.log
# hot PC 히스토그램
python3 -c "
import re, collections
c = collections.Counter()
for line in open('/tmp/exec.log'):
    m = re.search(r'/00000000([0-9a-f]{8})/', line)
    if m: c[m.group(1)] += 1
for pc, n in c.most_common(15): print(pc, n)
"
rm /tmp/exec.log
```

hot PC 디스어셈블 → 무엇을 기다리는지 (MMIO? 메모리? 카운터?) 분석.

### 7.3 회차 이력 기록

`PROGRESS.md` 에 회차 표:

```markdown
| 회차 | 정지점 | 대응 |
|---|---|---|
| A | Data Abort FAR=0x… | iRAM RAM 영역 추가 |
| B | Undefined ELR=0x… (smc) | 그 smc 패치 |
| … | … | … |
```

각 회차의 변경은 PROGRESS.md 와 우회목록 (`06_machine/우회_패치_목록.md`)
에 즉시 반영. 누적된 변경이 머신·펌웨어 패치 전체.

---

## 8. 외부 입력 — 셸 도달

### 8.1 일반 원칙

- autoboot 게이트는 보통 one-shot — 적절한 입력 패턴 필요.
- 사람이 키보드로 칠 때는 키 자동반복으로 자연히 해결되지만, 자동화된
  하니스에서는 타이밍·UART 흐름제어가 필요.

### 8.2 UART RX 흐름제어 — QEMU 의 chardev

QEMU 의 chardev 흐름제어를 정확히 다루지 않으면 외부 입력이 끊긴다:
- `qemu_chr_fe_set_handlers(..., can_receive=can_rx, ...)` 로 등록.
- `can_rx` 가 0 을 반환하면 QEMU 가 입력 공급 중단.
- 한 바이트 소비할 때 **`qemu_chr_fe_accept_input(&chr)`** 를 호출 안
  하면 QEMU 가 다시 보내지 않는다.

이 누락이 가장 흔한 함정.

### 8.3 셸 출력 라우팅의 변동

부트로더는 보통 두 출력 경로:
- 저수준 putc / 입력 echo: 직접 UART 로 — 보드 init 와 무관.
- 서식 출력 (printf): 보드 init 가 console device 를 설정한 뒤에야
  UART 로 라우팅. 보드 init 의 일부를 우회/스킵하면 printf 가 다른 곳
  (보통 로그버퍼) 으로 라우팅된다.

증상: UART 에 입력 에코는 보이지만 프롬프트/명령목록이 안 보임. 이때:
- 로그버퍼 (메모리 덤프) 캡처: QEMU monitor `pmemsave 0xADDR SIZE FILE`
- `strings FILE | grep` 로 프롬프트·명령목록 추출.
- 정직히 명시: "이 우회의 부작용으로 서식출력이 UART 가 아니라 로그
  버퍼로 라우팅됨. 검증은 메모리 덤프로."

### 8.4 하니스 작성 가이드라인

- 머신은 입력을 만들지 않는다.
- 하니스는 외부 프로세스. QEMU 의 stdin (`-serial stdio`) 에 바이트를
  쓴다. 입력 패턴을 결정.
- 반응형 (출력을 보고 단계 전환) 이면 더 안정. 콘솔의 특정 마커 (정해진
  부팅로그 라인 등) 를 보고 다음 입력.
- "help 동작 확인" 등 명령 디스패치 검증은 반드시 외부 하니스가 명령을
  입력하는 형태로. **머신이 명령을 만들어 자기 자신에게 입력하면 무효.**

### 8.5 PROMPT_NOISE 같은 self-defense

S-Boot 류 부트로더는 "셸 진입 후 N초 안에 유효한 명령 없으면 panic" 같은
방어 로직이 있다. 하니스는 셸 진입 후 즉시 (수십초 이내) 실명령을 입력.

---

## 9. 정직성 자가체크리스트 (LLM 이 매 턴 끝에)

매 회차 끝에 LLM 이 자기 자신에게:

- [ ] 이번 변경은 **펌웨어 또는 머신** 어느 쪽인가? 펌웨어면 우회 목록에
  `[대상 / 이유 / 방법 / 부작용]` 형식으로 적었는가?
- [ ] 변경한 모든 주소·바이트·인코딩은 **디스어셈블 또는 실행관찰** 로
  도출했는가? 어느 회차의 어느 로그/디스어셈블 라인에서?
- [ ] 진행이 됐다고 판단했다면 **PC 트레이스 또는 새 콘솔 출력** 으로
  확인했는가? 어느 PC 또는 어느 라인이 새로 나왔는가?
- [ ] 무한폴링/예외가 사라졌는가, 아니면 **다른 정지점으로 이동** 했는가?
  같은 정지점이 반복되면 그 회차의 변경은 효과 없음 → 다시.
- [ ] **토글/추측 stub 또는 결과 하드코딩** 을 도입하지 않았는가?
- [ ] 이번 변경이 **다른 정직한 모델·정지점을 가리는 일** 은 없는가?
  (예: `ignore_memory_transaction_failures=true` 켜기, 일괄 패치로 다른
  정지점 묻기)
- [ ] `PROGRESS.md` 의 회차 표에 이 회차를 추가했는가?

한 항목이라도 "아니오" 면 그 변경은 무효. 다시 한다.

---

## 10. 함정 (meta-level — 답이 아닌 경고)

답을 적지 않지만, 분석 자체를 방해하는 환경/도구의 함정들:

### 10.1 도구·환경

- **`-d exec` 로그 크기**: 5~10초에 1 GiB. 디스크 보호 안 하면 작업이
  중단되고 진행이 막힌다. 매 실행 끝에 즉시 삭제.
- **`-icount`**: TCG 의 `cpu_io_recompile` 무한루프로 사실상 hang.
  사용 금지.
- **QEMU 의 chardev 흐름제어 누락**: 외부 입력이 한 번 버퍼 차고 멈춤.
  RX 소비 시 `qemu_chr_fe_accept_input` 호출 필수.
- **QEMU 10.x 의 chardev 타입명**: `CharBackend` 가 아니라 `CharFrontend`.
  옛 예제 그대로 가져다 쓰면 컴파일 에러.
- **virtiofs 마운트 (`/mnt/c/...`) 의 I/O 속도**: 매우 느리고 캐시 일관성
  문제도 있음. 로그·바이너리는 Linux 측 ext4 (`~/qemu-build`, `/tmp`)
  에 두고, 작업폴더 마운트에는 소스·문서만.

### 10.2 머신 설정

- **`ignore_memory_transaction_failures = true`**: 미매핑 페리페럴이
  silent 로 통과 → 정지점 안 보임. **반드시 false.**
- **`has_el3 = true` 결정 문제**: BL3 진입스텁이 EL3 setup 을 어떻게
  하는지 디스어셈블로 먼저 확인. 진입스텁이 EL3 경로에서 `vbar_el3`
  를 비정상값으로 설정하면 (실제로 흔함) 첫 예외부터 폭주. EL2/EL1 진입
  경로가 정상이면 `has_el3 = false` 로 리셋이 안전.
- **`valid.max_access_size = 4` 만**: 8B `ldp`/`stp` 가 들어오면 거부.
  `valid.max=8, impl.max=4` 로 두어 QEMU 가 분할 호출하게 한다.

### 10.3 인코딩

- **`ret` 인스트럭션**: `0xD65F03C0` (`ret x30`) 와 `0xD65F03E0`
  (`ret xzr` = 0번지 점프) 은 비슷해 보이지만 동작이 완전 다르다.
  디스어셈블러는 둘 다 `ret` 으로 표기. 펌웨어 패치로 stub 을 만들
  때 정확한 인코딩 확인 (정상 함수의 `ret` 을 디스어셈블 → `D65F03C0`
  인지 본 뒤 그 값을 쓴다).
- AArch64 인코딩은 직관적이지 않으므로 패치 바이트 생성 시 capstone
  으로 reverse-disassemble 해서 의도한 명령이 맞는지 확인.

### 10.4 분석

- **하나의 정지점에 여러 변경**: 다음 정지점이 어느 변경 때문에 나타났
  는지 알 수 없게 됨. 한 회차 = 한 변경.
- **트레이스 없이 "진행" 판정**: 콘솔에 줄이 더 나왔다고 진행이 아니다.
  PC 트레이스 또는 새 종류의 정지점이 나와야 진행.
- **regex 매칭 단독으로 성공 판정**: 펌웨어가 그 문자열을 출력했다고
  실행이 거기 도달한 건 아닐 수 있다 (코드의 일부로 그 문자열을 형식
  화해서 다른 곳에 쓸 수도 있음). PC 트레이스 또는 메모리 덤프와 함께.

### 10.5 우회

- **자가주입 (머신이 입력+명령을 만듦)**: 검증이 순환 — 무효.
- **적응형 토글 stub**: 추측에 추측을 쌓는 것. 절대 금지.
- **일괄 패치를 "어차피 안 되니까" 로 정당화**: 근본원인이 모든 인스턴스
  에 동일하게 적용됨을 증명해야 일괄이 정당.

---

## 11. 검증 (실제 실행으로만)

GOAL.md 의 성공기준은 다음 모두를 실제 실행으로:

1. **PC 트레이스가 셸 함수와 셸 명령루프에 도달.** exec 트레이스에서
   해당 PC 들이 관찰됨.
2. **부트로더 프롬프트가 실제 생성됨.** UART 또는 (라우팅 부작용이 있다면)
   로그버퍼 메모리 덤프에서 프롬프트 문자열 확인.
3. **셸이 외부 명령을 디스패치.** 외부 하니스의 명령에 대해 명령 인터
   프리터의 출력이 생성됨 (`Following commands are supported:` 같은
   디스패치 산출물).
4. **위를 실제 트레이스/콘솔 출력/메모리 캡처로 확인.** regex 매칭 단독
   불인정.

증거:
- `07_logs/run_honest_model.txt` — 전체 부팅로그.
- `07_logs/SHELL_REACHED_evidence.txt` — 셸 도달·디스패치 증거 (트레이스
  요약 + 메모리 덤프 / UART 캡처).

---

## 12. 산출물

| 파일 | 내용 |
|---|---|
| `06_machine/<machine>.c` | QEMU 머신 (정직 모델 + 우회 N종) |
| `06_machine/harness.py` | 외부 입력 하니스 |
| `06_machine/우회_패치_목록.md` | 우회 N종 + 모델 목록 (정직 형식) |
| `04_static-analysis/정적분석_리포트.md` | 모든 도출 근거 |
| `07_logs/run_honest_model.txt` | 부팅로그 |
| `07_logs/SHELL_REACHED_evidence.txt` | 셸 증거 |
| `PROGRESS.md` | 회차별 이력 |
| `GOAL.md` | 목표·성공기준 |

---

## 13. 마무리 — 한 줄로

> **회차 = 정지점 1개 = 분석 1개 = 변경 1개 = 기록 1줄.**
> 변경의 모든 값은 디스어셈블 또는 실행관찰로 도출. 추측 금지.
> 입력은 외부에서. 우회는 우회로 명시. 못 간 곳은 못 갔다고 기록.

이 한 줄을 어기는 모든 것은 무효 — 다시.