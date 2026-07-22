#!/usr/bin/env bash
# End-to-end smoke test of the sboot-rehost deterministic layer.
# Substitutes a fake QEMU so the whole run/fingerprint/gate/stop/verify chain
# can be exercised without real firmware.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO/scripts"
export REPO
ROOT="$(mktemp -d)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n'  "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대=$3  실제=$2"; fi; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# --- shims: fake qemu + timeout (macOS lacks GNU timeout) --------------------
BIN="$ROOT/bin"; mkdir -p "$BIN"
if ! command -v timeout >/dev/null 2>&1; then
  cat > "$BIN/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
  chmod +x "$BIN/timeout"
fi
export PATH="$BIN:$PATH"

make_qemu() {   # $1 = console payload file, $2 = trace payload file
  cat > "$BIN/fake-qemu" <<EOF
#!/usr/bin/env bash
OUT=""; LOG=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -serial) OUT="\${2#file:}"; shift 2;;
    -D) LOG="\$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "\$OUT" ] && cat "$1" > "\$OUT"
[ -n "\$LOG" ] && cat "$2" > "\$LOG"
echo "fake-qemu done"
EOF
  chmod +x "$BIN/fake-qemu"
}

new_ws() {      # $1 = name -> echoes workdir
  local wd="$ROOT/$1"; mkdir -p "$wd/06_machine" "$wd/07_logs" "$wd/fw"
  printf '### 우회1\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$wd/06_machine/bypasses.md"
  echo "$wd"
}

export TRACE_DIR="$ROOT/_traces"

# =============================================================================
hdr "1. 트랙 1 — 정상 도달 (셸)"
WD=$(new_ws t1ok)
printf 'static void w(void){ qemu_chr_fe_write_all(s->chr,b,1); }\n' > "$WD/06_machine/machine.c"
printf 'S-BOOT # help\nFollowing commands are supported\n' > "$ROOT/con1.txt"
printf 'no exceptions here\n0x9021f3dc: stp x29,x30\n' > "$ROOT/trc1.txt"
make_qemu "$ROOT/con1.txt" "$ROOT/trc1.txt"
printf 'S-BOOT # \x00Following commands are supported\x00help\x00' > "$WD/bl3.bin"
printf '| shell_func | 0x9021f3dc | prompt xref |\n' > "$WD/STATIC.md"

QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD" 1 sboot-test 1 shell "shell" "$WD/bl3.bin" help > "$ROOT/obs1.json" 2>/dev/null
python3 -c "import json;json.load(open('$ROOT/obs1.json'))" 2>/dev/null && ok "observation.json 이 유효한 JSON" || bad "observation.json 파싱"
M=$(python3 -c "import json;print(json.load(open('$ROOT/obs1.json'))['milestone'])" 2>/dev/null)
chk "마일스톤 shell 도달" "$M" "shell"
I=$(python3 -c "import json;print(json.load(open('$ROOT/obs1.json'))['injected'])" 2>/dev/null)
chk "자가주입 아님" "$I" "False"
ST=$(python3 -c "import json;print(json.load(open('$ROOT/obs1.json'))['stop'])" 2>/dev/null)
chk "정지 아님" "$ST" "False"
RO=$(python3 -c "import json;print(json.load(open('$ROOT/obs1.json'))['run_ok'])" 2>/dev/null)
chk "run_ok 참" "$RO" "True"

# =============================================================================
hdr "2. 트랙 1 — 자가주입 차단 (머신이 문자열을 갖고 있음)"
WD2=$(new_ws t1inj)
printf 'static const char*p="S-BOOT # ";\nqemu_chr_fe_write_all(c,b,1);\n' > "$WD2/06_machine/machine.c"
cp "$WD/bl3.bin" "$WD2/bl3.bin"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD2" 1 sboot-test 1 shell "shell" "$WD2/bl3.bin" help > "$ROOT/obs2.json" 2>/dev/null
M2=$(python3 -c "import json;print(json.load(open('$ROOT/obs2.json'))['milestone'])" 2>/dev/null)
I2=$(python3 -c "import json;print(json.load(open('$ROOT/obs2.json'))['injected'])" 2>/dev/null)
chk "도달로 인정 안 함" "$M2" "none"
chk "자가주입 감지됨" "$I2" "True"

