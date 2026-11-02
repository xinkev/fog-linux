#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Apply the fog-EU deltas to upstream v7.3.0's sm6225-xiaomi-fog.dts.

Upstream's DTS is written for their `rain` unit (board-id 0x60022) and uses
the USB HS-PHY wiring that our `fog` unit rejected in the 7.1.5 tree:
`vdda-pll` bound to PM6125 L12 (1.8 V class) and `cfg_ahb` claimed from a
GCC driver that this "thin" DT never registers.

What this script changes (per-delta idempotent, asserts on unexpected input):

  * qcom,board-id 0x60022 -> 0x40022
  * usb_hsphy: xo_board ref only, PM6125 L4 (0.88 V) as vdda-pll,
    L12 as vdda18, L15 as vdda33, GCC_QUSB2PHY_PRIM_BCR reset
  * pm6125_l12 pinned 1.8 V, pm6125_l15 pinned 3.232 V (SPMI settles at min)
  * wlan local-mac-address -> $WLAN_MAC (our unit's factory MAC)

The MAC comes from the environment, never from this repo (MACs are per-unit
and not repo material). The Makefile exports WLAN_MAC from the gitignored
`device.local.mk`; without it the upstream MAC is left in place with a note.

Usage: WLAN_MAC=aa:bb:cc:dd:ee:ff tools/v730-fog-dts.py <dts>
"""

import os
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


def sub_once(src, old, new, what):
    """Replace `old` with `new` once; no-op if already applied."""
    if old in src:
        return src.replace(old, new, 1), True
    if new in src:
        return src, False
    fail(f"{what}: expected text not found (neither original nor replacement)")
    return src, False


def main():
    if len(sys.argv) != 2:
        fail("usage: v730-fog-dts.py <sm6225-xiaomi-fog.dts>")
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        src = f.read()

    changed = []

    # 1. board-id: ours is the fog/EEA variant
    src, did = sub_once(src, "qcom,board-id = <0x60022 0x00>;",
                        "qcom,board-id = <0x40022 0x00>;", "board-id")
    if did:
        changed.append("board-id 0x40022")

    # 2. usb_hsphy node -> the block proven on this unit
    if '&usb_hsphy {\n\tcompatible = "qcom,usb-snps-femto-v2-phy";' not in src:
        m = re.search(r"&usb_hsphy \{.*?\n\};\n", src, re.S)
        if not m:
            fail("&usb_hsphy node not found")
        src = src[:m.start()] + USB_NODE.format(mark=MARK) + src[m.end():]
        changed.append("HS-PHY rails (L4 0.88 V, L12 1.8 V, L15 3.232 V)")

    # 3. L12 pinned 1.8 V
    src, did = sub_once(
        src,
        "pm6125_l12a: l12 {\n"
        "\t\t\tregulator-min-microvolt = <1624000>;\n"
        "\t\t\tregulator-max-microvolt = <1984000>;\n"
        "\t\t};",
        "pm6125_l12a: l12 {\n"
        "\t\t\t/* " + MARK + ": SPMI inits at min; pin 1.8 V */\n"
        "\t\t\tregulator-min-microvolt = <1800000>;\n"
        "\t\t\tregulator-max-microvolt = <1800000>;\n"
        "\t\t};",
        "pm6125_l12a")
    if did:
        changed.append("L12 pinned 1.8 V")

    # 4. L15 pinned 3.232 V
    src, did = sub_once(
        src,
        "pm6125_l15a: l15 {\n"
        "\t\t\tregulator-min-microvolt = <2920000>;\n"
        "\t\t\tregulator-max-microvolt = <3232000>;\n"
        "\t\t};",
        "pm6125_l15a: l15 {\n"
        "\t\t\t/* " + MARK + ": SPMI inits at min; pin 3.232 V */\n"
        "\t\t\tregulator-min-microvolt = <3232000>;\n"
        "\t\t\tregulator-max-microvolt = <3232000>;\n"
        "\t\t};",
        "pm6125_l15a")
    if did:
        changed.append("L15 pinned 3.232 V")

    # 5. WLAN MAC: upstream hardcodes THEIR unit's factory MAC in the DTS.
    mac = os.environ.get("WLAN_MAC", "").strip().lower()
    m = re.search(r"local-mac-address = \[([0-9a-f :]+)\];", src)
    if not m:
        fail("local-mac-address property not found in the DTS")
    if mac:
        parts = mac.split(":")
        if len(parts) != 6 or any(not re.fullmatch(r"[0-9a-f]{2}", p) for p in parts):
            fail(f"WLAN_MAC={mac!r} is not AA:BB:CC:DD:EE:FF")
        hexs = " ".join(parts)
        if m.group(1).split() != hexs.split():
            src = src[:m.start()] + f"local-mac-address = [{hexs}];" + src[m.end():]
            changed.append(f"wlan MAC {mac}")
    else:
        print("v730-fog-dts: WLAN_MAC unset — leaving the DTS MAC "
              f"({m.group(1)}), set it in device.local.mk")

    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
        print(f"{path}: applied " + ", ".join(changed))
    else:
        print(f"{path}: already up to date")


if __name__ == "__main__":
    main()
