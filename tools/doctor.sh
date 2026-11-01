#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Preflight for a fresh clone: what exists, what the phone is doing, what to do.
set -uo pipefail

BASE=Redmi10c-base
OUT=$BASE/out/ubuntu-dualboot
bad=0
ok()  { printf '  ok    %s\n' "$*"; }
no()  { printf '  MISS  %s\n' "$*"; bad=1; }

echo "host"
command -v docker >/dev/null 2>&1 && ok docker || no "docker (needed for kernel/rootfs builds)"
for i in fog-build:latest fog-rootfs:latest; do
    if docker image inspect "$i" >/dev/null 2>&1; then ok "image $i"
    else no "image $i — build from build/Dockerfile*, see RUNBOOK 'Reproduce'"; fi
done
command -v adb >/dev/null 2>&1 && ok adb || no "adb/fastboot (Android platform-tools)"

echo "sources"
if [ -d "$BASE/.git" ]; then ok "upstream clone ($BASE)"
else no "upstream clone — git clone https://github.com/Damir00109/Redmi10c $BASE"; fi
if [ -f "$BASE/out/linux-7.1.5/arch/arm64/boot/Image.gz" ]; then ok "kernel built"
else no "kernel not built — make kernel (~10 min)"; fi

echo "artifacts"
if [ -f "$OUT/boot-linux.img" ]; then ok boot-linux.img
else no "boot-linux.img — make image"; fi
if [ -f "$OUT/linux_rootfs.img" ]; then ok linux_rootfs.img
else no "linux_rootfs.img — debootstrap, see RUNBOOK 'Rootfs' (~20 min)"; fi
if [ -f "$OUT/linux_rootfs.sparse.img" ]; then ok linux_rootfs.sparse.img
else no "linux_rootfs.sparse.img — make rootfs"; fi

echo "device"
adb_state=$(adb devices 2>/dev/null | awk 'NR>1 && NF {print $2; exit}')
if [ "$adb_state" = "device" ]; then
    kver=$(adb shell uname -r 2>/dev/null | tr -d '\r')
    case "$kver" in
        7.*) ok "adb: Linux ($kver) — adb shell is root; 'make adb' for the cookbook" ;;
        *)   ok "adb: Android/recovery ($kver) — not the Linux port; 'make test SKIP_CUST=1'" ;;
    esac
elif [ "$adb_state" = "recovery" ]; then
    ok "adb: recovery (PBRP) — RAM boot; boot Linux: 'make test SKIP_CUST=1'"
elif [ "$adb_state" = "unauthorized" ]; then
    ok "adb: unauthorized — 'make rootfs' installs this host's key"
elif fastboot devices 2>/dev/null | grep -q .; then
    ok "fastboot: slot=$(fastboot getvar current-slot 2>&1 | head -1 | sed 's/.*: //')" \
       "retry_b=$(fastboot getvar slot-retry-count:b 2>&1 | head -1 | sed 's/.*: //')"
else
    no "no phone on adb/fastboot — power on, or hold Vol-Down + Power for fastboot"
fi

echo
if [ "$bad" -eq 0 ]; then
    echo "ready: make test"
else
    echo "not ready — fix the MISS lines above"
    exit 1
fi