# =============================================================================
hdr "3. 트랙 1 — Data Abort 지문 추출"
WD3=$(new_ws t1fault)
printf 'int x;\n' > "$WD3/06_machine/machine.c"
printf '' > "$ROOT/con3.txt"
printf 'Taking exception 4 [Data Abort]\nFAR 0x12860010\nELR 0xf48343a4\nTaking exception 4 [Data Abort]\n' > "$ROOT/trc3.txt"
make_qemu "$ROOT/con3.txt" "$ROOT/trc3.txt"
cp "$WD/bl3.bin" "$WD3/bl3.bin"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD3" 1 sboot-test 1 shell "shell" "$WD3/bl3.bin" help > "$ROOT/obs3.json" 2>/dev/null
F=$(python3 -c "import json;d=json.load(open('$ROOT/obs3.json'));print(d['far'])" 2>/dev/null)
E=$(python3 -c "import json;d=json.load(open('$ROOT/obs3.json'));print(d['exceptions'])" 2>/dev/null)
chk "FAR 를 16진 문자열로 보존" "$F" "0x12860010"
chk "예외 2 건 계수" "$E" "2"

# =============================================================================
hdr "4. 트랙 2 — 마일스톤 사다리 (가장 높은 것 채택)"
WD4=$(new_ws t2)
printf 'int y;\n' > "$WD4/06_machine/machine_kernel.c"
touch "$WD4/fw/Image.patched"
printf 'Run /init\nscsi host0: ufshcd\nPower mode change(0): M(1)G(3)\n[sda] Attached SCSI disk\n' > "$ROOT/con4.txt"
printf 'kernel trace\n' > "$ROOT/trc4.txt"
make_qemu "$ROOT/con4.txt" "$ROOT/trc4.txt"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD4" 2 test-kernel 1 link_up "userspace,link_up,power_mode,scsi_attach,partitions_up" > "$ROOT/obs4.json" 2>/dev/null
M4=$(python3 -c "import json;print(json.load(open('$ROOT/obs4.json'))['milestone'])" 2>/dev/null)
chk "최고 마일스톤 scsi_attach" "$M4" "scsi_attach"

# 4b. 트랙 2 자가주입 — 낮은 단이 오염되면 높은 단도 인정 금지
WD4B=$(new_ws t2inj)
printf 'qemu_log("Run /init");\n' > "$WD4B/06_machine/machine_kernel.c"
touch "$WD4B/fw/Image.patched"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD4B" 2 test-kernel 1 link_up "userspace,link_up,power_mode,scsi_attach" > "$ROOT/obs4b.json" 2>/dev/null
M4B=$(python3 -c "import json;print(json.load(open('$ROOT/obs4b.json'))['milestone'])" 2>/dev/null)
I4B=$(python3 -c "import json;print(json.load(open('$ROOT/obs4b.json'))['injected'])" 2>/dev/null)
chk "오염 시 상위 단도 불인정" "$M4B" "none"
chk "트랙 2 자가주입 감지"     "$I4B" "True"

