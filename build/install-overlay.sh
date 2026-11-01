#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install build/overlay/ into the cust ext4 image and re-sparsify it.
# Runs inside the fog-rootfs container as root (needs mount -o loop).
set -euo pipefail

IMG=${IMG:-Redmi10c-base/out/ubuntu-dualboot/linux_rootfs.img}
SPARSE=${SPARSE:-${IMG%.img}.sparse.img}
MNT=/mnt/rain-rootfs

[ -f "$IMG" ] || { echo "no image: $IMG" >&2; exit 1; }

mkdir -p "$MNT"
mount -o loop "$IMG" "$MNT"
trap 'umount "$MNT"' EXIT

(cd build/overlay && find . -type f -print) | while read -r f; do
    install -D -m "$(stat -c %a "build/overlay/$f")" "build/overlay/$f" "$MNT/$f"
done

# Autoreboot only fires when this flag exists.
touch "$MNT/etc/rain-autoreboot"

# Units must be enabled for the loop to be unattended.
UNIT="$MNT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$UNIT"
for u in rain-autoreboot.service rain-boot-report.service usb-gadget.service usb-force.service; do
    [ -f "$MNT/etc/systemd/system/$u" ] && ln -sfn "/etc/systemd/system/$u" "$UNIT/$u"
done

umount "$MNT"
trap - EXIT

img2simg "$IMG" "$SPARSE"
ls -l "$SPARSE"
