#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Autonomous test-boot loop for the Redmi 10C (fog).
#
# RAM boot (the default for the v7.3.0 image) writes no slot: boot the image,
# wait for adb, gate on the identity, capture the checks, return to fastboot.
# The legacy slot-B path flashes boot_b + cust, boots, and waits for the phone
# to reboot itself back to fastboot (rain-autoreboot.service).
#
# Usage: tools/testboot-loop.sh [--no-flash] [--keep-going] [--timeout SEC]
#
# Exit: 0 booted (identity gate passed), 2 no fastboot, 3 flash/boot refused,
#       4 boot did not complete, 5 adb came up but not as the fog image.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$ROOT/Redmi10c-base"
OUT="$BASE/out/ubuntu-dualboot"
V730_BOOT="$ROOT/Redmi10c-base/v730/rootfs/out/boot-linux.img"
BOOT_IMG="${BOOT_IMG:-$([ -f "$V730_BOOT" ] && echo "$V730_BOOT" || echo "$OUT/boot-linux.img")}"
CUST_IMG="${CUST_IMG:-$(dirname "$BOOT_IMG")/linux_rootfs.sparse.img}"
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

# systemd's /sbin/reboot cannot pass a reboot reason, so plain
# `adb reboot bootloader` just does a normal reboot on the 26.04 rootfs.
# The static helper issues reboot(2) with LINUX_REBOOT_CMD_RESTART2,
# which ABL honours.
reboot_to_fastboot() {
  local h="$ROOT/build/overlay/usr/local/sbin/rain-reboot-bootloader"
  if [ -f "$h" ] && adb push "$h" /tmp/rrb >/dev/null 2>&1; then
    adb shell 'chmod 755 /tmp/rrb; /tmp/rrb bootloader' >/dev/null 2>&1
  else
    adb reboot bootloader 2>/dev/null
  fi
}

# --- RAM-boot mode (default for the v7.3.0 image) ---------------------------
# Writes no slot and cannot burn the slot-retry counter. There is no
# rain-autoreboot in the 26.04 rootfs, so the loop returns the phone to
# fastboot itself.
run_ram_boot() {
  local i st
  if ! have_fb; then
    if have_adb; then
      log "linux/adb device present -> reboot bootloader"
      reboot_to_fastboot
    fi
    wait_fb 60 || { log "FAIL: no fastboot device (power-cycle needed)"; return 2; }
  fi
  log "RAM boot $(basename "$BOOT_IMG") ($(du -h "$BOOT_IMG" | cut -f1))"
  fastboot boot "$BOOT_IMG" >/dev/null 2>&1 || { log "FAIL: fastboot boot refused"; return 3; }

  log "waiting up to ${TIMEOUT}s for adb"
  st=""
  for ((i = 0; i < TIMEOUT; i += 3)); do
    sleep 3
    st=$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1; exit}')
    [ -n "$st" ] && break
  done
  if [ -z "$st" ]; then
    log "FAIL: no adb after ${TIMEOUT}s (kernel or userspace did not come up)"
    return 4
  fi
  log "adb up: $st"

  # A boot only counts if it is the 26.04 fog image. Anything else on adb
  # (a legacy `rain` rootfs, a wrong kernel, another phone) used to pass as
  # "booted"; that hides exactly the regressions this loop exists to catch.
  if ! check=$("$ROOT/tools/adb-status.sh" --check); then
    log "FAIL: adb is up but not the fog 26.04 image: $check"
    {
      echo "identity check failed: $check"
      adb devices -l
      adb shell 'uname -a; hostname; id' 2>&1
    } >"$SCRATCH/adb-check.txt" 2>&1
    log "wrote $SCRATCH/adb-check.txt; returning to fastboot"
    reboot_to_fastboot
    wait_fb 90 || log "WARN: did not return to fastboot"
    return 5
  fi
  log "identity: $check"

  {
    adb devices -l
    echo "--- identity ---"
    adb shell 'uname -r; grep PRETTY_NAME /etc/os-release; id; cat /sys/class/udc/*/state' 2>&1
    echo "--- systemd ---"
    adb shell 'systemctl is-system-running; systemctl --failed --no-legend' 2>&1
    echo "--- display ---"
    adb shell 'cat /sys/class/drm/card0-DSI-1/status; cat /sys/class/graphics/fb0/virtual_size' 2>&1
    echo "--- touch ---"
    adb shell 'grep -A1 fts_ts /proc/bus/input/devices; dmesg | grep -i fts | tail -3' 2>&1
    echo "--- wifi ---"
    adb shell 'ip -br link show wlan0; cat /sys/class/net/wlan0/address' 2>&1
  } >"$SCRATCH/adb-check.txt" 2>&1
  log "wrote $SCRATCH/adb-check.txt"

  log "returning to fastboot"
  reboot_to_fastboot
  wait_fb 90 || log "WARN: did not return to fastboot"
  return 0
}

