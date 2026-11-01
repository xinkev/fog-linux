#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Fetch adbd + Android runtime libs for the cust rootfs.
#
# Ubuntu 24.04 (noble) has no adbd package; Debian trixie ships one built
# against glibc 2.38+, which noble (2.39) satisfies. libprotobuf32t64 is
# the only dependency noble does not ship by default.
#
# Files land in docs/.scratch/adbd/ (gitignored). `make rootfs` installs
# them into the image; nothing here is committed.
set -eu

DEST=${DEST:-docs/.scratch/adbd}
mkdir -p "$DEST/debs"

sum() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

fetch() {
    url=$1
    out=$2
    want=$3
    if [ -f "$out" ] && [ "$(sum "$out")" = "$want" ]; then
        echo "ok      $out"
        return 0
    fi
    echo "fetch   $url"
    curl -fsSL --retry 3 -o "$out.part" "$url"
    got=$(sum "$out.part")
    if [ "$got" != "$want" ]; then
        echo "checksum mismatch for $out: got $got want $want" >&2
        rm -f "$out.part"
        exit 1
    fi
    mv "$out.part" "$out"
}

DEB=https://deb.debian.org/debian/pool/main/a
PORTS=https://ports.ubuntu.com/pool/main/p

fetch "$DEB/android-platform-tools/adbd_34.0.5-12_arm64.deb" \
      "$DEST/debs/adbd_34.0.5-12_arm64.deb" \
      c8d2cb679fb6b0d508181310f7fb0e6ce4e713376ac123b9c47f1be58112ce6c
fetch "$DEB/android-platform-tools/android-libbase_34.0.5-12_arm64.deb" \
      "$DEST/debs/android-libbase_34.0.5-12_arm64.deb" \
      1b1460faa12cf04611cb58ff02808608fd2e3be642b72752a189c4ab84112a20
fetch "$DEB/android-platform-tools/android-libcutils_34.0.5-12_arm64.deb" \
      "$DEST/debs/android-libcutils_34.0.5-12_arm64.deb" \
      683ec66783e0d54e91bee661af7f758528b2c85163d585ae936d1cfd5bf8d661
fetch "$DEB/android-platform-tools/android-liblog_34.0.5-12_arm64.deb" \
      "$DEST/debs/android-liblog_34.0.5-12_arm64.deb" \
      7ce80b00c4592d0021ce2973d922f1c014fbbe33a289690732dfb556bfbbec96
fetch "$DEB/android-platform-external-boringssl/android-libboringssl_14.0.0+r45-2_arm64.deb" \
      "$DEST/debs/android-libboringssl_14.0.0+r45-2_arm64.deb" \
      6dd20f2d7ad3cdff7c80d8076feea6258c8e9f0a0a23ad85d447eeb3e7f11c36
fetch "$PORTS/protobuf/libprotobuf32t64_3.21.12-8.2build1_arm64.deb" \
      "$DEST/libprotobuf32t64_3.21.12-8.2build1_arm64.deb" \
      c35f528c08499f75c2e721114657d12cdf08455ff6e1b49bc3c630865f2175e8

echo "staged in $DEST"
