#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build upstream v7.3.0's Ubuntu 26.04 `cust` rootfs inside an arm64
# privileged container (host is Apple Silicon; no qemu needed).
#
# Runs Redmi10c-base/v730/rootfs/build-rootfs.sh with our fog identity edits
# applied first (hostname/user/USB strings/fs label — see
# tools/v730-fog-identity.py), and:
#   REDMI=/src          -> picks up kernel modules, firmware, overlay, sensors
#   IMG_SIZE_MB=1800    -> cust is 2 GiB; override with IMG_SIZE_MB=...
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V730="$ROOT/Redmi10c-base/v730"
[ -d "$V730/rootfs" ] || { echo "missing $V730 — run: make base" >&2; exit 1; }
python3 "$ROOT/tools/v730-fog-identity.py" "$V730"
TAR="$V730/rootfs/cache/ubuntu-26.04-server-cloudimg-arm64-root.tar.xz"
URL="https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-arm64-root.tar.xz"
IMG_SIZE_MB="${IMG_SIZE_MB:-1800}"

if [ ! -f "$TAR" ]; then
  echo ">> downloading $URL"
  mkdir -p "$(dirname "$TAR")"
  curl -L --fail --retry 3 -o "$TAR.part" "$URL"
  mv "$TAR.part" "$TAR"
fi

# adbd host key: v7.3's build copies "$HOME/.android/adbkey.pub" into the image.
HOME_DIR="$ROOT/docs/.scratch/v730-home"
mkdir -p "$HOME_DIR/.android"
if [ -f "$HOME/.android/adbkey.pub" ]; then
  cp -f "$HOME/.android/adbkey.pub" "$HOME_DIR/.android/adbkey.pub"
else
  echo "note: no ~/.android/adbkey.pub — adb will ask for authorization" >&2
fi

exec env DOCKER_CONFIG="$ROOT/.docker" \
  docker run --rm --privileged --security-opt seccomp=unconfined --security-opt apparmor=unconfined --platform linux/arm64 \
  -v "$V730":/src \
  -v "$HOME_DIR":/root \
  -w /src \
  -e REDMI=/src \
  -e IMG_SIZE_MB="$IMG_SIZE_MB" \
  fog-v730:latest bash -lc 'mkdir -p /build/out && OUT=/build/out bash rootfs/build-rootfs.sh && cp -a /build/out/linux_rootfs*.img /src/rootfs/out/'
