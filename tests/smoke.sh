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

# Dryness is judged over a window, so two dry rounds are not yet exhaustion.
for i in 4 5; do
  python3 "$S/record.py" "$W7" round round=$i goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=0 fixer_no_new_change=true >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "dry 2회차는 아직 소진 아님" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"

python3 "$S/record.py" "$W7" round round=6 goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=0 fixer_no_new_change=true >/dev/null
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "무브 소진 → EXHAUSTED" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "EXHAUSTED"

# 회귀 가드: 마지막 한 회차의 반짝임이 창 전체를 지우면 안 된다 (66회차 런어웨이)
python3 "$S/record.py" "$W7" round round=7 goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=1 fixer_no_new_change=false >/dev/null
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "마지막 회차 새 사실 1 → 소진 해제" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"
for i in 8 9 10; do
  python3 "$S/record.py" "$W7" round round=$i goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=0 fixer_no_new_change=true >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "다시 창이 차면 EXHAUSTED" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "EXHAUSTED"

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

# 13. Windows → WSL 브리지 (wsl_bridge.sh)
printf '\n\033[1m== 13. Windows → WSL 브리지 ==\033[0m\n'

# 경로 변환 단위 검증
sed -n '/^__to_wsl() {/,/^}/p' "$S/wsl_bridge.sh" > "$ROOT/to_wsl.sh"
tw() { echo "$(. "$ROOT/to_wsl.sh"; __to_wsl "$1")"; }
chk "Windows 백슬래시 경로 변환" "$(tw 'C:\Users\mawj0\x.sh')" "/mnt/c/Users/mawj0/x.sh"
chk "Git Bash 드라이브 경로 변환" "$(tw '/c/Users/mawj0/ws')"      "/mnt/c/Users/mawj0/ws"
chk "이미 Linux 경로면 그대로"    "$(tw '/home/marista/rehost')"   "/home/marista/rehost"
chk "경로 아닌 인자는 그대로"    "$(tw 'code=BLOCKED_ENV')"       "code=BLOCKED_ENV"

# 가짜 Git Bash + 가짜 wsl.exe 로 end-to-end
WB="$ROOT/winbin"; mkdir -p "$WB"
printf '#!/usr/bin/env bash\necho "MINGW64_NT-10.0-22631"\n' > "$WB/uname"; chmod +x "$WB/uname"
cat > "$WB/wsl.exe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ROOT/argv.txt"
a=(); for x in "\$@"; do a+=( "\${x/#\/mnt\/c\//$ROOT/c/}" ); done
set -- "\${a[@]}"; [ "\$1" = "-e" ] && shift
PATH="/usr/bin:/bin" exec "\$@"
EOF
chmod +x "$WB/wsl.exe"
mkdir -p "$ROOT/c/plug" "$ROOT/c/My Work/ws"; cp -R "$S" "$ROOT/c/plug/scripts"

PATH="$WB:$PATH" bash "$ROOT/c/plug/scripts/journal.sh" 'C:/My Work/ws' note "브리지" >/dev/null 2>&1
chk "Git Bash 면 wsl.exe 로 건너간다" "$(head -1 "$ROOT/argv.txt")" "-e"
chk "공백 있는 경로가 한 인자로 보존" "$(grep -c '^/mnt/c/My Work/ws$' "$ROOT/argv.txt")" "1"
chk "건너간 뒤 실제로 파일을 쓴다"    "$([ -f "$ROOT/c/My Work/ws/JOURNAL.md" ] && echo yes)" "yes"

PATH="$WB:$PATH" bash "$ROOT/c/plug/scripts/py.sh" record.py 'C:/My Work/ws' blocker code=T detail=d >/dev/null 2>&1
chk "python 도 브리지를 탄다" "$([ -s "$ROOT/c/My Work/ws/blockers.jsonl" ] && echo yes)" "yes"

# wsl.exe 가 없으면 정직하게 실패해야 한다
NB="$ROOT/nowsl"; mkdir -p "$NB"; cp "$WB/uname" "$NB/"
PATH="$NB:/usr/bin:/bin" bash "$ROOT/c/plug/scripts/journal.sh" 'C:/x' note y >/dev/null 2>&1
chk "wsl.exe 없으면 EX_CONFIG(78)" "$?" "78"
JN=$(PATH="$NB:/usr/bin:/bin" bash "$ROOT/c/plug/scripts/check_env.sh" 'C:/x' 1 2>/dev/null)
chk "그래도 check_env 는 JSON 을 낸다" \
    "$(echo "$JN" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')" "False"

# Linux 에서는 가드가 무동작
JL=$(bash "$S/check_env.sh" "$(new_ws bridge)" 1 2>/dev/null)
chk "Linux/macOS 에서는 가드 무동작" \
    "$(echo "$JL" | python3 -c 'import json,sys;print(json.load(sys.stdin)["os"] in ("Linux","Darwin"))')" "True"


