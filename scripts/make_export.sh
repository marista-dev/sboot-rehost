#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# make_export.sh — 완성된 워크스페이스 → "빌드 없이 바로 실행" 키트로 조립.
# /sboot-rehost:rehost-export 스킬이 호출. 기계적 복사 + turnkey run/setup/build/.gitignore 생성.
# 문서(docs/*.md narrative)와 완료 확인·통지는 스킬이 담당.
#
# 사용법 (env 로 파라미터):
#   WS=<workspace> TRACK=<1|2> DEST=<dest dir> QEMU=<prebuilt qemu> MACHINE=<machine name> \
#   [CPU=cortex-a76] [SMP=8] [MEM=4G] [KCMDLINE="..."] [INPUT_CMD=help] \
#   [EUFS_LU_IMAGE=~/rehost/<id>/disk.img] [EUFS_LBS=4096] \
#   bash make_export.sh
set -e
: "${WS:?WS 워크스페이스 필요}"; : "${TRACK:?TRACK 1|2 필요}"; : "${DEST:?DEST 필요}"
: "${MACHINE:?MACHINE 필요}"
CPU="${CPU:-cortex-a76}"; SMP="${SMP:-8}"; MEM="${MEM:-4G}"; INPUT_CMD="${INPUT_CMD:-help}"

mkdir -p "$DEST"/{bin,firmware,machine,scripts,evidence,docs}

# ── 프리빌트 QEMU (빌드 없이 실행의 핵심) ──
if [ -n "${QEMU:-}" ] && [ -x "$QEMU" ]; then
  cp "$QEMU" "$DEST/bin/qemu-system-aarch64"; echo "  bin/qemu-system-aarch64 (prebuilt)"
else
  echo "  ★ 프리빌트 QEMU 없음 — 받는 사람이 scripts/build.sh 로 빌드해야 함"
fi

# ── 실행 분석 (시간·비용이 어디로 갔는지) ──
# 측정치를 그대로 넘기면 받는 사람이 jsonl 을 직접 읽어야 한다. 어느 정지점이 회차를
# 가장 많이 먹었고 어느 변경이 관측을 못 움직였는지는 기록에서 계산되는 값이므로,
# 내보내기 시점에 한 번 계산해 문서로 넣는다.
python3 "$(dirname "$0")/analyze_run.py" "$WS" --track "$TRACK" >/dev/null 2>&1 \
  || echo "  ★ 실행 분석 생성 실패 — jsonl 기록을 확인하세요"

# ── evidence (기록·증거) ──
# 사람이 읽는 기록(JOURNAL/PROGRESS/VERIFICATION/ANALYSIS) + 기계가 읽는 측정치(*.jsonl) 둘 다.
for f in VERIFICATION.md ANALYSIS.md PROGRESS.md JOURNAL.md STATIC.md STUBS.md KERNEL_STATIC.md INPUT.md \
         metrics.jsonl rounds.jsonl blockers.jsonl verdict_script.json analysis.json \
         fingerprint.json observation.json; do
  [ -f "$WS/$f" ] && cp "$WS/$f" "$DEST/evidence/"
