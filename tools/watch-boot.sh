#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Classify what the phone booted into, without a human watching the screen.
#
#   LINUX   - USB ACM gadget appeared; optionally probe it over serial
#   ANDROID - adb up with an Android fingerprint (ABL fell back to slot a)
#   FASTBOOT- bootloader came back
#   HUNG    - no signal at all after the timeout (needs a power cycle)
#
# Usage: tools/watch-boot.sh [--flash] [--reboot] [--timeout SEC] [--no-probe]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$ROOT/Redmi10c-base"
TIMEOUT=120
FLASH=0
REBOOT=0
PROBE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --flash) FLASH=1 ;;
    --reboot) REBOOT=1 ;;
    --no-probe) PROBE=0 ;;
    --timeout) TIMEOUT=$2; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

have_fb() { fastboot devices 2>/dev/null | grep -q .; }
have_adb() { adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; }
serial_port() { ls /dev/cu.usbmodem* /dev/ttyACM* 2>/dev/null | head -n 1; }

if [ "$FLASH" -eq 1 ]; then
  have_fb || { echo "FAIL: no fastboot device (power-cycle to bootloader first)"; exit 2; }
  set -e
  fastboot erase dtbo_b >/dev/null
  fastboot flash boot_b "$BASE/out/ubuntu-dualboot/boot-linux.img" >/dev/null
  fastboot flash vbmeta_b "$BASE/out/ubuntu-dualboot/vbmeta_b.img" >/dev/null
  fastboot flash cust "$BASE/out/ubuntu-dualboot/linux_rootfs.sparse.img" >/dev/null
  fastboot --set-active=b >/dev/null
  set +e
fi

if [ "$REBOOT" -eq 1 ]; then
  if have_fb; then fastboot reboot >/dev/null; fi
fi

# Ignore fastboot for a few seconds: after `reboot` it lingers briefly.
start=$(date +%s)
grace=10
while :; do
  now=$(date +%s); elapsed=$((now - start))
  [ "$elapsed" -ge "$TIMEOUT" ] && break

  port=$(serial_port)
  if [ -n "$port" ]; then
    echo "LINUX serial=$port t=${elapsed}s"
    if [ "$PROBE" -eq 1 ]; then
      python3 "$ROOT/tools/serial-probe.py" "$port" --timeout 2 \
        'uname -r' 'cat /etc/os-release | head -2' 'ls /sys/class/udc' \
        | sed 's/^/  | /'
    fi
    exit 0
  fi

  if [ "$elapsed" -ge "$grace" ]; then
    if have_adb; then
      prod=$(adb shell getprop ro.product.device 2>/dev/null | tr -d '\r')
      rel=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
      echo "ANDROID product=${prod:-?} android=${rel:-?} t=${elapsed}s"
      exit 1
    fi
    if have_fb; then
      echo "FASTBOOT t=${elapsed}s"
      exit 2
    fi
  fi
  sleep 2
done

echo "HUNG no usb/adb/fastboot after ${TIMEOUT}s"
exit 3