# 14. 도출 결과 배선 (derived_facts.py) — 찾은 것이 실제로 쓰이는가
printf '\n\033[1m== 14. 도출 결과 배선 ==\033[0m\n'
DW=$(new_ws derived)
cat > "$DW/STATIC.md" <<'EOF'
# 정적 도출

## 도출된 정지점

| 시그니처 | 관측 | 메커니즘 (근거) | 담당 fixer | 시도할 변경 |
|---|---|---|---|---|
| `entry_vector_refault` | FAR==ELR=0x620 | VBAR 미설정 (capstone 근거) | `fixer-bootflow` | 진입 PC 수정 |
EOF
D1=$(python3 "$S/derived_facts.py" "$DW" --track 1)
chk "도출한 정지점을 읽는다"     "$(echo "$D1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["new"])')" "1"
chk "담당 fixer 를 뽑아낸다"     "$(echo "$D1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_points"][0]["fixer"])')" "fixer-bootflow"

# 같은 정지점을 또 도출해도 '새 사실' 이 늘면 안 된다 (자기신고 대체의 핵심)
D2=$(python3 "$S/derived_facts.py" "$DW" --track 1)
chk "같은 정지점 재도출은 new=0" "$(echo "$D2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["new"])')" "0"

printf '| `smc_unhandled` | 예외2, ELR 이 smc | psci 미구현 (근거) | `fixer-el3` | id 처리 |\n' >> "$DW/STATIC.md"
D3=$(python3 "$S/derived_facts.py" "$DW" --track 1)
chk "진짜 새 정지점은 new=1"     "$(echo "$D3" | python3 -c 'import json,sys;print(json.load(sys.stdin)["new"])')" "1"

# 표가 없으면 0 이어야 한다 (없는 걸 지어내지 않음)
EW2=$(new_ws derived_empty)
D4=$(python3 "$S/derived_facts.py" "$EW2" --track 1)
chk "표가 없으면 new=0"          "$(echo "$D4" | python3 -c 'import json,sys;print(json.load(sys.stdin)["new"])')" "0"

# 측정값이 정지 판정까지 이어지는가
python3 - "$DW" <<'PY2'
import json, os, sys
w = sys.argv[1]
with open(os.path.join(w, "rounds.jsonl"), "w") as f:
    for i in range(5, 23):
        f.write(json.dumps({"round": i, "goal": "shell", "fp_exc": "2020000",
            "fp_far": "0x620", "fp_elr": "0x620", "fp_milestone": "none", "fp_bytes": 0,
            "category": "unknown", "fixer": "fixer-bootflow", "change_key": None,
            "effect": "stall", "analyst_new_facts": 0, "fixer_no_new_change": True}) + "\n")
PY2
SC=$(python3 "$S/stop_conditions.py" "$DW" --ladder shell)
chk "새 도출 0 + fixer 소진 → EXHAUSTED" \
    "$(echo "$SC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "EXHAUSTED"

# 반대로 도출이 계속 나오면 멈추면 안 된다
python3 - "$DW" <<'PY3'
import json, os, sys
w = sys.argv[1]
rows = open(os.path.join(w, "rounds.jsonl")).read().replace('"analyst_new_facts": 0',
                                                            '"analyst_new_facts": 1')
open(os.path.join(w, "rounds.jsonl"), "w").write(rows)
PY3
SC2=$(python3 "$S/stop_conditions.py" "$DW" --ladder shell)
chk "새 도출이 있으면 계속 진행" \
    "$(echo "$SC2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"


# 15. 층 판정 신호 (futile_changes) — 고쳤는데 아무 변화 없음을 보는가
printf '\n\033[1m== 15. 층 판정 신호 ==\033[0m\n'
LW=$(new_ws layer)
python3 - "$LW" <<'PY4'
import json, os, sys
w = sys.argv[1]
with open(os.path.join(w, "rounds.jsonl"), "w") as f:
    for i in range(1, 21):
        # 회차 10·15 에 변경을 적용했지만 지문은 계속 0x620 그대로
        f.write(json.dumps({"round": i, "goal": "shell", "fp_exc": "2130000",
            "fp_far": "0x620", "fp_elr": "0x620", "fp_milestone": "none", "fp_bytes": 0,
            "category": "unknown", "fixer": "fixer-bootflow",
            "change_key": f"bandaid_{i}" if i in (10, 15) else None,
            "effect": "applied" if i in (10, 15) else "stall",
            "analyst_new_facts": 1, "fixer_no_new_change": False}) + "\n")
PY4
LJ=$(python3 "$S/stop_conditions.py" "$LW" --ladder shell)
chk "무효 변경을 센다"           "$(echo "$LJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["futile_changes"])')" "2"
chk "층 재검토 신호 발화"        "$(echo "$LJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["needs_layer_review"])')" "True"
chk "그래도 정지는 아니다"       "$(echo "$LJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"

# 지문을 움직인 변경은 무효가 아니다
python3 - "$LW" <<'PY5'
import json, os, sys
w = sys.argv[1]
rows = [json.loads(l) for l in open(os.path.join(w, "rounds.jsonl"))]
for r in rows[15:]:
    r["fp_far"] = "0xC90A5028"          # 변경이 지문을 움직였다