done
cp "$WS"/07_logs/console_*.txt "$WS"/07_logs/*.summary.txt "$WS"/07_logs/kboot_*.txt "$DEST/evidence/" 2>/dev/null || true
# What the harness typed, and what the firmware did with it. Without these the
# kit shows the console but not whether the surface was reached by real input.
cp "$WS"/07_logs/input_*.txt "$WS"/input_summary.json "$DEST/evidence/" 2>/dev/null || true

if [ "$TRACK" = "1" ]; then
  # ── 트랙 1: sboot 셸 ──
  cp "$WS"/02_unpacked/sboot.bin "$DEST/firmware/" 2>/dev/null || cp "$WS"/03_bl3/*.bin "$DEST/firmware/sboot.bin" 2>/dev/null || echo "  ★ sboot.bin 없음"
  cp "$WS"/06_machine/machine.c "$DEST/machine/" 2>/dev/null || true
  cp "$WS"/06_machine/*.md "$DEST/machine/" 2>/dev/null || true   # 우회_패치_목록.md 등
  # The kit must reach the surface the same way the run did: the autoboot gate
  # is one-shot and wants a run of a derived byte, so the harness and the derived
  # plan travel with it. A kit that only pipes the command in cannot pass that
  # gate, and then it does not reproduce what it claims to.
  P="$(dirname "$0")"
  cp "$P/uart_harness.py" "$DEST/scripts/" 2>/dev/null || true
  cp "$WS/input_plan.json" "$WS/milestone_tokens.txt" "$DEST/scripts/" 2>/dev/null || true
  PROMPT_TOKEN=""
  [ -s "$WS/milestone_tokens.txt" ] && PROMPT_TOKEN=$(awk -F'\t' 'NF>1 && $1=="shell" {print $2; exit}' "$WS/milestone_tokens.txt")
  cat > "$DEST/run.sh" <<RUN
#!/usr/bin/env bash
# turnkey — 빌드 없이 실행 (WSL2/Linux x86_64). bash run.sh
set +e; DIR="\$(cd "\$(dirname "\$0")" && pwd)"
QEMU="\$DIR/bin/qemu-system-aarch64"; SB="\$DIR/firmware/sboot.bin"
[ -x "\$QEMU" ] || { echo "★ bin/qemu 없음 — bash scripts/build.sh 로 빌드"; exit 1; }
[ -f "\$SB" ]   || { echo "★ firmware/sboot.bin 없음"; exit 1; }
"\$QEMU" --version >/dev/null 2>&1 || { echo "★ 공유 라이브러리 부족 — bash setup.sh 먼저"; exit 1; }
echo "== $MACHINE — 부트로더 표면 도달 + '$INPUT_CMD' =="
# 입력은 QEMU 밖에서 넣는다. 머신이 자기 RX 를 채우면 스스로에게 명령을 준 것이라
# 도달로 인정되지 않는다(정직성 §7). 보낸 바이트는 전부 out/input.txt 에 남는다.
mkdir -p "\$DIR/out"
python3 "\$DIR/scripts/uart_harness.py" \\
  --console "\$DIR/out/console.txt" --input-log "\$DIR/out/input.txt" \\
  --summary "\$DIR/out/input_summary.json" \\
  --plan "\$DIR/scripts/input_plan.json" \\
  --timeout ${RUN_TIMEOUT_S:-20} --cmd '$INPUT_CMD' --surface shell \\
  ${PROMPT_TOKEN:+--prompt-token '$PROMPT_TOKEN'} \\
  -- "\$QEMU" -M $MACHINE -cpu $CPU -kernel "\$SB" \\
     -display none -serial stdio -monitor none
echo
echo "-- 콘솔 --"; tail -40 "\$DIR/out/console.txt"
echo "-- 입력 경로 --"; cat "\$DIR/out/input_summary.json"
RUN
else
  # ── 트랙 2: 커널 + UFS ──
  cp "$WS"/fw/Image.patched "$WS"/fw/Image "$DEST/firmware/" 2>/dev/null || true
  cp "$WS"/fw/*.dtb "$WS"/fw/*.cpio* "$WS"/fw/initramfs* "$DEST/firmware/" 2>/dev/null || true
  cp "$WS"/06_machine/machine_kernel.c "$WS"/06_machine/*ufs*.c "$WS"/06_machine/*ufs*.h "$DEST/machine/" 2>/dev/null || true
  cp "$WS"/06_machine/*.md "$DEST/machine/" 2>/dev/null || true
  # 패치 스크립트 (플러그인 것 복사 — 받는 사람이 재빌드 시)
  P="$(dirname "$0")"
  cp "$P/patch_kernel.py" "$P/patch_qemu_core.py" "$P/run_kernel.sh" "$DEST/scripts/" 2>/dev/null || true
  # 디스크/rootfs 는 대용량 — 참조만 남기고 심볼릭/안내 (실이미지는 스킬이 판단해 복사)
  EUFS_LINE=""
  [ -n "${EUFS_LU_IMAGE:-}" ] && EUFS_LINE="EUFS_LU_IMAGE=\"\$DIR/firmware/\$(basename "$EUFS_LU_IMAGE")\" EUFS_LBS=${EUFS_LBS:-4096}"
  cat > "$DEST/run.sh" <<RUN
#!/usr/bin/env bash
# turnkey — 빌드 없이 커널 부팅 (WSL2/Linux x86_64). bash run.sh
set +e; DIR="\$(cd "\$(dirname "\$0")" && pwd)"
QEMU="\$DIR/bin/qemu-system-aarch64"; IMG="\$DIR/firmware/Image.patched"
DTB="\$(ls "\$DIR"/firmware/*.dtb 2>/dev/null | head -1)"
IRD="\$(ls "\$DIR"/firmware/*.cpio* "\$DIR"/firmware/initramfs* 2>/dev/null | head -1)"
[ -x "\$QEMU" ] || { echo "★ bin/qemu 없음 — bash scripts/build.sh"; exit 1; }
[ -f "\$IMG" ]  || { echo "★ firmware/Image.patched 없음"; exit 1; }
"\$QEMU" --version >/dev/null 2>&1 || { echo "★ 공유 라이브러리 부족 — bash setup.sh 먼저"; exit 1; }
echo "== $MACHINE — 커널 직부팅 (트랙 2) =="
$EUFS_LINE timeout 200 "\$QEMU" -M $MACHINE -cpu $CPU -smp $SMP -m $MEM -nographic \\
  -kernel "\$IMG" \${DTB:+-dtb "\$DTB"} \${IRD:+-initrd "\$IRD"} \\
  ${KCMDLINE:+-append "$KCMDLINE"} -serial mon:stdio
RUN
fi

# ── 공용: setup.sh (공유 라이브러리) / build.sh (프리빌트 없을 때 재빌드) / .gitignore ──
cat > "$DEST/setup.sh" <<'SETUP'
#!/usr/bin/env bash
# 최초 1회 — 포함된 QEMU 실행에 필요한 공유 라이브러리만 (빌드 아님).
sudo apt-get update -qq || true
sudo apt-get install -y libglib2.0-0 libpixman-1-0 libslirp0 2>/dev/null || true
echo "setup: OK (누락 상세: ldd bin/qemu-system-aarch64 | grep 'not found')"
SETUP

cat > "$DEST/scripts/build.sh" <<'BUILD'
#!/usr/bin/env bash
# 프리빌트 bin/ 이 없을 때(예: git 경로로 받음) QEMU 10.2.2 에 machine 통합 후 재빌드.
set -e; DIR="$(cd "$(dirname "$0")/.." && pwd)"; Q="$HOME/qemu-build/qemu-10.2.2"
[ -d "$Q" ] || { echo "QEMU 10.2.2 소스 필요: ~/qemu-build/qemu-10.2.2 (HOW-TO-RUN 참조)"; exit 1; }
cp "$DIR"/machine/*.c "$DIR"/machine/*.h "$Q/hw/arm/" 2>/dev/null || cp "$DIR"/machine/*.c "$Q/hw/arm/"
grep -q "$(ls "$DIR"/machine/*.c | head -1 | xargs basename)" "$Q/hw/arm/meson.build" || \
  printf "arm_ss.add(files(%s))\n" "$(cd "$DIR/machine" && ls *.c | sed "s/.*/'&'/" | paste -sd, -)" >> "$Q/hw/arm/meson.build"
[ -f "$DIR"/scripts/patch_qemu_core.py ] && python3 "$DIR"/scripts/patch_qemu_core.py || true
cd "$Q/build" && ninja qemu-system-aarch64
cp "$Q/build/qemu-system-aarch64" "$DIR/bin/"; echo "build: bin/qemu-system-aarch64 갱신"
BUILD

cat > "$DEST/.gitignore" <<'GI'
# 이 키트의 대용량/저작권 파일 — git 커밋 금지. 폴더 직접 공유(zip/복사) 시엔 그대로 실행됨.
bin/
firmware/
*.log
*.img
GI

chmod +x "$DEST/run.sh" "$DEST/setup.sh" "$DEST/scripts/build.sh" 2>/dev/null || true
echo "make_export: DONE -> $DEST"
