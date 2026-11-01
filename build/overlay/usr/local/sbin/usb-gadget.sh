#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Bind the Qualcomm DWC3 UDC as a CDC-ACM (serial) gadget so the host gets
# /dev/cu.usbmodem* without a keyboard attached to the phone.
#
# The initramfs binds the gadget and keeps it bound across switch_root, but
# the controller comes out of that transition halted (DCTL.RUN_STOP = 0,
# udc state = "not attached", DSTS.USBLNKST = 3), so the host never sees it.
# Re-binding is supposed to re-run dwc3_gadget_pullup() -> run_stop = 1, but a
# naive unbind/rebind failed half-way and left the gadget unbound. So: no
# set -e, log every step, retry the bind, and dump the controller around it.
CFG=/sys/kernel/config
G="$CFG/usb_gadget/g1"

msg() { echo "usb-gadget: $*" >/dev/kmsg 2>/dev/null || true; }

dump() {
    python3 -u - "$1" <<'PYEOF' 2>&1 || true
import mmap, os, struct, sys
PAGE = 4096
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
def rd(a):
    b = a & ~(PAGE - 1)
    mm = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, mmap.PROT_READ, offset=b)
    try:
        return struct.unpack("<I", mm[a - b:a - b + 4])[0]
    finally:
        mm.close()
dctl, dsts = rd(0x04E0C704), rd(0x04E0C70C)
try:
    udc = open("/sys/kernel/config/usb_gadget/g1/UDC").read().strip() or "(empty)"
except Exception as e:
    udc = "?%s" % e
try:
    st = open("/sys/class/udc/4e00000.usb/state").read().strip()
except Exception as e:
    st = "?%s" % e
print("usb-gadget[%s]: DCTL=0x%08x RUN_STOP=%d DSTS=0x%08x USBLNKST=%d udc=%s state=%s"
      % (sys.argv[1], dctl, (dctl >> 31) & 1, dsts, (dsts >> 18) & 0xf, udc, st))
PYEOF
}

mountpoint -q "$CFG" || mount -t configfs none "$CFG" 2>/dev/null
UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
if [ -z "$UDC" ]; then
    msg "no UDC in /sys/class/udc"
    exit 1
fi

dump before

if [ -s "$G/UDC" ]; then
    msg "inherited binding $(cat "$G/UDC") -> unbinding to force a restart"
    echo "" >"$G/UDC"
    sleep 1
    dump after-unbind
fi

mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409" "$G/functions/acm.usb0" 2>/dev/null
echo 0x1d6b >"$G/idVendor" 2>/dev/null
echo 0x0104 >"$G/idProduct" 2>/dev/null
echo rain >"$G/strings/0x409/serialnumber" 2>/dev/null
echo Xiaomi >"$G/strings/0x409/manufacturer" 2>/dev/null
echo rain-ubuntu >"$G/strings/0x409/product" 2>/dev/null
echo ACM >"$G/configs/c.1/strings/0x409/configuration" 2>/dev/null
echo 0xA0 >"$G/configs/c.1/bmAttributes" 2>/dev/null
ln -sfn "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0" 2>/dev/null

i=0
while [ $i -lt 4 ]; do
    i=$((i + 1))
    if echo "$UDC" >"$G/UDC" 2>/tmp/udc-err; then
        msg "bound $UDC (attempt $i)"
        break
    fi
    msg "bind attempt $i failed: $(cat /tmp/udc-err 2>/dev/null)"
    sleep 1
done

sleep 1
dump after-bind
