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

## Step 0 — 옛 버전을 먼저 없앤다 (건너뛰지 않는다)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/purge_cache.sh"
```

캐시는 버전마다 폴더가 남는다. 옛 폴더가 있으면 어떤 경로로든 옛 스킬·에이전트·
스크립트가 다시 로드될 수 있고, 그러면 회차·로그·판정이 전부 옛 규칙을 따른다.
이 저장소에서 실제로 `0.2.0` 과 `0.17.0` 이 남아 있었고 세션은 `0.17.0` 을 로드하고
있었다 — 저장소가 `0.24.0` 인데도.

이 명령은 **최신 하나만 남기고 전부 지우고**, `__pycache__` 도 지운다.

| 종료코드 | 뜻 | 할 일 |
|---|---|---|
| `0` | 최신으로 정리됨 | Step 1 로 진행 |
| **`1`** | **세션이 옛 버전을 로드 중** | **여기서 정지.** 아래 안내 후 종료 |
| `2` | 판정 불가 (개발 체크아웃 등) | 사실을 밝히고 진행 |

> **이미 로드된 것은 캐시를 지워도 바뀌지 않는다.** 세션은 시작 시점의 사본을 계속
> 쓴다. 그래서 종료코드 1 이면 **반드시 여기서 멈춘다** — 정리했다고 보고하면서
> 옛 코드로 계속 도는 것이 가장 나쁘다. 지운 것이 지금 세션이 쓰던 버전이면 재시작
> 전까지 명령이 동작하지 않을 수 있다는 점도 함께 알린다.

```
== 옛 버전을 지웠습니다 — 재시작이 필요합니다 ==
| 지운 버전 | 0.2.0, 0.17.0 |
| 남긴 버전 | 0.24.0 |
| 이 세션   | 0.17.0 을 로드 중 (지워짐) |

  /plugin marketplace update sboot-rehost-marketplace
  /plugin install sboot-rehost@sboot-rehost-marketplace
  → Claude Code 재시작 후 /sboot-rehost:init 을 다시 부르세요
```

이어서 버전 게이트를 확인한다.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check_version.sh"
```

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
- **옛 캐시 삭제를 보고만 하고 넘어가지 않는다.** 종료코드 1 이면 멈춘다.
- **이 명령은 워크스페이스도 `INPUT.md` 도 만들지 않는다.** 그건 펌웨어를 받은
  `start` 의 일이다. 펌웨어 없이 만들면 무엇을 대상으로 하는지 없는 껍데기가 남는다.