# 4c. 사다리가 건너뛴 단 때문에 하위 도달이 가려지지 않아야 한다
#     (K3 사다리에는 rootfs 가 없다. 최고 마일스톤만 보면 userspace 도달이 숨는다)
WD4C=$(new_ws t2skip)
printf 'int q;\n' > "$WD4C/06_machine/machine_kernel.c"
touch "$WD4C/fw/Image.patched"
printf 'Run /init\nerofs: (device dm-0): mounted\n' > "$ROOT/con4c.txt"
printf 'trace\n' > "$ROOT/trc4c.txt"
make_qemu "$ROOT/con4c.txt" "$ROOT/trc4c.txt"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD4C" 2 test-kernel 1 userspace "userspace,link_up,power_mode" > "$ROOT/obs4c.json" 2>/dev/null
TOP=$(python3 -c "import json;print(json.load(open('$ROOT/obs4c.json'))['milestone'])" 2>/dev/null)
LIST=$(python3 -c "import json;print(','.join(json.load(open('$ROOT/obs4c.json'))['milestones_reached']))" 2>/dev/null)
chk "최고 마일스톤은 rootfs" "$TOP" "rootfs"
chk "도달 목록에 userspace 포함" "$LIST" "userspace,rootfs"
# 파이프라인의 사다리 인덱스 계산을 그대로 재현
IDX=$(node -e '
const goals=["userspace","link_up","power_mode"];
const reached=process.argv[1].split(",");
console.log(reached.reduce((b,n)=>Math.max(b,goals.indexOf(n)),-1));
' "$LIST" 2>/dev/null)
chk "사다리 인덱스 0 (userspace 도달 인식)" "$IDX" "0"

# =============================================================================
hdr "5. 한 변경 검문 (check_change)"
WD5=$(new_ws gate)
printf 'int a;\nint b;\n' > "$WD5/06_machine/machine.c"
printf 'int x;\n' > "$WD5/06_machine/other.c"
bash "$S/check_change.sh" "$WD5" snapshot >/dev/null
printf 'int a;\nint b2;\n' > "$WD5/06_machine/machine.c"
if bash "$S/check_change.sh" "$WD5" verify >/dev/null 2>&1; then ok "한 파일 1 hunk + 우회 4항목 통과"; else bad "정상 변경이 거부됨"; fi
printf 'int x2;\n' > "$WD5/06_machine/other.c"
if bash "$S/check_change.sh" "$WD5" verify >/dev/null 2>&1; then bad "두 파일 동시 수정이 통과됨"; else ok "두 파일 동시 수정 거부"; fi
bash "$S/check_change.sh" "$WD5" restore >/dev/null 2>&1
R=$(cat "$WD5/06_machine/other.c")
chk "restore 로 원본 복구" "$R" "int x;"
rm -f "$WD5/06_machine/bypasses.md"
printf 'int a;\nint bX;\n' > "$WD5/06_machine/machine.c"
if bash "$S/check_change.sh" "$WD5" verify >/dev/null 2>&1; then bad "우회 기록 없는데 통과됨"; else ok "우회 기록 누락 거부"; fi

# =============================================================================
hdr "6. 정지 조건 (stop_conditions)"
W6="$ROOT/stopA"; mkdir -p "$W6"
for i in 1 2; do
  python3 "$S/record.py" "$W6" round round=$i goal=link_up fp_exc=1 fp_far=0xA$i fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=3 fixer_no_new_change=false >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W6")
chk "진전 중엔 정지 안 함" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"

W7="$ROOT/stopB"; mkdir -p "$W7"
for i in 1 2 3; do
  python3 "$S/record.py" "$W7" round round=$i goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=2 fixer_no_new_change=false >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "정체 2 → 에스컬레이션 발화" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["escalate_to_analyst"])')" "True"
chk "정체 2 → 아직 정지 아님"   "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"

for i in 4 5; do
  python3 "$S/record.py" "$W7" round round=$i goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=0 fixer_no_new_change=true >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "무브 소진 → EXHAUSTED" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "EXHAUSTED"

W8="$ROOT/stopC"; mkdir -p "$W8"
for i in 1 2 3 4; do
  if [ $((i % 2)) -eq 1 ]; then FF=0xAAA; else FF=0xBBB; fi
  python3 "$S/record.py" "$W8" round round=$i goal=link_up fp_exc=1 fp_far=$FF fp_elr=0x1 fp_milestone=none fp_bytes=9 analyst_new_facts=0 fixer_no_new_change=true >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W8")
chk "진동 A↔B 감지" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["oscillating"])')" "True"

W9="$ROOT/stopD"; mkdir -p "$W9"
python3 "$S/record.py" "$W9" blocker code=BLOCKED_KO detail="벤더 .ko 없음" >/dev/null
J=$(python3 "$S/stop_conditions.py" "$W9")
chk "사실 블로커 → 즉시 정지" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "BLOCKED_KO"

# =============================================================================
hdr "7. 검증 5/5 (verify.py)"
VW=$(new_ws verify)
printf 'Following commands are supported\x00' > "$VW/bl3.bin"
printf 'Following commands are supported\n'   > "$VW/07_logs/console_1.txt"
printf 'qemu_chr_fe_write_all(s->chr,b,1);\n' > "$VW/06_machine/machine.c"
printf '| shell_func | 0x9021f3dc |\n' > "$VW/STATIC.md"
printf '0x9021f3dc: stp\n' > "$VW/07_logs/run_1.log"
V=$(python3 "$S/verify.py" "$VW" --track 1 --bl3 "$VW/bl3.bin" --trace "$VW/07_logs/run_1.log" 2>/dev/null)
chk "정상 → 5/5 REAL" "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])')" "REAL"
printf 'const char*s="Following commands are supported";\nqemu_chr_fe_write_all(c,b,1);\n' > "$VW/06_machine/machine.c"
V=$(python3 "$S/verify.py" "$VW" --track 1 --bl3 "$VW/bl3.bin" --trace "$VW/07_logs/run_1.log" 2>/dev/null)
chk "자가주입 → FORCED" "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])')" "FORCED"

