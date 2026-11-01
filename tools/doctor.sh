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
for f in "$OUT/boot-linux.img" "$OUT/linux_rootfs.img" "$OUT/linux_rootfs.sparse.img"; do
    if [ -f "$f" ]; then ok "$(basename "$f")"
    else no "$(basename "$f") — make image / make rootfs"; fi
done

echo "device"
adb_state=$(adb devices 2>/dev/null | awk 'NR>1 && NF {print $2; exit}')
if [ "$adb_state" = "device" ]; then
    ok "adb: $(adb devices -l 2>/dev/null | awk 'NR==2 {print $4, $5}')"
elif [ "$adb_state" = "recovery" ]; then
    ok "adb: recovery (PBRP) — RAM boot, no slot written"
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