# --- 0. RAM boot (default) or legacy slot flash ----------------------------
case "${RAM_BOOT:-auto}" in
  1) run_ram_boot; exit $? ;;
  0) ;;
  auto)
    if [ -f "$V730_BOOT" ] && [ "$(cd "$(dirname "$BOOT_IMG")" && pwd)/$(basename "$BOOT_IMG")" = "$V730_BOOT" ]; then
      run_ram_boot; exit $?
    fi ;;
esac

# --- 1. get to fastboot -----------------------------------------------------
if ! have_fb; then
  if have_adb; then
    log "adb device present -> reboot bootloader"
    reboot_to_fastboot
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
adb_hit=0
while :; do
  now=$(date +%s); elapsed=$((now - start))
  [ "$elapsed" -ge "$TIMEOUT" ] && break
  if have_fb; then returned=1; break; fi
  if in_android; then log "ANDROID fallback: slot B boot failed (retry counter exhausted)"; break; fi
  # A Linux-boot adbd shows up as device/unauthorized/offline. Capture it
  # before rain-autoreboot (45 s after the report) takes the phone away.
  if [ "$adb_hit" -eq 0 ] && ! in_recovery && ! in_android; then
    st=$(adb devices 2>/dev/null | awk 'NR>1 && NF {print $2; exit}')
    if [ -n "$st" ]; then
      adb_hit=1
      log "ADB DEVICE PRESENT state=$st"
      {
        adb devices -l
        echo "--- adb shell ---"
        adb shell 'uname -a; id; cat /sys/class/udc/*/state 2>/dev/null; ls -l /dev/usb-ffs/adb 2>/dev/null' 2>&1
      } >"$SCRATCH/adb-check.txt" 2>&1 &
      pid=$!
      for _ in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill "$pid" 2>/dev/null || true
      log "wrote $SCRATCH/adb-check.txt"
    fi
  fi
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
if [ -f "$SCRATCH/adb-check.txt" ]; then
  echo "----- adb check -----"
  cat "$SCRATCH/adb-check.txt"
  echo "---------------------"
fi
if [ -f "$SCRATCH/rain-boot-report.txt" ]; then
  echo "----- report summary -----"
  grep -E '^(udc state|usb-gadget|usb-adb-gadget|adbd|ffs|adb keys)|DSTS|GSNPSID|PHY6c' \
    "$SCRATCH/rain-boot-report.txt" | head -12
  echo "--------------------------"
fi

# Legacy slot-B path: coming back to fastboot is the only evidence that
# userspace ran (the 24.04 image reports then reboots itself). Do not exit 0
# on a boot that never got there — that is the regression this catches.
if [ "$returned" -eq 1 ]; then
  log "PASS: booted and returned to fastboot"
  exit 0
fi
if [ "$adb_hit" -eq 1 ]; then
  log "FAIL: adb appeared but the phone never returned to fastboot within ${TIMEOUT}s"
else
  log "FAIL: no adb and no return to fastboot within ${TIMEOUT}s"
fi
exit 4