# =============================================================================
hdr "8. 측정 기록 (record.py 타입 보존)"
RW="$ROOT/rec"; mkdir -p "$RW"
python3 "$S/record.py" "$RW" start t1 >/dev/null
python3 "$S/record.py" "$RW" metric phase=Run timer=t1 tokens_total=12345 milestone=none far=0x1234ABCD ok=true >/dev/null
L=$(tail -1 "$RW/metrics.jsonl")
chk "16진은 문자열 유지" "$(echo "$L" | python3 -c 'import json,sys;print(json.load(sys.stdin)["far"])')" "0x1234ABCD"
chk "none 은 문자열 유지"  "$(echo "$L" | python3 -c 'import json,sys;print(json.load(sys.stdin)["milestone"])')" "none"
chk "정수는 정수"          "$(echo "$L" | python3 -c 'import json,sys;print(type(json.load(sys.stdin)["tokens_total"]).__name__)')" "int"
chk "불리언은 불리언"      "$(echo "$L" | python3 -c 'import json,sys;print(type(json.load(sys.stdin)["ok"]).__name__)')" "bool"
chk "elapsed_s 기록됨"     "$(echo "$L" | python3 -c 'import json,sys;print("elapsed_s" in json.load(sys.stdin))')" "True"

# =============================================================================
hdr "9. 기록 파일 생성 확인 (JOURNAL / rounds / observation)"
[ -s "$WD/JOURNAL.md" ]        && ok "JOURNAL.md 생성"        || bad "JOURNAL.md 없음"
[ -s "$WD/observation.json" ]  && ok "observation.json 생성"  || bad "observation.json 없음"
[ -s "$WD/fingerprint.json" ]  && ok "fingerprint.json 생성"  || bad "fingerprint.json 없음"
[ -s "$WD/metrics.jsonl" ]     && ok "metrics.jsonl 생성"     || bad "metrics.jsonl 없음"
grep -q "try #1" "$WD/JOURNAL.md" && ok "JOURNAL 에 회차 시작 기록" || bad "JOURNAL 회차 기록 없음"

# =============================================================================
hdr "10. QEMU 실행 실패 시 정직한 보고"
FW=$(new_ws qfail)
printf 'int z;\n' > "$FW/06_machine/machine.c"
QEMU="/nonexistent/qemu" bash "$S/run_round.sh" "$FW" 1 m 1 shell "shell" "$FW/bl3.bin" help > "$ROOT/obsf.json" 2>/dev/null
RF=$(python3 -c "import json;print(json.load(open('$ROOT/obsf.json'))['run_ok'])" 2>/dev/null)
chk "run_ok=false 로 정직 보고" "$RF" "False"

# =============================================================================
hdr "11. 펌웨어 형상 다양성 (9820 사례 회귀)"

# 11a. ext4 rootfs 를 K2 증거로 인정하는가 (EROFS 만 인정하던 회귀)
EW=$(new_ws ext4); printf 'int y;\n' > "$EW/06_machine/machine_kernel.c"
printf -- '- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$EW/06_machine/bypasses.md"
printf 'Run /init\nEXT4-fs (sda): mounted filesystem\nVFS: Mounted root (ext4 filesystem) readonly\n' > "$EW/07_logs/kboot_1.txt"
V=$(python3 "$S/verify.py" "$EW" --track 2 --target K2 2>/dev/null)
chk "ext4 rootfs 를 K2 로 인정" "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][1]["pass"])')" "True"

# 11b. K3 는 partitions_up 필수 — 중간 마일스톤으로 통과 금지
KW=$(new_ws k3mid); printf 'int y;\n' > "$KW/06_machine/machine_kernel.c"
printf '### b\n- **대상**: t\n- **이유**: r\n- **방법**: m\n- **알려진 부작용**: s\n' > "$KW/06_machine/bypasses.md"
printf 'Run /init\nscsi host0: ufshcd\nPower mode change(0)\n' > "$KW/07_logs/kboot_1.txt"
printf 'UTRD UPIU Query SCSI\n' > "$KW/07_logs/kboot_1.log"
V=$(python3 "$S/verify.py" "$KW" --track 2 --target K3 --trace "$KW/07_logs/kboot_1.log" 2>/dev/null)
chk "K3 중간 마일스톤은 항목2 불통과" "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][1]["pass"])')" "False"
chk "UFS 단계를 미완으로 보고"        "$(echo "$V" | python3 -c 'import json,sys;print("미완" in json.load(sys.stdin)["ufs_controller"]["stage"])')" "True"
chk "마크다운 강조 우회 4항목 인식"    "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][4]["pass"])')" "True"

