#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the upstream v7.3.0 tree (kernel v7.3 + Ubuntu 26.04 rootfs) for the
# Redmi 10C `fog`. Subcommands:
#
#   base    checkout worktree, firmware, cloud rootfs, container image
#   kernel  kernel.patch + our fog DTS deltas, Image.gz/dtbs/modules
#   image   pack boot-linux.img (pivot initramfs) and verify it
#   rootfs  build the Ubuntu 26.04 `cust` image (tools/build-rootfs-v730.sh)
#
# All builds run in the arm64 `fog-v730` container (host is Apple Silicon, so
# this is a native build; no cross compiler or qemu).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V730="$ROOT/Redmi10c-base/v730"
KERN="$V730/out/build/linux-7.3"
DTS="$V730/out/src/linux/arch/arm64/boot/dts/qcom/sm6225-xiaomi-fog.dts"
FW_TAG="${FW_TAG:-firmware-2026.09.25}"
CLOUD_TAR="$V730/rootfs/cache/ubuntu-26.04-server-cloudimg-arm64-root.tar.xz"
CLOUD_URL="https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-arm64-root.tar.xz"
KERNEL_TAG="${KERNEL_TAG:-v7.3}"

export DOCKER_CONFIG="$ROOT/.docker"
docker_run() {
  docker run --rm --platform linux/arm64 -v "$V730":/src -w /src fog-v730:latest "$@"
}

log() { echo "[v730] $*"; }

cmd_base() {
  if [ ! -d "$V730" ]; then
    log "creating worktree $V730"
    git -C "$ROOT/Redmi10c-base" fetch origin v7.3.0
    git -C "$ROOT/Redmi10c-base" worktree add "$V730" origin/v7.3.0
  fi

  log "applying fog identity (USB serial/product, hostname, user, fs label)"
  python3 "$ROOT/tools/v730-fog-identity.py" "$V730"

  if [ ! -f "$V730/initramfs/lib/firmware/focaltech_ts_fw_xinli.bin" ]; then
    log "fetching firmware $FW_TAG"
    tmp="$(mktemp -d)"
    gh release download "$FW_TAG" -R Damir00109/Redmi10c \
      -p redmi10c-firmware.tar.zst -O "$tmp/fw.tar.zst"
    tar --zstd -xf "$tmp/fw.tar.zst" -C "$tmp"
    rm -rf "$V730/initramfs/lib/firmware" "$V730/vendor-qcom" "$V730/sensors"
    mkdir -p "$V730/initramfs/lib" "$V730/vendor-qcom"
    cp -a "$tmp/firmware" "$V730/initramfs/lib/firmware"
    cp -a "$tmp/qcom" "$V730/vendor-qcom/qcom"
    [ -d "$tmp/sensors" ] && cp -a "$tmp/sensors" "$V730/sensors"
    rm -rf "$tmp"
  fi

  if [ ! -f "$CLOUD_TAR" ]; then
    log "downloading Ubuntu 26.04 cloud rootfs"
    mkdir -p "$(dirname "$CLOUD_TAR")"
    curl -L --fail --retry 3 -o "$CLOUD_TAR.part" "$CLOUD_URL"
    mv "$CLOUD_TAR.part" "$CLOUD_TAR"
  fi

  if ! docker image inspect fog-v730:latest >/dev/null 2>&1; then
    log "building fog-v730 container"
    docker build --platform linux/arm64 -f "$ROOT/build/Dockerfile.v730" -t fog-v730 "$ROOT/build"
  fi
}

cmd_kernel() {
  cmd_base
  if [ ! -f "$KERN/arch/arm64/boot/Image.gz" ]; then
    if [ ! -d "$V730/out/src/linux/.git" ]; then
      log "preparing kernel $KERNEL_TAG source (tarball; git clone is ~30x slower)"
      mkdir -p "$V730/out/src"
      curl -L --fail --retry 3 -o "$V730/out/src/linux.tar.xz" \
        "https://cdn.kernel.org/pub/linux/kernel/${KERNEL_TAG%.*}.x/linux-${KERNEL_TAG#v}.tar.xz"
      rm -rf "$V730/out/src/linux"
      mkdir -p "$V730/out/src/linux"
      tar -xJf "$V730/out/src/linux.tar.xz" -C "$V730/out/src/linux" --strip-components=1
      rm -f "$V730/out/src/linux.tar.xz"
      git -C "$V730/out/src/linux" init -q
      git -C "$V730/out/src/linux" add -A
      git -C "$V730/out/src/linux" -c user.email=build@local -c user.name=build \
        commit -qm "linux $KERNEL_TAG base"
      git -C "$V730/out/src/linux" tag "$KERNEL_TAG"
    fi
    log "building kernel (build.sh: patch, Image.gz, dtbs, busybox, rescue image)"
    docker_run env CROSS_COMPILE= JOBS="$(sysctl -n hw.ncpu)" ./build.sh
  fi

  log "applying fog DTS deltas (board-id 0x40022, HS-PHY rails, L12/L15)"
  python3 "$ROOT/tools/v730-fog-dts.py" "$DTS"
  docker_run bash -lc '
    set -e
    make -C out/src/linux O=/src/out/build/linux-7.3 ARCH=arm64 CROSS_COMPILE= \
      -j"$(nproc)" dtbs modules
    make -C out/src/linux O=/src/out/build/linux-7.3 ARCH=arm64 CROSS_COMPILE= \
      INSTALL_MOD_PATH=/src/out/build/linux-7.3 modules_install
  '
}

cmd_image() {
  cmd_base
  [ -f "$DTS" ] || { echo "no kernel tree — run: $0 kernel" >&2; exit 1; }
  docker_run bash -lc 'cd rootfs && ./tools/pack-boot-linux.sh'
  "$ROOT/tools/verify-image.sh" "$V730/rootfs/out/boot-linux.img"
}

cmd_rootfs() {
  cmd_base
  "$ROOT/tools/build-rootfs-v730.sh"
}

case "${1:-}" in
  base) cmd_base ;;
  kernel) cmd_kernel ;;
  image) cmd_image ;;
  rootfs) cmd_rootfs ;;
  *) echo "usage: $0 {base|kernel|image|rootfs}" >&2; exit 2 ;;
esac
