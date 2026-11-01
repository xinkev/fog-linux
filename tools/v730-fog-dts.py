#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Apply the fog-EU deltas to upstream v7.3.0's sm6225-xiaomi-fog.dts.

Upstream's DTS is written for their `rain` unit (board-id 0x60022) and uses
the USB HS-PHY wiring that our `fog` unit rejected in the 7.1.5 tree:
`vdda-pll` bound to PM6125 L12 (1.8 V class) and `cfg_ahb` claimed from a
GCC driver that this "thin" DT never registers.

What this script changes (idempotent, asserts on unexpected input):

  * qcom,board-id 0x60022 -> 0x40022
  * usb_hsphy: xo_board ref only, PM6125 L4 (0.88 V) as vdda-pll,
    L12 as vdda18, L15 as vdda33, GCC_QUSB2PHY_PRIM_BCR reset
  * pm6125_l12 pinned 1.8 V, pm6125_l15 pinned 3.232 V (SPMI settles at min)

Usage: tools/v730-fog-dts.py <path-to-sm6225-xiaomi-fog.dts>
"""

import re
import sys

MARK = "fog-EU deltas"

USB_NODE = """/*
 * {mark}: our unit's downstream DT gives the HS PHY vdd=pm6125_l4 (0.88 V),
 * vdda18=l12 (1.8 V), vdda33=l15 (3.232 V).  Upstream binds vdda-pll to l12
 * as well and claims cfg_ahb from GCC; on this board that leaves the PHY core
 * without its 0.88 V rail and clk_get() on cfg_ahb returns NULL.  The femto
 * driver force-enables the GCC USB clocks over MMIO, so "ref" is enough.
 */
&usb_hsphy {{
\tcompatible = "qcom,usb-snps-femto-v2-phy";
\tclocks = <&xo_board>;
\tclock-names = "ref";
\tresets = <&gcc GCC_QUSB2PHY_PRIM_BCR>;
\tvdda-pll-supply = <&pm6125_l4a>;
\tvdda18-supply = <&pm6125_l12a>;
\tvdda33-supply = <&pm6125_l15a>;
\t/delete-property/ nvmem-cells;
\t/delete-property/ nvmem-cell-names;
\t/delete-property/ vdd-supply;
\t/delete-property/ vdda-phy-dpdm-supply;
\tstatus = "okay";
}};
"""


def fail(msg):
    sys.exit(f"v730-fog-dts: {msg}")


def main():
    if len(sys.argv) != 2:
        fail("usage: v730-fog-dts.py <sm6225-xiaomi-fog.dts>")
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        src = f.read()

    if MARK in src:
        print(f"{path}: already patched")
        return

    # 1. board-id
    if "qcom,board-id = <0x60022 0x00>;" not in src:
        fail("expected qcom,board-id = <0x60022 0x00> not found")
    src = src.replace("qcom,board-id = <0x60022 0x00>;",
                      "qcom,board-id = <0x40022 0x00>;", 1)

    # 2. usb_hsphy node -> our proven block
    m = re.search(r"&usb_hsphy \{.*?\n\};\n", src, re.S)
    if not m:
        fail("&usb_hsphy node not found")
    src = src[:m.start()] + USB_NODE.format(mark=MARK) + src[m.end():]

    # 3. L12 pinned 1.8 V
    old_l12 = ("pm6125_l12a: l12 {\n"
               "\t\t\tregulator-min-microvolt = <1624000>;\n"
               "\t\t\tregulator-max-microvolt = <1984000>;\n"
               "\t\t};")
    new_l12 = ("pm6125_l12a: l12 {\n"
               "\t\t\t/* " + MARK + ": SPMI inits at min; pin 1.8 V */\n"
               "\t\t\tregulator-min-microvolt = <1800000>;\n"
               "\t\t\tregulator-max-microvolt = <1800000>;\n"
               "\t\t};")
    if old_l12 not in src:
        fail("expected pm6125_l12a block not found")
    src = src.replace(old_l12, new_l12, 1)

    # 4. L15 pinned 3.232 V
    old_l15 = ("pm6125_l15a: l15 {\n"
               "\t\t\tregulator-min-microvolt = <2920000>;\n"
               "\t\t\tregulator-max-microvolt = <3232000>;\n"
               "\t\t};")
    new_l15 = ("pm6125_l15a: l15 {\n"
               "\t\t\t/* " + MARK + ": SPMI inits at min; pin 3.232 V */\n"
               "\t\t\tregulator-min-microvolt = <3232000>;\n"
               "\t\t\tregulator-max-microvolt = <3232000>;\n"
               "\t\t};")
    if old_l15 not in src:
        fail("expected pm6125_l15a block not found")
    src = src.replace(old_l15, new_l15, 1)

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print(f"{path}: applied board-id + HS-PHY + L12/L15 deltas")


if __name__ == "__main__":
    main()
