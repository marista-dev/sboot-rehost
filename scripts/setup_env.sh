#!/usr/bin/env bash
# setup_env.sh — sboot-rehost 의 의존성 자동 설치
# /sboot-rehost:rehost-init 또는 실행 명령의 S0 단계가 호출. 사용자 동의 후만 실행.
# 소요: 약 18 분 (대부분 QEMU 빌드)

set -e

echo "============================================================"
echo " sboot-rehost — 의존성 셋업 (~18 분)"
echo "============================================================"

# ---- 1) apt ----
echo "=== [1/3] apt 패키지 설치 (sudo 필요) ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential ninja-build pkg-config \
    libglib2.0-dev libpixman-1-dev libslirp-dev \
    python3 python3-pip python3-venv \
    socat unzip wget curl tar lz4 file \
    flex bison device-tree-compiler   # 트랙 2: 커널/DTB (dtc=fdtdump, flex/bison=QEMU dtc)
# 트랙 2 K3 (dm-linear/모듈 로드 캡스톤) 은 aarch64 크로스툴체인 추가 필요 —
# 무루트 확보는 worked example 의 get_xtool.sh (공식 Ubuntu .deb apt-get download) 참고.

# ---- 2) pip ----
echo "=== [2/3] pip 패키지 (capstone, meson 등) ==="
pip3 install --break-system-packages meson capstone lz4 keystone-engine || {
    echo "  fallback: --user 로 재시도"
    pip3 install --user meson capstone lz4 keystone-engine
}

# pip 위치 PATH 추가 (한 번)
if ! grep -q '/.local/bin' "$HOME/.bashrc"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$HOME/.local/bin:$PATH"

# ---- 3) QEMU 10.2.2 ----
echo "=== [3/3] QEMU 10.2.2 다운로드 + 빌드 ==="
QEMU_DIR="$HOME/qemu-build/qemu-10.2.2"

if [[ ! -d "$QEMU_DIR" ]]; then
    mkdir -p "$HOME/qemu-build"
    cd "$HOME/qemu-build"
    if [[ ! -f qemu-10.2.2.tar.xz ]]; then
        curl -L -o qemu-10.2.2.tar.xz https://download.qemu.org/qemu-10.2.2.tar.xz
    fi
    tar xf qemu-10.2.2.tar.xz
fi

cd "$QEMU_DIR"
if [[ ! -d build ]]; then
    mkdir build && cd build
    ../configure \
        --target-list=aarch64-softmmu \
        --disable-werror \
        --disable-sdl \
        --disable-vnc \
        --disable-gtk \
        --disable-docs
else
    cd build
fi

ninja qemu-system-aarch64

# ---- 검증 ----
echo
echo "=== 검증 ==="
"$QEMU_DIR/build/qemu-system-aarch64" --version | head -1
python3 -c "import capstone; print('capstone', capstone.__version__)"
python3 -c "import keystone; print('keystone OK')" || echo "  (keystone optional)"
which meson && meson --version || true

echo
echo "OK: 환경 셋업 완료."
echo "다음 단계: Claude Code 에서 /sboot-rehost:rehost-bootloader (트랙 1) 또는 /sboot-rehost:rehost-kernel (트랙 2) 호출"
