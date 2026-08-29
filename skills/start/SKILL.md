---
name: start
description: sboot-rehost 의 유일한 실행 명령. 환경 준비 · 펌웨어 인식 · 워크스페이스 생성 · 정적 도출 · 매체 합성 · 머신 빌드 · 회차 루프 · 검증 · 재현 키트까지 한 번에 자율 진행한다. 처음 부르면 작업 폴더를 만들고 _inbox/ 에 펌웨어를 넣으라고 안내한 뒤 종료하며, 펌웨어가 있으면 그때부터 끝까지 간다. 목표 등급은 인자로만 받고 기본값은 F2 (커널 진입). 구 명령 rehost-init · rehost-setup · rehost-full 을 대체한다.
disable-model-invocation: true
---

당신은 **sboot-rehost 실행** 오케스트레이터. 사용자가 치는 명령은 이것 하나다.

```
/sboot-rehost:start [F1|F2|F3]
```

**질문하지 않는다.** `AskUserQuestion` 을 호출하지 않으며, 모든 분기는 자동 결정하고
`journal.sh decision` 으로 남긴다. 등급을 생략하면 **F2**.

---

## 한 문장

> **한 머신, 한 진입점, 나머지는 게스트 안에서.**

QEMU 는 부트로더 컨테이너만 올리고 리셋 PC 를 **첫 실행 가능 스테이지**에 둔다.
그다음 스테이지도, 커널도, DTB 도 **펌웨어 자신의 코드가** 매체에서 읽어 적재한다.

```
[컨테이너 한 번 적재]
   stage0 ──▶ stage1 ──▶ … ──▶ 부트로더 ──▶ 커널 ──▶ rootfs
     ▲          ▲                  │
     │          └ 암호화 스테이지는 건너뛰고 다음 실행 가능 스테이지로 재지정
     └ 리셋 PC (도출값)
```

**하지 않는 것**: `-kernel Image` · `-dtb` · `-initrd` 를 주지 않는다. 떠먹이면 커널만
올린 기존 연구와 구별되지 않는다. 이미지 carve 도 하지 않는다 — 머신 init 이 컨테이너
하나를 열어 스테이지별 VA 로 `memcpy` 한다.

---

## 상태를 보고 스스로 다음을 정한다

이 명령은 **어디서 불려도 같은 답을 낸다.** 현재 상태를 보고 할 일을 고른다.

| 상태 | 할 일 |
|---|---|
| 작업 폴더 없음 | 만들고 다음 칸으로 |
| 의존성 없음 | `setup_env.sh` 를 **백그라운드**로 돌리고 진행. 필요한 시점에 대기 |
| `_inbox/` 비어 있음 | **안내 후 종료** (아래 Step 1) |
| `_inbox/` 에 펌웨어 있고 워크스페이스 없음 | 워크스페이스 생성 → 끝까지 진행 |
| 워크스페이스가 이미 있음 | **이어서 진행** (재개). 덮어쓰지 않는다 |

---

## Step 0 — 게이트

1. **버전**: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check_version.sh` — 세션이 로드한
   플러그인이 최신이 아니면 `BLOCKED_VERSION` 으로 **정지**하고 갱신·재시작을 안내한다.
   옛 버전으로 돌면 회차·로그·판정이 모두 옛 규칙을 따른다.
2. **환경**: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check_env.sh` — QEMU·ninja·capstone·
   `lz4`·`simg2img`. 없으면 `setup_env.sh` 를 백그라운드로 돌리고 진짜 PID 를 보고한다.
3. **작업 루트**: `WORKROOT = <cwd>/rehost_workspaces`, 그 안에 `_inbox/`.
   이미 있으면 덮어쓰지 않는다.

## Step 1 — 펌웨어가 없으면 여기서 끝

`_inbox/` 가 비어 있으면 폴더만 만들고 **안내 후 종료**한다. 이것이 옛 `rehost-init`
자리다. 다음에 다시 `start` 를 부르면 그때부터 이어서 간다.

