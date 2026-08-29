# 05. 설치와 버전 확인

> **읽고 나면**: 이 플러그인이 제대로 로드됐는지, 지금 세션이 어느 버전을 쓰는지 확인할 수
> 있고, 버전이 어긋났을 때 무엇을 해야 하는지 알 수 있다.

---

## 1. 정체

| 항목 | 값 | 출처 |
|---|---|---|
| 플러그인 이름 | `sboot-rehost` | `.claude-plugin/plugin.json` |
| 마켓플레이스 | `sboot-rehost-marketplace` | `.claude-plugin/marketplace.json` |
| 저장소 버전 | `0.22.0` | `plugin.json` |
| 명령 접두사 | `/sboot-rehost:` | 플러그인 이름에서 파생 |

---

## 2. 가장 먼저 확인할 것 — 세션이 쓰는 버전

**Claude Code 세션은 시작 시점에 로드한 플러그인 버전을 계속 쓴다.** 저장소나 캐시를 최신으로
갱신해도 이미 실행 중인 세션이 쓰는 것은 **로드 시점의 버전**이다.

이것이 위험한 이유는 실패가 눈에 띄지 않기 때문이다. 루프는 돌고 로그는 정상으로 보이는데
동작은 이전 릴리스의 것이다. 결과적으로 두 버전 전에 고쳐진 문제를 다시 디버깅하게 된다.

### 파이프라인이 먼저 막는다

`/sboot-rehost:start` 는 다른 무엇보다 먼저 버전을 확인하고, 어긋나면 `BLOCKED_VERSION`
으로 **정지한다.** 경고하고 진행하지 않는다.

```bash
bash scripts/check_version.sh "$PLUGIN_DIR"
```

세 값을 비교한다.

| 값 | 뜻 |
|---|---|
| `running` | 지금 실행되는 스크립트가 속한 버전 |
| `registered` | **세션이 실제로 로드한 버전** (스킬·에이전트의 출처) |
| `available` | 이 컴퓨터에 있는 최신 버전 |

`registered` 가 `available` 보다 낮으면 스킬과 에이전트가 이전 세대의 것이다.
`running` 과 `registered` 가 다르면 스크립트와 프롬프트가 서로 다른 세대일 수 있다.

판정이 불가능한 경우(작업 사본 실행, 캐시 없음)는 **막지 않고 사유를 기록한다.**
판별 불가에 정지를 걸면 개발 중인 체크아웃에서 도구 자체가 실행되지 않는다.

### 수동 확인

```bash
# 세션이 로드한 버전
python3 -c "
import json,os
d=json.load(open(os.path.expanduser('~/.claude/plugins/installed_plugins.json')))
for k,v in d['plugins'].items():
    if 'sboot' in k:
        for e in v: print(e['version'], e['scope'], e['installPath'])"

# 이 컴퓨터에 있는 버전들
ls ~/.claude/plugins/cache/sboot-rehost-marketplace/sboot-rehost/
```

---

## 3. 어긋났을 때

```
/plugin marketplace update sboot-rehost-marketplace    # 카탈로그 갱신
/plugin install sboot-rehost@sboot-rehost-marketplace  # 등록을 최신으로
/reload-plugins                                        # 재시작 없이 적용
        ↓ 그래도 안 되면
Claude Code 재시작
        ↓ 그래도 안 되면
rm -rf ~/.claude/plugins/cache                         # 캐시 삭제 후 재설치
```

VS Code 확장이면 `/plugins` → Marketplaces 탭 → 해당 마켓플레이스 새로고침 → 재시작.

### 최신인지 판별하는 가장 빠른 방법

명령 목록에 **`/sboot-rehost:start`** 가 보이면 최신이다.

| 보이는 것 | 버전 |
|---|---|
| `start` | v0.21.0 이상 |
| `rehost-full` 은 있으나 `start` 가 없음 | v0.19.0 ~ v0.20.x |
| `rehost-bootloader` · `rehost-kernel` 만 있음 | v0.19.0 이전 (트랙 시대) |

---

## 4. 설치

```
/plugin marketplace add hyu-sslab/sboot-rehost
/plugin install sboot-rehost@sboot-rehost-marketplace
```

---

## 5. 구성 요소 확인

```bash
V=0.22.0
R=~/.claude/plugins/cache/sboot-rehost-marketplace/sboot-rehost/$V
ls $R/skills/    # start status export  (셋뿐이어야 한다)
ls $R/agents/    # static-analyzer supervisor fault-classifier fixer-* verifier
ls $R/scripts/   # check_version.sh stage_map.py build_lu.py run_full.sh ...
```

| 있어야 하는 것 | 없으면 |
|---|---|
| `skills/start/` | v0.21.0 이전 |
| `scripts/check_version.sh` · `stage_map.py` · `build_lu.py` | v0.19.0 이전 |
| `agents/fixer-secureboot.md` | v0.19.0 이전 |
| `knowledge/faults_unified.md` | v0.19.0 이전 |

---

## 6. 실행 환경

`check_env.sh` 가 루프 전에 확인한다. 하나라도 없으면 `BLOCKED_ENV` 로 정지한다.

| 항목 | 용도 |
|---|---|
| QEMU (aarch64) | 실행 |
| ninja | 머신 재빌드 |
| python3 + capstone | 정적 도출 |
| dtc 또는 fdtdump | DTB 파싱 (F2 이상) |
| WSL | 셸이 Windows 인 경우 |
