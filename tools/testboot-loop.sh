#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Autonomous test-boot loop for the Redmi 10C (rain/fog).
#
# The phone reboots itself into fastboot after each test boot
# (rain-autoreboot.service), so no physical power cycle is needed:
#
#   flash boot_b + cust -> boot -> wait for fastboot to return
#     -> RAM-boot PBRP -> mount cust -> pull the report -> exit
#
# Usage: tools/testboot-loop.sh [--no-flash] [--keep-going] [--timeout SEC]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$ROOT/Redmi10c-base"
OUT="$BASE/out/ubuntu-dualboot"
BOOT_IMG="${BOOT_IMG:-$OUT/boot-linux.img}"
CUST_IMG="${CUST_IMG:-$OUT/linux_rootfs.sparse.img}"
PBRP="$ROOT/reference/pbrp-fog-boot.img"
SCRATCH="$ROOT/docs/.scratch"
TIMEOUT="${TIMEOUT:-240}"
DO_FLASH=1
KEEP_GOING=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-flash) DO_FLASH=0 ;;
    --keep-going) KEEP_GOING=1 ;;
    --timeout) TIMEOUT=$2; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$SCRATCH"
have_fb() { fastboot devices 2>/dev/null | grep -q .; }
have_adb() { adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; }
in_recovery() { adb devices -l 2>/dev/null | grep -q recovery; }
in_android() { adb devices -l 2>/dev/null | grep -q 'product:fog_eea'; }

wait_fb() {
  local n=$1 i
  for ((i = 0; i < n; i++)); do have_fb && return 0; sleep 1; done
  return 1
}

log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- 1. get to fastboot -----------------------------------------------------
if ! have_fb; then
  if in_recovery || in_android; then
    log "adb device present -> reboot bootloader"
    adb reboot bootloader 2>/dev/null
  fi
  wait_fb 60 || { log "FAIL: no fastboot device (power-cycle needed)"; exit 2; }
fi
log "fastboot: $(fastboot devices | awk '{print $1}')"

# --- 2. flash ---------------------------------------------------------------
if [ "$DO_FLASH" -eq 1 ]; then
  log "flashing boot_b ($(basename "$BOOT_IMG"))"
  fastboot flash boot_b "$BOOT_IMG" >/dev/null 2>&1 || { log "FAIL: boot_b"; exit 3; }
  if [ -f "$CUST_IMG" ] && [ "${SKIP_CUST:-0}" != "1" ]; then
    log "flashing cust ($(basename "$CUST_IMG"))"
    fastboot flash cust "$CUST_IMG" >/dev/null 2>&1 || log "WARN: cust flash failed"
  fi
fi

# --- 2b. make sure slot B is actually the boot target ----------------------
# ABL gives slot B 7 attempts (slot-retry-count). Every boot that dies before
# userspace burns one; at 0 the slot is marked unbootable and ABL silently
# boots Android instead. Re-activating resets the counter — note that
# --set-active=b also reboots straight into slot B, so it has to come after
# the flash and takes the place of "fastboot reboot".
retry=$(fastboot getvar slot-retry-count:b 2>&1 | head -1 | sed 's/.*: //')
unbt=$(fastboot getvar slot-unbootable:b 2>&1 | head -1 | sed 's/.*: //')
cur=$(fastboot getvar current-slot 2>&1 | head -1 | sed 's/.*: //')
log "slot: current=${cur:-?} retry=${retry:-?} unbootable=${unbt:-?}"
need_active=0
[ "$cur" != "b" ] && need_active=1
[ "$unbt" = "yes" ] && need_active=1
case "${retry:-0}" in ''|*[!0-9]*) ;; *) [ "$retry" -le 1 ] && need_active=1 ;; esac
if [ "$need_active" -eq 1 ]; then
  log "re-activating slot B (resets retry counter)"
  fastboot --set-active=b >/dev/null 2>&1 || log "WARN: set-active failed"
fi

# --- 3. boot and wait for the phone to come back to fastboot ----------------
# --set-active does NOT reboot on this ABL, so always reboot explicitly.
log "rebooting slot B; waiting up to ${TIMEOUT}s for self-reboot to fastboot"
fastboot reboot >/dev/null 2>&1 || log "WARN: reboot command failed"

# A return only counts after the bootloader has actually gone away once;
# otherwise the still-present fastboot interface looks like a success.
gone=0
for i in $(seq 1 25); do
  have_fb || { gone=1; break; }
  sleep 1
done
[ "$gone" -eq 0 ] && log "WARN: fastboot never dropped (reboot did not take effect)"
sleep 12
start=$(date +%s)
returned=0
while :; do
  now=$(date +%s); elapsed=$((now - start))
  [ "$elapsed" -ge "$TIMEOUT" ] && break
  if have_fb; then returned=1; break; fi
  if in_android; then log "ANDROID fallback: slot B boot failed (retry counter exhausted)"; break; fi
  sleep 3
done

if [ "$returned" -eq 1 ]; then
  log "phone returned to fastboot on its own (autoreboot worked)"
else
  log "WARN: did not return to fastboot within ${TIMEOUT}s"
fi

# --- 4. pull the report via PBRP -------------------------------------------
# Drop stale copies first: the image itself ships an old report from build
# time, and pulling that would look like a fresh one.
rm -f "$SCRATCH/rain-boot-report.txt" "$SCRATCH/rain-dmesg.txt"
if have_fb; then
  log "RAM-booting PBRP to read cust"
  for try in 1 2 3; do
    fastboot boot "$PBRP" >/dev/null 2>&1
    sleep 20
    in_recovery && break
    if in_android; then adb reboot bootloader 2>/dev/null; wait_fb 40; fi
  done
  if in_recovery; then
    adb shell 'mkdir -p /cust && mount -t ext4 -o ro /dev/block/sda8 /cust' 2>/dev/null
    adb pull /cust/var/log/rain-boot-report.txt "$SCRATCH/rain-boot-report.txt" >/dev/null 2>&1 \
      && log "pulled rain-boot-report.txt"
    adb pull /cust/var/log/rain-dmesg.txt "$SCRATCH/rain-dmesg.txt" >/dev/null 2>&1 \
      && log "pulled rain-dmesg.txt"
    adb shell 'umount /cust' 2>/dev/null
  else
    log "WARN: could not enter PBRP to pull logs"
  fi
fi

# --- 5. summary -------------------------------------------------------------
if [ -f "$SCRATCH/rain-boot-report.txt" ]; then
  echo "----- report summary -----"
  grep -E '^(udc state|usb-gadget)|DSTS|GSNPSID|PHY6c' "$SCRATCH/rain-boot-report.txt" | head -8
  echo "--------------------------"
fi
exit 0
