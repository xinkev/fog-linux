#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Put the phone into fastboot from whatever it is running right now.
#
# WHY THIS EXISTS: `adb reboot bootloader` does NOT work from the Ubuntu 26.04
# rootfs. systemd's /sbin/reboot calls reboot(2) without a reason string, so
# ABL just does a normal reboot (into whichever slot is active). Android's init
# passes LINUX_REBOOT_CMD_RESTART2 "bootloader", which is why the same command
# works there. The static aarch64 helper in build/overlay/usr/local/sbin/
# issues that syscall directly; this script pushes it, runs it, and waits for
# fastboot. Use this instead of adb's reboot.
#
# Usage: tools/to-bootloader.sh     (or: make bootloader)
# Exit:  0 in fastboot, 2 no usable device, 3 helper push/build failed,
#        4 no fastboot within the timeout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/overlay/usr/local/sbin/rain-reboot-bootloader.c"
HELPER="$ROOT/build/overlay/usr/local/sbin/rain-reboot-bootloader"
TIMEOUT="${TIMEOUT:-90}"

log() { echo "to-bootloader: $*"; }

have_fb() { fastboot devices 2>/dev/null | grep -q .; }
wait_fb() {
  local n=$1 i
  for ((i = 0; i < n; i++)); do have_fb && return 0; sleep 1; done
  return 1
}

ensure_helper() {
  [ -x "$HELPER" ] && return 0
  log "helper binary missing — building it in the fog-v730 container"
  DOCKER_CONFIG="$ROOT/.docker" docker run --rm --platform linux/arm64 \
    -v "$ROOT":/src -w /src fog-v730:latest \
    gcc -static -O2 -s -o build/overlay/usr/local/sbin/rain-reboot-bootloader \
    build/overlay/usr/local/sbin/rain-reboot-bootloader.c >/dev/null 2>&1
  [ -x "$HELPER" ] || { log "could not build $HELPER (need docker + fog-v730 image)"; return 1; }
}

if have_fb; then
  log "already in fastboot"
  exit 0
fi

state=$(adb devices 2>/dev/null | awk 'NR>1 && NF {print $2; exit}')
if [ -z "$state" ]; then
  log "no adb and no fastboot device — power on, or hold Vol-Down + Power"
  exit 2
fi
if [ "$state" != "device" ] && [ "$state" != "recovery" ]; then
  log "adb state=$state — accept the debugging prompt / fix adb, or power-cycle to fastboot"
  exit 2
fi

if [ "$state" = "recovery" ]; then
  # PBRP's ramdisk reboot honours the reason just fine.
  log "recovery: adb reboot bootloader"
  adb reboot bootloader 2>/dev/null
else
  kver=$(adb shell uname -r 2>/dev/null | tr -d '\r')
  case "$kver" in
    7.*)
      ensure_helper || exit 3
      log "Linux $kver: reboot(2) with reason 'bootloader'"
      adb push "$HELPER" /tmp/rrb >/dev/null 2>&1 || { log "adb push failed"; exit 3; }
      adb shell 'chmod 755 /tmp/rrb; /tmp/rrb bootloader' >/dev/null 2>&1
      ;;
    *)
      # Android/stock: init supplies the reason itself.
      log "Android/recovery ($kver): adb reboot bootloader"
      adb reboot bootloader 2>/dev/null
      ;;
  esac
fi

if wait_fb "$TIMEOUT"; then
  log "in fastboot ($(fastboot devices | awk '{print $1}'))"
  exit 0
fi
log "no fastboot after ${TIMEOUT}s"
exit 4
