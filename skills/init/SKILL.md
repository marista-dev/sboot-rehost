---
name: init
description: 설치 후 1회 실행하는 환경 구축 명령. QEMU 10.2.2 빌드와 의존성(capstone·ninja·dtc·lz4·simg2img)을 설치하고, 작업 루트 rehost_workspaces/ 와 펌웨어 드롭 폴더 _inbox/ 를 만든다. QEMU 빌드가 약 18 분 걸리므로 실행 명령과 분리돼 있다. 끝나면 사용자가 _inbox/ 에 펌웨어를 넣고 /sboot-rehost:start 를 부른다.
disable-model-invocation: true
---

당신은 **환경 구축** 오케스트레이터. 이 명령은 **한 번만** 부르면 된다.

```
/sboot-rehost:init
```

## 왜 실행 명령과 분리돼 있나

QEMU 10.2.2 빌드가 **약 18 분** 걸린다. 이걸 `start` 안에 넣으면 리호스팅을 시작한
줄 알았던 사용자가 20 분을 기다리게 되고, 그동안 무엇이 진행 중인지도 흐려진다.
환경은 한 번 만들면 펌웨어가 몇 개든 재사용되므로 분리하는 편이 맞다.

**두 번째 펌웨어부터는 부를 필요가 없다.** 이미 있으면 검사만 하고 끝난다.

---

## Step 0 — 버전 게이트

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check_version.sh"
```

세션이 로드한 플러그인이 최신이 아니면 **정지**하고 갱신·재시작을 안내한다.
옛 버전으로 환경을 만들면 이후 실행이 옛 규칙을 따른다.

## Step 1 — 작업 폴더 (이 명령의 핵심)

```bash
mkdir -p <cwd>/rehost_workspaces/_inbox
cp "${CLAUDE_PLUGIN_ROOT}/scripts/inbox_readme.txt" \
   <cwd>/rehost_workspaces/_inbox/DROP_FIRMWARE_HERE.txt
```

- 작업 루트는 **현재 폴더(cwd) 밑**이다. 경로를 지어내지 않는다.
- **이미 있으면 덮어쓰지 않는다.** 다른 펌웨어의 작업물이 들어 있을 수 있다.
- 전부 `.gitignore` 대상이므로 플러그인 저장소 안에서 실행해도 git 에 섞이지 않는다.

## Step 2 — 의존성

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check_env.sh"
```

| 결과 | 할 일 |
|---|---|
| `ok: true` | "환경 OK" 보고하고 끝 |
| 문제 있음 | `setup_env.sh` 를 **백그라운드**로 실행하고 **진짜 PID** 를 보고 |

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup_env.sh" > /tmp/sboot_setup.log 2>&1 &
echo "PID $!"
```

설치되는 것:

| 도구 | 쓰임 |
|---|---|
| `qemu-system-aarch64` 10.2.2 | 머신 실행 |
| `ninja` · `meson` | 머신 재빌드 (회차마다) |
| `capstone` | 디스어셈블 — 주소·구조 도출 |
| `dtc` / `fdtdump` | DTB 파싱 (F2 이상) |
| `lz4` | BL 패키지의 `.lz4` 해제 |
| `simg2img` | AP 의 sparse 이미지를 raw 로 (F2 이상) |

셸이 Windows 면 `wsl_bridge.sh` 가 WSL 로 전환한다. 대용량 쓰기는 WSL ext4 에 둔다.

## Step 3 — 완료 보고

```
== 환경 준비 완료 ==
| 작업 루트 | <cwd>/rehost_workspaces/ |
| 드롭 폴더 | <cwd>/rehost_workspaces/_inbox/  ← 여기에 펌웨어를 넣으세요 |
| 의존성    | OK  (또는: 백그라운드 설치 중 — PID <pid>, 약 18분) |

다음:
  1) 펌웨어(.zip / BL_*.tar.md5 / AP_*.tar.md5)를 _inbox/ 에 넣으세요
  2) /sboot-rehost:start          (목표 등급 기본 F2)
```

설치가 백그라운드로 도는 중이면 **그 사실을 명시**한다. `start` 는 환경이 준비되지
않았으면 `BLOCKED_ENV` 로 정지하므로, 설치가 끝난 뒤 부르면 된다.

---

## 정직성

- **폴더는 실제 cwd 밑에 만든다.** 만들었다고 보고한 경로는 실제로 존재해야 한다.
- **PID 는 진짜 PID 다.** 백그라운드로 돌렸다고만 말하고 붙이지 않으면 사용자가
  진행 여부를 확인할 수 없다.
- **이 명령은 워크스페이스도 `INPUT.md` 도 만들지 않는다.** 그건 펌웨어를 받은
  `start` 의 일이다. 펌웨어 없이 만들면 무엇을 대상으로 하는지 없는 껍데기가 남는다.
