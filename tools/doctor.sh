#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Preflight for a fresh clone: what exists, what the phone is doing, what to do.
set -uo pipefail

BASE=Redmi10c-base
V730=$BASE/v730
OUT=$V730/rootfs/out
bad=0
ok()  { printf '  ok    %s\n' "$*"; }
no()  { printf '  MISS  %s\n' "$*"; bad=1; }

echo "host"
command -v docker >/dev/null 2>&1 && ok docker || no "docker (needed for kernel/rootfs builds)"
for i in fog-v730:latest; do
    if docker image inspect "$i" >/dev/null 2>&1; then ok "image $i"
    else no "image $i — make base builds it"; fi
done
command -v adb >/dev/null 2>&1 && ok adb || no "adb/fastboot (Android platform-tools)"
command -v gh >/dev/null 2>&1 && ok gh || no "gh (firmware release download)"

echo "sources"
if [ -d "$BASE/.git" ]; then ok "upstream clone ($BASE)"
else no "upstream clone — git clone https://github.com/Damir00109/Redmi10c $BASE"; fi
if [ -d "$V730" ]; then ok "v7.3.0 worktree ($V730)"
else no "v7.3.0 worktree — make base"; fi
if [ -f "$V730/initramfs/lib/firmware/focaltech_ts_fw_xinli.bin" ]; then ok "firmware staged"
else no "firmware — make base (gh release download)"; fi
if [ -f "$V730/out/build/linux-7.3/arch/arm64/boot/Image.gz" ]; then ok "kernel 7.3 built"
else no "kernel not built — make kernel (~15 min)"; fi

echo "artifacts"
if [ -f "$OUT/boot-linux.img" ]; then ok "boot-linux.img ($(du -h "$OUT/boot-linux.img" | cut -f1))"
else no "boot-linux.img — make image"; fi
if [ -f "$OUT/linux_rootfs.sparse.img" ]; then ok "linux_rootfs.sparse.img ($(du -h "$OUT/linux_rootfs.sparse.img" | cut -f1))"
else no "linux_rootfs.sparse.img — make rootfs (~15 min)"; fi

echo "device"
adb_state=$(adb devices 2>/dev/null | awk 'NR>1 && NF {print $2; exit}')
if [ "$adb_state" = "device" ]; then
    kver=$(adb shell uname -r 2>/dev/null | tr -d '\r')
    case "$kver" in
        7.3.*) ok "adb: Linux ($kver) — root shell; 'make test' re-boots it from RAM" ;;
        7.*)   ok "adb: Linux ($kver, old image) — 'make test' replaces it" ;;
        *)     ok "adb: Android/recovery ($kver) — not the Linux port" ;;
    esac
elif [ "$adb_state" = "recovery" ]; then
    ok "adb: recovery (PBRP) — RAM boot; 'make test' boots Linux"
elif [ "$adb_state" = "unauthorized" ]; then
    ok "adb: unauthorized — the rootfs build installs this host's key"
elif fastboot devices 2>/dev/null | grep -q .; then
    ok "fastboot: slot=$(fastboot getvar current-slot 2>&1 | head -1 | sed 's/.*: //')"
else
    no "no phone on adb/fastboot — power on, or hold Vol-Down + Power for fastboot"
fi

echo
if [ "$bad" -eq 0 ]; then
    echo "ready: make test   (RAM boot; writes no slot)"
else
    echo "not ready — fix the MISS lines above"
    exit 1
fi