# 11c. partitions_up 도달 시 K3a 완료
printf 'Run /init\nscsi host0: ufshcd\n[sda] Attached SCSI disk\nsda: sda1 sda2\n' > "$KW/07_logs/kboot_1.txt"
V=$(python3 "$S/verify.py" "$KW" --track 2 --target K3 --trace "$KW/07_logs/kboot_1.log" 2>/dev/null)
chk "partitions_up → K3a 완료" "$(echo "$V" | python3 -c 'import json,sys;print("K3a" in json.load(sys.stdin)["ufs_controller"]["stage"])')" "True"

# 11d. 소스 negative — 주석·#include 는 출력이 아니다
CW=$(new_ws srcneg)
printf '#include "qapi/error.h"\n/* 분석 주석: autoboot 게이트 */\nstatic void f(void){ qemu_chr_fe_write_all(c,b,1); }\n' > "$CW/06_machine/machine.c"
printf 'autoboot error\n' > "$CW/07_logs/console_1.txt"
printf 'x\x00autoboot\x00error\x00' > "$CW/bl3.bin"
printf '| shell_func | 0x1234abcd |\n' > "$CW/STATIC.md"
printf '0x1234abcd: stp\n' > "$CW/07_logs/run_1.log"
V=$(python3 "$S/verify.py" "$CW" --track 1 --bl3 "$CW/bl3.bin" --trace "$CW/07_logs/run_1.log" 2>/dev/null)
chk "주석·#include 는 누출로 안 셈" "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][2]["pass"])')" "True"