open(os.path.join(w, "rounds.jsonl"), "w").write(
    "".join(json.dumps(x, ensure_ascii=False) + "\n" for x in rows))
PY5
LJ2=$(python3 "$S/stop_conditions.py" "$LW" --ladder shell)
chk "지문이 움직이면 무효 아님"  "$(echo "$LJ2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["needs_layer_review"])')" "False"

# 관측 문서에 신호가 실려 나가는가 (supervisor 가 봐야 판단한다)
grep -q 'needs_layer_review' "$S/run_round.sh"
chk "run_round 가 신호를 병합"   "$?" "0"

# build 층 정지점이 지식 테이블에 있는가
grep -q "entry_el_mismatch" "$REPO/knowledge/faults_bootloader.md"
chk "build 층 정지점 등재"       "$?" "0"
grep -q "rebuild" "$REPO/agents/supervisor.md"
chk "supervisor 가 rebuild 를 안다" "$?" "0"


# 16. 최후수단 fixer + 트랙 경계
printf '\n\033[1m== 16. fixer-general · 트랙 경계 ==\033[0m\n'

# 범위 무제한 fixer 가 정지를 막지 못해야 한다
GW2=$(new_ws general)
python3 - "$GW2" <<'PY6'
import json, os, sys
w = sys.argv[1]
with open(os.path.join(w, "rounds.jsonl"), "w") as f:
    for i in range(1, 21):
        f.write(json.dumps({"round": i, "goal": "shell", "fp_exc": "2130000",
            "fp_far": "0x620", "fp_elr": "0x620", "fp_milestone": "none", "fp_bytes": 0,
            "category": "unknown", "fixer": "fixer-general",
            "change_key": f"try_{i}" if i >= 8 else None,
            "effect": "applied" if i >= 8 else "stall",
            "analyst_new_facts": 0, "fixer_no_new_change": False}) + "\n")
PY6
GJ=$(python3 "$S/stop_conditions.py" "$GW2" --ladder shell)
chk "무효 변경은 수로 안 센다"     "$(echo "$GJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["futile_spent"])')" "True"
chk "general 이 시도 중이어도 소진" "$(echo "$GJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "EXHAUSTED"

# 지문이 움직이면 소진이 아니다
python3 - "$GW2" <<'PY7'
import json, os, sys
w = sys.argv[1]
rows = [json.loads(l) for l in open(os.path.join(w, "rounds.jsonl"))]
for n, r in enumerate(rows):
    if n >= 9: r["fp_far"] = f"0x{0xC90A5000 + n:X}"
open(os.path.join(w, "rounds.jsonl"), "w").write(
    "".join(json.dumps(x, ensure_ascii=False) + "\n" for x in rows))
PY7
GJ2=$(python3 "$S/stop_conditions.py" "$GW2" --ladder shell)
chk "진전 중이면 소진 아님"        "$(echo "$GJ2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"

# 트랙 1 에 스토리지/커널 fixer 가 새지 않는가
T1=$(python3 - <<'PY8'
import re, pathlib
s = pathlib.Path("workflows/pipeline.js").read_text()
m = re.search(r"FIXERS_BY_TRACK = \{\s*1: \[([^\]]*)\]", s)
print(m.group(1).replace("'", "").replace(" ", "") if m else "PARSE_FAIL")
PY8
)
chk "트랙 1 fixer 목록"            "$T1" "fixer-memory,fixer-el3,fixer-bootflow"
grep -q 'fixer-storage' <<< "$T1"
chk "트랙 1 에 스토리지 fixer 없음" "$?" "1"

# 최후수단은 순위로 오르지 않는다
grep -q "KNOWN_FIXERS = FIXERS_BY_TRACK" "$REPO/workflows/pipeline.js"
chk "general 은 KNOWN_FIXERS 밖"   "$?" "0"
grep -q 'reached_by: decline_only' "$REPO/fixers/registry.yaml"
chk "registry 에 도달 조건 명시"   "$?" "0"
grep -q 'fixer_candidates.md' "$REPO/agents/fixer-general.md"
chk "후보 기록 지시 있음"          "$?" "0"

# supervisor 가 명부를 보고 처방하고, 담당 없으면 직행하는가
grep -q 'prescribed_fixer' "$REPO/agents/supervisor.md"
chk "supervisor 가 처방을 안다"    "$?" "0"
grep -q 'route === GENERAL_FIXER' "$REPO/workflows/pipeline.js"
chk "general 직행 경로 배선"       "$?" "0"
grep -q 'KNOWN_FIXERS.includes(sup?.prescribed_fixer)' "$REPO/workflows/pipeline.js"
chk "처방은 트랙 fixer 만 허용"    "$?" "0"


printf '\n\033[1m════════ 결과: %d 통과 / %d 실패 ════════\033[0m\n' "$PASS" "$FAIL"
echo "작업 폴더: $ROOT"
[ "$FAIL" -eq 0 ]
