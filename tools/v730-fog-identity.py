#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Rewrite upstream v7.3.0's `rain` identity strings to `fog` in the worktree.

Upstream (Damir00109/Redmi10c v7.3.0) targets a `rain` unit. Our phone is the
EEA `fog` SKU, so everything the outside world can see — USB iSerialNumber,
USB product string, hostname, login user, filesystem label, /etc/issue — says
`fog`/`fog-ubuntu`.

Deliberately NOT renamed: internal upstream names that its units and scripts
reference by path or unit name (`rain-overlay`, `rain-*.service`,
`rain-loc-tool`, the `/usr/share/qcom/sm6225/Xiaomi/rain` DSP firmware tree).
Renaming those would be a fork of upstream's unit set, not an identity fix.

Idempotent: an edit whose `old` text is gone and whose `new` text is present
counts as already applied. A file where neither appears means upstream moved
the line — that is an error, not a silent skip.

Usage: tools/v730-fog-identity.py [V730_DIR]
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_V730 = ROOT / "Redmi10c-base" / "v730"

BUILD = "rootfs/build-rootfs.sh"
PIVOT = "rootfs/tools/pivot-init"
GADGET = "rootfs/tools/rain-overlay/usr/local/sbin/usb-adb-gadget.sh"

# (file, old, new) — exact substrings, applied in order.
EDITS: list[tuple[str, str, str]] = [
    # --- rootfs identity: hostname, user, label, banner -------------------
    (BUILD, "echo 'rain-ubuntu' | sudo tee \"$RF/etc/hostname\"",
            "echo 'fog-ubuntu' | sudo tee \"$RF/etc/hostname\""),
    (BUILD, "10.0.0.2 rain-ubuntu", "10.0.0.2 fog-ubuntu"),
    (BUILD, "id rain >/dev/null 2>&1 || useradd -m -s /bin/bash "
            "-G sudo,netdev,video,plugdev,audio rain",
            "id fog >/dev/null 2>&1 || useradd -m -s /bin/bash "
            "-G sudo,netdev,video,plugdev,audio fog"),
    (BUILD, 'echo "rain:rain" | chpasswd', 'echo "fog:fog" | chpasswd'),
    (BUILD, 'echo "root:rain" | chpasswd', 'echo "root:fog" | chpasswd'),
    (BUILD, "touch /var/lib/systemd/linger/rain",
            "touch /var/lib/systemd/linger/fog"),
    (BUILD, "Ubuntu 26.04.1 LTS rain-ubuntu \\n \\l",
            "Ubuntu 26.04.1 LTS fog-ubuntu \\n \\l"),
    (BUILD, "sudo mkfs.ext4 -L rain-ubuntu -O ^metadata_csum_seed",
            "sudo mkfs.ext4 -L fog-ubuntu -O ^metadata_csum_seed"),
    (BUILD, "only /home/rain stays uid 1000", "only /home/fog stays uid 1000"),
    (BUILD, "! -path \"$MNT/home/rain*\"", "! -path \"$MNT/home/fog*\""),
    # --- pivot initramfs rescue gadget (ACM console before switch_root) ---
    (PIVOT, "GADGET_SERIAL=rain", "GADGET_SERIAL=fog"),
    (PIVOT, "GADGET_PRODUCT=rain-ubuntu", "GADGET_PRODUCT=fog-ubuntu"),
    (PIVOT, 'echo "=== rain ubuntu pivot ==="', 'echo "=== fog ubuntu pivot ==="'),
    # --- rootfs ADB gadget: this is the serial `adb devices` shows ---------
    (GADGET, 'echo rain >"$G/strings/0x409/serialnumber"',
             'echo fog >"$G/strings/0x409/serialnumber"'),
    (GADGET, 'echo rain-ubuntu >"$G/strings/0x409/product"',
             'echo fog-ubuntu >"$G/strings/0x409/product"'),
]


def main() -> int:
    v730 = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_V730
    if not v730.is_dir():
        print(f"no worktree at {v730} — run: make base", file=sys.stderr)
        return 1

    changed: dict[str, int] = {}
    errors: list[str] = []
    for rel, old, new in EDITS:
        path = v730 / rel
        text = path.read_text()
        if old in text:
            path.write_text(text.replace(old, new))
            changed[rel] = changed.get(rel, 0) + 1
        elif new not in text:
            errors.append(
                f"{rel}: neither {old!r} nor {new!r} found (upstream moved the line?)"
            )

    for rel, n in sorted(changed.items()):
        print(f"fog identity: {rel}: {n} edit(s)")
    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 2
    if not changed:
        print("fog identity: already applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