# 11e. 0 바이트 initramfs 를 QEMU 에 넘기지 않는가
ZW=$(new_ws zeroinit); : > "$ZW/fw/initramfs.cpio.gz"; touch "$ZW/fw/Image.patched"
printf 'int z;\n' > "$ZW/06_machine/machine_kernel.c"
printf 'boot\n' > "$ROOT/conz.txt"; printf 'trace\n' > "$ROOT/trcz.txt"; make_qemu "$ROOT/conz.txt" "$ROOT/trcz.txt"
cat > "$BIN/fake-qemu-args" <<'EOF'
#!/usr/bin/env bash
echo "$@" > /tmp/qemu_args_seen.txt
OUT=""; LOG=""
while [ $# -gt 0 ]; do case "$1" in -serial) OUT="${2#file:}"; shift 2;; -D) LOG="$2"; shift 2;; *) shift;; esac; done
[ -n "$OUT" ] && echo boot > "$OUT"; [ -n "$LOG" ] && echo trace > "$LOG"
EOF
chmod +x "$BIN/fake-qemu-args"
QEMU="$BIN/fake-qemu-args" bash "$S/run_kernel.sh" "$ZW" test-kernel 1 >/dev/null 2>&1
if grep -q '\-initrd' /tmp/qemu_args_seen.txt 2>/dev/null; then bad "0 바이트 initramfs 가 QEMU 로 전달됨"; else ok "0 바이트 initramfs 는 전달 안 함"; fi
rm -f /tmp/qemu_args_seen.txt

# =============================================================================
hdr "12. 벤더 다양성 — MediaTek (LK / MT6833 사례 회귀)"

# 12a. carve_check 가 아키텍처별 기준을 쓰는가 (LK 는 1.5MB, S-Boot 기준이면 오탐)
REPO="$REPO" python3 - > /tmp/carve_res.txt <<'PY'
import sys, types, os, io, contextlib
sys.modules.setdefault('capstone', types.SimpleNamespace(
    Cs=None, CS_ARCH_ARM64=0, CS_ARCH_ARM=0, CS_MODE_ARM=0, CS_MODE_THUMB=0))
sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts"))
import carve_disasm as cd
blob = bytearray(b"\x00" * (1500 * 1024))
blob[100:108] = b"fastboot"; blob[200:209] = b"preloader"
open("/tmp/lk_t.bin","wb").write(bytes(blob))
def full(a):
    cd.ARCH = a; b = io.StringIO()
    with contextlib.redirect_stdout(b): cd.carve_check("/tmp/lk_t.bin")
    return "is_full: True" in b.getvalue()
print(full("arm64")); print(full("arm32")); os.remove("/tmp/lk_t.bin")
PY
chk "LK 를 arm64 기준으로 보면 carve 오탐" "$(sed -n 1p /tmp/carve_res.txt)" "False"
chk "LK 를 arm32 기준으로 보면 full"       "$(sed -n 2p /tmp/carve_res.txt)" "True"
rm -f /tmp/carve_res.txt

# 12b. fastboot 표면의 마일스톤을 run_qemu 가 인식하는가
FW=$(new_ws mtk_fb); printf 'int q;\n' > "$FW/06_machine/machine.c"
printf 'fastboot_init()\nfastboot: processing commands\n[fastboot: command buf]-[getvar:version]\n' > "$ROOT/confb.txt"
printf 'no exceptions\n' > "$ROOT/trcfb.txt"; make_qemu "$ROOT/confb.txt" "$ROOT/trcfb.txt"
printf 'x' > "$FW/lk.bin"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$FW" 1 mtk-bootloader 1 fastboot "fastboot" "$FW/lk.bin" help fastboot > "$ROOT/obsfb.json" 2>/dev/null
chk "fastboot 표면 마일스톤 인식" "$(python3 -c "import json;print(json.load(open('$ROOT/obsfb.json'))['milestone'])" 2>/dev/null)" "fastboot"

# 12c. fastboot 표면에서 머신이 입력 명령을 지어내면 항목4 불통과
VW=$(new_ws mtk_v); printf 'x\x00fastboot: processing commands\x00' > "$VW/lk.bin"
printf 'fastboot: processing commands\n' > "$VW/07_logs/console_1.txt"
printf 'const char *c = "getvar:version";\n' > "$VW/06_machine/machine.c"
printf -- '- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$VW/06_machine/bypasses.md"
printf '| shell_func | 0xdeadbeef |\n' > "$VW/STATIC.md"; printf '0xdeadbeef: x\n' > "$VW/07_logs/run_1.log"
V=$(python3 "$S/verify.py" "$VW" --track 1 --surface fastboot --bl3 "$VW/lk.bin" --trace "$VW/07_logs/run_1.log" 2>/dev/null)
chk "머신이 입력 명령을 지어내면 불통과" "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][3]["pass"])')" "False"
printf 'static void f(void){}\n' > "$VW/06_machine/machine.c"
V=$(python3 "$S/verify.py" "$VW" --track 1 --surface fastboot --bl3 "$VW/lk.bin" --trace "$VW/07_logs/run_1.log" 2>/dev/null)
chk "외부 입력이면 항목4 통과"           "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][3]["pass"])')" "True"


# 12d. 등급이 실제로 사다리를 바꾸는가 (A/B/C)
GW=$(new_ws grades); printf 'int g;\n' > "$GW/06_machine/machine.c"
printf 'S-BOOT # help\nFollowing commands\nreset: OK\nautoboot aborted..\n' > "$ROOT/cong.txt"
printf 'trace\n' > "$ROOT/trcg.txt"; make_qemu "$ROOT/cong.txt" "$ROOT/trcg.txt"
printf 'shell\tFollowing commands\ncommands\treset: OK\nautoboot\tautoboot aborted\n' > "$GW/milestone_tokens.txt"
printf 'x' > "$GW/bl.bin"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$GW" 1 bl-test 1 shell "shell,commands,autoboot" "$GW/bl.bin" help shell > "$ROOT/obsg.json" 2>/dev/null
LISTG=$(python3 -c "import json;print(','.join(json.load(open('$ROOT/obsg.json'))['milestones_reached']))" 2>/dev/null)
TOPG=$(python3 -c "import json;print(json.load(open('$ROOT/obsg.json'))['milestone'])" 2>/dev/null)
chk "등급 단(commands·autoboot) 관측" "$LISTG" "shell,commands,autoboot"
chk "최고 단은 autoboot"              "$TOPG"  "autoboot"

printf '\n\033[1m════════ 결과: %d 통과 / %d 실패 ════════\033[0m\n' "$PASS" "$FAIL"
echo "작업 폴더: $ROOT"
[ "$FAIL" -eq 0 ]