```
== 준비 완료 ==
| 드롭 폴더 | <cwd>/rehost_workspaces/_inbox/  ← 여기에 펌웨어를 넣으세요 |
| 의존성    | OK / 백그라운드 설치 중 (PID <pid>) |

넣을 것: .zip 또는 BL_*.tar.md5 + AP_*.tar.md5
넣은 뒤: /sboot-rehost:start        (등급을 바꾸려면 /sboot-rehost:start F1)
```

## Step 2 — 펌웨어 인식과 워크스페이스

- `_inbox/` 스캔. 여러 개면 가장 최근(mtime) 을 쓰고 **어느 것을 썼는지 보고**한다.
- 워크스페이스 이름은 펌웨어에서 `<model>_<build>` 로 도출한다. 이미 있으면 재개.
- 폴더: `01_firmware 02_unpacked 03_bootloader 04_static-analysis 06_machine 07_logs 08_docs fw`
- `journal.sh <WS> session-start "/sboot-rehost:start" "<등급>"`
- **사용자 입력 원문을 기록한다** — `invoked_with` 로 파이프라인에 넘기면
  `prompts.jsonl` 과 `JOURNAL.md` 에 원문이 남는다. 요약하지 않는다.
- **`PROGRESS.md` 머리말을 만든다** — `templates/PROGRESS.md.tmpl` 의 placeholder를
  채워 워크스페이스에 쓴다. 회차 루프는 여기에 한 줄씩 **추가만** 하므로, 머리말이
  없으면 나중에 그 이력이 어느 펌웨어·어느 등급의 것인지 알 수 없다.

**SoC 계열은 추측하지 말고 매직으로 판별한다.** 결과는 탐색 힌트(`profiles/`)를 고르는
데만 쓰이고, 값 자체는 static-analyzer 가 대상에서 도출한다.

| 관찰 | 판정 |
|---|---|
| `sboot.bin` + `S-BOOT`/`Following commands` | `exynos` / S-Boot |
| `lk.bin` · MTK 헤더 매직 `0x58881688` · `preloader_*` | `mediatek` / LK |
| `aboot` · `emmc_appsboot.mbn` | `qualcomm` / aboot |
| 위 어디에도 안 맞음 | `generic` |

## Step 3 — 언팩

`tar.md5` → `lz4` 해제 → **sparse 이미지는 raw 로 푼다.**
매직 `0xed26ff3a` 를 검사해 `simg2img` 를 돌리고, 도구가 없으면 **정지**한다.
raw 로 착각해 그대로 복사하면 파일구조가 깨지고, 그 결함은 한참 뒤 AVB 실패로 나타난다.

## Step 4 — 파이프라인 호출

```
pipeline.js({
  workdir, model, target: 'F1'|'F2'|'F3',
  bootloader_path, soc_family, arch, bl_surface, has_super,
  invoked_with,             // 사용자 입력 원문 — 요약하지 말고 그대로
  plugin_dir: '${CLAUDE_PLUGIN_ROOT}',
})
```

파이프라인이 **정적 도출 → 매체 합성 → 머신 생성 → ninja → 회차 루프 → 검증 →
재현 키트**를 끝까지 자율 진행한다. 중간에 멈추지 않는다.

---

## 등급 — 목표 단계는 도출값이다

스테이지 수는 펌웨어마다 다르므로 고정하지 않는다. `stage_map.json` 이 실행 가능
스테이지를 세고, 그만큼 칸이 생긴 뒤 공통 후단이 붙는다.

| 등급 | 목표 | 뜻 |
|---|---|---|
| **F1** | 스테이지 진입 × N + `<표면>` | 부트로더 체인이 진짜로 돈다 |
| **F2** (기본) | F1 + `medium_up` · `partitions` · `verify_ok` · `kernel_entry` · **`kernel_alive`** | **커널이 실제로 실행됨** |
| **F3** | F2 + `userspace` · `partitions_up` (+ `super_mounted`) | rootfs 완주 |

**`kernel_entry` 와 `kernel_alive` 는 다르다.** 앞은 부트로더가 `Starting kernel...` 을
찍은 것이고, 뒤는 커널이 자기 배너(`Linux version`)를 찍은 것이다. **부트로더의 점프
선언만으로 도달로 세지 않는다.**

