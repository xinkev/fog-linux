#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Write full USB/gadget diagnostics to /var/log/ so they can be pulled from
# cust via PBRP (adb) without a serial console. Compact copy on VT 2.
#
# The register section is ordered safest-first: everything the PHY and glue
# drivers already map (0x1613000, 0x4ef8800), then the unclaimed blocks
# (EUD 0x1611000 / mode-mgr 0x1612000) last, after a sync, so a bus fault on
# those cannot cost us the rest of the report.
LOG=/var/log/rain-boot-report.txt
FULL=/var/log/rain-dmesg.txt
{
    echo "================ rain boot report ================"
    echo "kernel: $(uname -r)"
    echo "udc: [$(ls /sys/class/udc 2>/dev/null | tr '\n' ' ')]"
    echo "udc state: [$(cat /sys/class/udc/*/state 2>/dev/null)]"
    echo "gadget UDC: [$(cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null)]"
    echo "ttyGS: [$(ls /dev/ttyGS* 2>/dev/null | tr '\n' ' ')]"
    echo "usb-gadget: $(systemctl is-active usb-gadget.service 2>/dev/null)"
    echo "gettyGS0:   $(systemctl is-active getty@ttyGS0.service 2>/dev/null)"
    echo "endpoint-event spam: $(dmesg 2>/dev/null | grep -c "unknown endpoint event")"

    echo "--- regulators (usb-relevant) ---"
    for r in /sys/class/regulator/regulator.*; do
        [ -d "$r" ] || continue
        n=$(cat "$r/name" 2>/dev/null)
        case "$n" in
            *usb*|*l12*|*l15*|*vdda*|*vdd*) ;;
            *) continue ;;
        esac
        echo "$(basename "$r") $n state=$(cat "$r/state" 2>/dev/null) uV=$(cat "$r/microvolts" 2>/dev/null)"
    done

    echo "--- registers (python) ---"
    echo "python3: $(command -v python3 || echo MISSING)"
    echo "devmem node: $(ls -l /dev/mem 2>&1)"
    PYTHONUNBUFFERED=1 python3 -u - <<'PYEOF' 2>/tmp/rain-python.err
import faulthandler, mmap, os, struct, sys
faulthandler.enable()
PAGE = 4096
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
def rd(addr):
    base = addr & ~(PAGE - 1)
    mm = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    try:
        return struct.unpack("<I", mm[addr - base:addr - base + 4])[0]
    finally:
        mm.close()

def dump(title, regs):
    print("--- %s ---" % title, flush=True)
    for name, addr in regs:
        try:
            print("%-16s @0x%08x = 0x%08x" % (name, addr, rd(addr)), flush=True)
        except Exception as e:
            print("%-16s @0x%08x EXC %s" % (name, addr, e), flush=True)

DUMP = [("GSNPSID", 0x04E0C120), ("GCTL", 0x04E0C110),
        ("GUSB2PHYCFG", 0x04E0C200), ("GUSB3PIPECTL", 0x04E0C2C0),
        ("GEVNTADRLO", 0x04E0C400), ("GEVNTADRHI", 0x04E0C404),
        ("GEVNTSIZ", 0x04E0C408), ("GEVNTCNT", 0x04E0C40C),
        ("DCTL", 0x04E0C704), ("DSTS", 0x04E0C70C)]
dump("dwc3 core", DUMP)

# QSCRATCH: 0x4ef8800 is mapped by dwc3-qcom for 0x400 bytes.
dump("qscratch (glue)", [
    ("GENERAL_CFG_08", 0x04EF8808), ("HS_PHY_CTRL_10", 0x04EF8810),
    ("SS_PHY_CTRL_30", 0x04EF8830), ("QSCRATCH00", 0x04EF8800),
    ("QSCRATCH04", 0x04EF8804), ("QSCRATCH0c", 0x04EF880C),
    ("QSCRATCH14", 0x04EF8814),
])

# Femto-v2 HS PHY: driver maps the 0x1613000 page, all of these are safe.
dump("usb hs phy (0x1613000)", [
    ("COMMON0_0x54", 0x01613054), ("COMMON1_0x58", 0x01613058),
    ("COMMON2_0x5c", 0x0161305c), ("CTRL1_0x60", 0x01613060),
    ("CTRL2_0x64", 0x01613064), ("OVERRIDE_X0", 0x0161306C),
    ("OVERRIDE_X1", 0x01613070), ("OVERRIDE_X2", 0x01613074),
    ("OVERRIDE_X3", 0x01613078), ("CFG0_0x94", 0x01613094),
    ("REFCLK_0xa0", 0x016130A0),
])

