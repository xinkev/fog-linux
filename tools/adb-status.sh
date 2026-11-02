#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# What is adb actually talking to, and how do I use it?
#
# `--check` is the machine-readable gate used by tools/testboot-loop.sh:
#   0  the 26.04 `fog` image is up (adb serial `fog`, kernel 7.3)
#   1  adb is up but it is not that image (legacy `rain` rootfs, other kernel)
#   2  no adb device
#   3  adb has the device but not in state `device` (unauthorized/offline)
# Override with EXPECT_SERIAL= and EXPECT_KVER= (prefix match on uname -r).
# 7.1.5 is NOT good enough: the legacy slot-B rootfs runs 7.1.5 too.
set -uo pipefail

EXPECT_SERIAL="${EXPECT_SERIAL:-fog}"
EXPECT_KVER="${EXPECT_KVER:-7.3}"

if [ "${1:-}" = "--check" ]; then
    state=$(adb devices 2>/dev/null | awk 'NR>1 && NF {print $2; exit}')
    serial=$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1; exit}')
    [ -n "$state" ] || { echo "no adb device"; exit 2; }
    [ "$state" = "device" ] || { echo "adb state=$state"; exit 3; }
    [ "$serial" = "$EXPECT_SERIAL" ] || {
        echo "adb serial=$serial, expected $EXPECT_SERIAL (legacy rootfs or another phone?)"
        exit 1
    }
    kver=$(adb shell uname -r 2>/dev/null | tr -d '\r')
    case "$kver" in
        "$EXPECT_KVER"*) echo "fog on Linux $kver"; exit 0 ;;
    esac
    echo "adb serial=$serial but kernel is '$kver', expected $EXPECT_KVER.x"
    exit 1
fi

echo "=== adb state ==="
adb devices -l 2>/dev/null || true

state=$(adb devices 2>/dev/null | awk 'NR>1 && NF {print $2; exit}')
if [ -z "$state" ]; then
    if fastboot devices 2>/dev/null | grep -q .; then
        echo "phone: fastboot (bootloader)"
        echo "  -> flash/boot: make test SKIP_CUST=1"
    else
        echo "phone: not on adb or fastboot"
        echo "  -> power on, or hold Vol-Down + Power for fastboot"
    fi
    exit 0
fi

if [ "$state" != "device" ]; then
    echo "phone: adb state=$state"
    case "$state" in
        recovery)
            echo "  -> PBRP recovery (RAM boot), not Linux"
            echo "  -> boot Linux: make test SKIP_CUST=1"
            ;;
        unauthorized)
            echo "  -> adbd needs this host's key: make rootfs, then reboot"
            ;;
        *)
            echo "  -> wait/unplug; see RUNBOOK 'Diagnosing a failed boot'"
            ;;
    esac
    exit 0
fi

kver=$(adb shell uname -r 2>/dev/null | tr -d '\r')
case "$kver" in
    7.*)
        echo "phone: Linux ($kver) — adb shell is root"
        ;;
    *)
        echo "phone: recovery/Android ($kver) — NOT the Linux port"
        echo "  -> boot Linux: make test SKIP_CUST=1"
        exit 0
        ;;
esac

cat <<'EOF'

=== cookbook ===
adb shell 'uname -a; id'              root shell on fog-ubuntu (1000 = user fog)
adb shell dmesg -w                    live kernel log
adb pull /var/log/rain-boot-report.txt
adb push file /usr/local/sbin/        userspace edits need no cust reflash
adb forward tcp:2222 tcp:22           with: adb shell systemctl enable --now ssh
adb exec-out cat /dev/fb0 > screen.raw
adb shell rm /etc/rain-autoreboot     stop the 45 s self-reboot
adb reboot bootloader                 back to fastboot

The image self-reboots 45 s after its boot report unless the flag is removed.
adbd here reports "authentication not required"; the host key is a fallback.
`make adb` never flashes or changes the phone.
EOF