**F1 은 매체 모델 없이 도달 가능하다.** 첫 스테이지는 핸드오프 슬롯으로 블록을 읽으므로
스토리지 모델이 아직 없어도 걸어간다.

### 커널이 조용하면 커맨드라인부터 본다

부트로더가 기본으로 `console=ram` 을 고르면 **커널이 완벽히 떠도 시리얼에 한 줄도 안
나온다.** 이때 침묵은 실패의 증거가 아니다. static-analyzer 가 `cmdline_plan.json` 에
후보를 도출하고, `build_lu.py` 가 **PARAM 파티션에 UART 조합을 기록**한다.
이건 우회가 아니라 부트로더의 정상 경로(`setup_param_info` → `sbl_set_bootargs`)다.

---

## 정지 조건

| 코드 | 조건 |
|---|---|
| `BLOCKED_VERSION` | 세션이 로드한 플러그인이 최신이 아님 (첫 게이트) |
| `BLOCKED_ENV` | 실행 환경 미비 |
| `BLOCKED_ARCH` | 그 아키텍처의 진입 스텁 시그니처가 아직 없음 (현재 arm32) |
| `BLOCKED_CARVE` | 컨테이너가 부분 추출 |
| `BLOCKED_NO_INPUT_PATH` | 어느 표면에도 입력 경로가 없음 |
| `BLOCKED_ASSET` | F2 이상인데 커널 자산 없음 (F1 로 낮추면 진행 가능) |
| `BLOCKED_TEE` | 시큐어월드 — 설계상 범위 밖 |
| `EXHAUSTED` | 시도 소진. **회차 수와 소요 시간은 정지 사유가 아니다** |

정지하면 **`RESUME.md`** 가 자동 생성된다 — 어디까지 갔나, 무엇을 시도했고 각각이 지문을
움직였나, 아직 안 써본 수단, 재개 명령. **정지는 포기가 아니라 인계이며 재개 가능하다.**

---

## 검증 — 게이트 3항

판정을 막는 것은 셋뿐이다. 목적은 하나 — **머신이나 에이전트가 만들어 낸 콘솔이 진짜
부팅으로 읽히지 않게 하는 것.**

| # | 게이트 | 무엇을 막는가 |
|---|---|---|
| 1 | 소스 negative | 머신이 출력하는 문자열이 콘솔에 나타나면 실패 |
| 2 | 출력 출처 | 콘솔의 **고정 문자열**이 펌웨어 이미지 안에 있어야 한다 |
| 3 | 입력 출처 | 머신이 자기 수신 버퍼를 채우면 실패 |

체인 PC 트레이스 · 검증 양방향 · 스토리지 이중 구동 · 우회 기록은 **측정해서 보고만**
하고 도달을 막지 않는다.

판정: **`VERIFIED`(출처 검증 통과)** / **`UNVERIFIED`(출처 검증 실패)**.

### 그래도 지키는 것

- **추측 스텁 금지** — 특히 적응형 토글(N회 읽은 뒤 값 변경). 펌웨어를 잘못된 분기로
  보내고 다른 펌웨어에서 재현되지 않는다.
- **우회는 우회로 표기** — `06_machine/bypasses.md` 에 대상·이유·방법·**부작용**.
  부작용 항목은 이후 실행이 정체될 때 가장 먼저 참조된다.
- **도달하지 못한 지점은 그렇게 기록**한다.
- **검증 결과 자체는 위조하지 않는다** — 상태 워드는 바꿔도 반환값과 실패 출력은 둔다.

---

## 구 명령

`rehost-init` · `rehost-setup` · `rehost-full` 을 **대체**하고 그 셋은 삭제됐다. 나뉘어 있던
이유는 폴더 생성과 펌웨어 인식과 실행이 각각 사용자 결정을 요구했기 때문인데, 지금은
전부 상태에서 도출되므로 가를 이유가 없다.

남는 명령: **`start`**(실행) · **`status`**(조회) · **`export`**(키트 재생성).