# Decode the two registers that actually decide "does the host see us".
dsts = rd(0x04E0C70C)
dctl = rd(0x04E0C704)
gctl = rd(0x04E0C110)
print("--- decode ---", flush=True)
print("DSTS.USBLNKST   = %d %s" % ((dsts >> 18) & 0xf,
      {0: "(on)", 3: "(disconnected)", 4: "(reset)"}.get((dsts >> 18) & 0xf, "")))
print("DSTS.DEVCTRLHLT = %d" % ((dsts >> 22) & 1))
print("DSTS.CONNECTSPD = 0x%x" % (dsts & 0x7))
# DWC3_DCTL_RUN_STOP is bit 31, not bit 0
print("DCTL.RUN_STOP   = %d" % ((dctl >> 31) & 1))
print("DCTL.ULSTCHNGREQ= %d" % ((dctl >> 9) & 0xf))
print("GCTL.PRTCAPDIR  = %d (2 = device)" % ((gctl >> 12) & 0x3))
print("GCTL.CORESOFTRESET = %d" % (gctl & 1))
print("ALL_DONE", flush=True)
PYEOF
    echo "--- python stderr ---"
    cat /tmp/rain-python.err 2>/dev/null || echo "(none)"

    echo "--- regulator summary (real voltages) ---"
    mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
    sed -n '1,40p' /sys/kernel/debug/regulator/regulator_summary 2>/dev/null || echo "(no regulator_summary)"

    echo "--- dmesg: phy/regulator/usb/rain (tail = late boot, where dwc3/femto live) ---"
    dmesg 2>/dev/null | grep -iE 'phy|regulator|usb|dwc3|gdsc|rain:|femto|1613000|qusb|ahb2phy' | tail -n 60
    echo "================================================="
    sync
} >"$LOG" 2>&1

# --- unclaimed blocks: EUD hijack check ------------------------------------
# Downstream DT: qcom,msm-eud@1610000 with reg = <0x1610000 0x2000>,
# <0x1612000 0x1000>, <0x3e5018 4> = eud_base / eud_mode_mgr2 / tcsr_check.
# Nothing in mainline maps these, so the read may fault (SError) and take the
# kernel down; the report above is already synced to cust by then.
{
    echo "--- eud hijack probe (risky: unclaimed MMIO) ---"
    echo "eud: reading base 0x1610000 ..."
    PYTHONUNBUFFERED=1 python3 -u - <<'PYEOF' 2>&1
import mmap, os, struct
PAGE = 4096
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
def rd(addr):
    base = addr & ~(PAGE - 1)
    mm = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    try:
        return struct.unpack("<I", mm[addr - base:addr - base + 4])[0]
    finally:
        mm.close()
# qcom_eud: CSR_EUD_EN 0x1014, SW_ATTACH_DET 0x1018; mode_mgr EUD_EN2 0x0
for name, addr in [("EUD_CSR_EUD_EN", 0x01611014), ("EUD_SW_ATTACH_DET", 0x01611018),
                   ("EUD_EN2(mode_mgr)", 0x01612000)]:
    v = rd(addr)
    print("%-18s @0x%08x = 0x%08x%s" % (name, addr, v,
          "   <-- EUD ENABLED: PHY is routed to the debug block" if (name.startswith("EUD_CSR") and v & 1) else ""), flush=True)
print("EUD_DONE", flush=True)
PYEOF
    echo "eud: probe returned"
    echo "================================================="
} >>"$LOG" 2>&1
sync

# Full unfiltered kernel log for offline analysis
dmesg >"$FULL" 2>/dev/null

# Compact screen copy: report body only (VTs truncate long lines anyway)
if [ -w /dev/tty2 ]; then
    printf '\033[2J\033[H' >/dev/tty2
    head -n 30 "$LOG" >/dev/tty2
    python3 - <<'EOF' || true
import fcntl, os
fd = os.open("/dev/tty0", os.O_RDWR | os.O_NOCTTY)
fcntl.ioctl(fd, 0x5606, 2)
os.close(fd)
EOF
fi
