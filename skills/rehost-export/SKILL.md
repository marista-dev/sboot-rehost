---
name: rehost-export
description: 완성된 리호스팅을 "빌드 없이 바로 실행" 가능한 공유 키트로 내보낸다. active(또는 workdir=<id>) 워크스페이스의 트랙 목표 완료를 확인한 뒤, examples/ 구조처럼 프리빌트 QEMU + 펌웨어/디스크 이미지 + machine 소스 + 스크립트 + docs + evidence 를 rehost_exports/<model>_<build>/track<N>/ 에 조립. 이 폴더는 항상 gitignore. 생성 위치를 사용자에게 안내.
---

당신은 **결과물 내보내기(export)** 오케스트레이터. 사용자가 sboot/kernel 목표까지 도달한 뒤
`/rehost-export` 를 부르면, **다른 사람이 빌드 없이 바로 실행**할 수 있는 키트를 만든다.

- 대상: active(또는 `workdir=<id>`) 워크스페이스.
- 산출: `<cwd>/rehost_exports/<model>_<build>/track<N>/` (한 펌웨어에 track1·track2 폴더가 각각).
- **이 폴더들은 항상 gitignore** (프리빌트 QEMU·펌웨어 대용량/저작권).

---

## Step 0 — 완료 확인 (★ 미완이면 export 금지)

INPUT.md 의 track 확인 후 그 트랙의 **목표 도달**을 검증:
- **트랙 1**: `VERIFICATION.md` 가 **5/5 REAL** (진짜 셸 도달). 4/5 이하면 "아직 FORCED — export 불가" 안내 후 종료.
- **트랙 2**: 목표 등급 도달. K1=`Run /init`, K2=`erofs dm-N mounted`, **K3=`sda: sda1..`(진짜 파티션)** —
  콘솔/VERIFICATION 로 확인. 미도달(예 K3 인데 partitions 미도달)이면 "미완 — export 불가" 안내 후 종료.

완료면: `bash <PLUGIN>/scripts/journal.sh <WS> session-start "/rehost-export" "키트 생성 track <N>"`.

## Step 1 — 대상 경로 결정

- `model`/`build` = INPUT.md 슬롯. firmware key = `<model>_<build>` (build 미상이면 `<model>_<id>`).
- `DEST = <cwd>/rehost_exports/<firmware>/track<track>/`. 이미 있으면 갱신 전 확인(덮어쓰기 경고).

## Step 2 — 키트 조립 (기계적)

프리빌트 QEMU 경로 확인: `~/qemu-build/qemu-10.2.2/build/qemu-system-aarch64`.
`scripts/make_export.sh` 호출 (env 로 파라미터):

```
WS=<workspace> TRACK=<1|2> DEST=<dest> \
QEMU=~/qemu-build/qemu-10.2.2/build/qemu-system-aarch64 \
MACHINE=<INPUT machine name> CPU=<cpu> \
[KCMDLINE="<트랙2 cmdline>"] [INPUT_CMD=help] \
[EUFS_LU_IMAGE=<트랙2 K3 디스크> EUFS_LBS=4096] \
bash <PLUGIN>/scripts/make_export.sh
```

이게: `bin/`(프리빌트 QEMU) + `firmware/`(sboot.bin 또는 Image/dtb/initrd) + `machine/`(machine.c
또는 machine_kernel.c + exynos_ufs.c/.h) + `scripts/`(patch·build) + `evidence/`(console/VERIFICATION/
JOURNAL/PROGRESS/STATIC) + turnkey `run.sh`·`setup.sh`·`.gitignore` 생성.

**대용량 이미지(트랙 2 K3 super/disk)**: make_export 가 자동으로 못 넣은 것은 직접 `firmware/` 로
복사 (또는 너무 크면 `firmware/README.txt` 에 "본인 disk.img 를 여기 두세요" 안내 + run.sh 가 `EUFS_LU_IMAGE` 참조).

## Step 3 — 문서 생성 (docs/ + README + HOW-TO-RUN)

워크스페이스의 JOURNAL/PROGRESS/우회목록/VERIFICATION 을 근거로 `DEST/docs/` 에 서술:
- `01_what-was-built.md` — 무엇을 리호스트했나 (트랙·등급·도달 지점).
- `02_boot-chain.md` — 부팅 체인 상 이 트랙의 진입점.
- `03_trial-and-error.md` — JOURNAL 의 시행착오(원인/분석/해결) 요약.
- `04_timeline.md` — JOURNAL 세션·회차 시각 타임라인.
- `05_bypasses.md` — 우회_패치_목록 (`[대상/이유/방법/부작용]`).
- `06_verification.md` — VERIFICATION 5/5 (또는 K3 마일스톤) + 증거.

`DEST/README.md`(개요 + 한 줄 실행) + `DEST/HOW-TO-RUN.md`(전제·실행·재빌드). 모든 서술은 실제
기록 근거로만 (지어내기 금지, 정직성).

## Step 4 — gitignore 보장 (★ 항상)

`<cwd>/rehost_exports/.gitignore` 에 `*` 를 써서 **exports 전체를 git 미추적**으로:
```
bash -c 'mkdir -p "<cwd>/rehost_exports"; printf "*\n" > "<cwd>/rehost_exports/.gitignore"'
```
(키트 내부에도 make_export 가 `.gitignore`(bin/ firmware/ *.img) 를 둠.)

## Step 5 — 통지 (★ 생성 위치 안내)

```
== export 완료 ==
생성 위치:  <cwd>/rehost_exports/<firmware>/track<N>/     (git 미추적)
포함:  bin/qemu-system-aarch64 (프리빌트) · firmware/ · machine/ · scripts/ · docs/ · evidence/ · run.sh
바로 실행(받는 사람):  cd <경로> && bash run.sh     (오류 시 bash setup.sh 먼저)
공유:  이 폴더를 zip/복사로 전달 (git 에는 안 올라감).
같은 펌웨어의 다른 트랙:  그 트랙 워크스페이스를 active 로 두고 /rehost-export → track<다른N>/ 에 생성.
```

`journal.sh <WS> session-end "/rehost-export" "키트 -> rehost_exports/<firmware>/track<N>"`.

---

## 정직성

- **미완이면 export 금지** (트랙 1 5/5 미만, 트랙 2 목표 마일스톤 미도달). 완료로 위장 금지.
- docs/evidence 는 실제 JOURNAL/VERIFICATION/콘솔 근거로만. 없는 결과 지어내지 말 것.
- export 폴더는 항상 gitignore (펌웨어 저작권·대용량). 생성 위치를 반드시 사용자에게 안내.
