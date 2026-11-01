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
cleanup() {
    umount "$MNT/proc" 2>/dev/null || true
    umount "$MNT/dev" 2>/dev/null || true
    umount "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

(cd build/overlay && find . -type f -print) | while read -r f; do
    install -D -m "$(stat -c %a "build/overlay/$f")" "build/overlay/$f" "$MNT/$f"
done

# adbd is not in Ubuntu noble; install the staged Debian binary + Android
# libs (tools/fetch-adbd-debs.sh fetches them into docs/.scratch/adbd).
if [ ! -x "$MNT/usr/sbin/adbd" ]; then
    DEBSRC="$PWD/docs/.scratch/adbd"
    if ls "$DEBSRC"/debs/adbd_*.deb >/dev/null 2>&1; then
        echo "installing adbd debs from $DEBSRC"
        mkdir -p "$MNT/tmp/adbd-debs"
        cp "$DEBSRC"/debs/*.deb "$DEBSRC"/libprotobuf32t64_*.deb "$MNT/tmp/adbd-debs/"
        # dpkg's maintainer scripts expect /dev and /proc.
        mount --bind /dev "$MNT/dev" 2>/dev/null || true
        mount -t proc proc "$MNT/proc" 2>/dev/null || true
        chroot "$MNT" /bin/bash -c '
            export DEBIAN_FRONTEND=noninteractive
            cd /tmp/adbd-debs
            dpkg -i libprotobuf32t64_*.deb android-liblog_*.deb android-libbase_*.deb \
                    android-libboringssl_*.deb android-libcutils_*.deb adbd_*.deb
        '
        umount "$MNT/proc" 2>/dev/null || true
        umount "$MNT/dev" 2>/dev/null || true
        rm -rf "$MNT/tmp/adbd-debs"
    else
        echo "WARNING: no adbd debs staged; run tools/fetch-adbd-debs.sh" >&2
    fi
fi

# Authorize this host. The public key is copied from ~/.android by `make
# rootfs`; keep it in scratch, never in git.
if [ -f "$PWD/docs/.scratch/adbd/adbkey.pub" ]; then
    install -d -m 700 "$MNT/data/misc/adb"
    # adbd parses newline-separated keys; a file without a trailing newline
    # leaves the last key unread on some adbd builds.
    cat "$PWD/docs/.scratch/adbd/adbkey.pub" >"$MNT/data/misc/adb/adb_keys"
    printf '\n' >>"$MNT/data/misc/adb/adb_keys"
    chmod 644 "$MNT/data/misc/adb/adb_keys"
    echo "installed host adb key"
else
    echo "WARNING: no host adbkey.pub staged; adb will show 'unauthorized'" >&2
fi

# Autoreboot only fires when this flag exists.
touch "$MNT/etc/rain-autoreboot"

# Units must be enabled for the loop to be unattended. ACM/force units are
# removed from the enable set: the ADB gadget takes the UDC.
UNIT="$MNT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$UNIT"
for u in usb-gadget.service usb-force.service; do
    rm -f "$UNIT/$u"
done
# The old image enabled a ttyGS0 getty; it pulled the ACM unit (and killed
# adbd through Conflicts). ADB-only has no ttyGS0.
rm -f "$MNT/etc/systemd/system/getty.target.wants/getty@ttyGS0.service"
for u in rain-autoreboot.service rain-boot-report.service usb-adb-gadget.service adbd.service; do
    [ -f "$MNT/etc/systemd/system/$u" ] && ln -sfn "/etc/systemd/system/$u" "$UNIT/$u"
done

umount "$MNT"
trap - EXIT

img2simg "$IMG" "$SPARSE"
ls -l "$SPARSE"
