#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Re-apply the Redmi 10C USB PHY/GDSC/QSCRATCH pokes from userspace.

The repo's proven sequence lives in pivot-init (initramfs), but with the
dwc3-qcom glue driver bound those writes can be undone. Run this again right
before binding the UDC, then let usb-gadget.service bind.
"""
import mmap
import os
import struct
import sys
import time

PAGE = 4096


class Mem:
    def __init__(self):
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)

    def _map(self, addr):
        base = addr & ~(PAGE - 1)
        mm = mmap.mmap(self.fd, PAGE, mmap.MAP_SHARED,
                       mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        return mm, addr - base

    def rd(self, addr):
        mm, off = self._map(addr)
        try:
            return struct.unpack("<I", mm[off:off + 4])[0]
        finally:
            mm.close()

    def wr(self, addr, val):
        mm, off = self._map(addr)
        try:
            mm[off:off + 4] = struct.pack("<I", val & 0xFFFFFFFF)
        finally:
            mm.close()

    def rmw(self, addr, clr, set_):
        cur = self.rd(addr)
        self.wr(addr, (cur & ~clr) | set_)


def main() -> int:
    m = Mem()

    # USB3 PHY / QMP power-up (same order as pivot-init usb_phy_init)
    m.rmw(0x0141A004, 0x1, 0x0)
    for _ in range(10):
        if (m.rd(0x0141A004) >> 31) & 1:
            break
        time.sleep(1)
    m.wr(0x0141A014, 0x1)
    m.wr(0x0141A010, 0x1)
    m.wr(0x0141A018, 0x1)
    m.wr(0x0141D000, 0x0)
    m.wr(0x0141D008, 0x3)

    # QSCRATCH: UTMI-as-pipe + VBUS_VALID
    m.rmw(0x04EF8808, 0x0, 0x100)
    time.sleep(0.3)
    m.rmw(0x04EF8808, 0x0, 0x9)
    time.sleep(0.3)
    m.rmw(0x04EF8808, 0x100, 0x0)
    m.rmw(0x04EF8810, 0x0, 0x10100000)
    m.rmw(0x04EF8830, 0x0, 0x01000000)

    # Khaje HS PHY param overrides
    m.wr(0x0161306C, 0x61)
    m.wr(0x01613070, 0x08)
    m.wr(0x01613074, 0x2D)

    # USB GDSC
    m.rmw(0x04E0C200, 0x140, 0x0)

    # NOTE: do not touch DCTL here. The old sequence cleared DWC3_DCTL_RUN_STOP
    # (bit 31) and set it again to "hand control back to the driver", but the
    # gadget is already bound at this point: stopping the controller behind
    # dwc3's back leaves its event ring stale, which shows up as an endless
    # "dwc3: unknown endpoint event 0" storm and a device the host cannot
    # enumerate. Read only.
    print("usb-force: DCTL=0x%08x RUN_STOP=%d" % (m.rd(0x04E0C704),
          (m.rd(0x04E0C704) >> 31) & 1))

    # Report the controller ID: 0x5533xxxx means the block is clocked/alive.
    print("GSNPSID=0x%08x GCTL=0x%08x QSCRATCH08=0x%08x QSCRATCH10=0x%08x "
          "GDSC704=0x%08x PHY6c=0x%08x" % (
              m.rd(0x04E00000), m.rd(0x04E00004),
              m.rd(0x04EF8808), m.rd(0x04EF8810),
              m.rd(0x04E0C704), m.rd(0x0161306C)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
