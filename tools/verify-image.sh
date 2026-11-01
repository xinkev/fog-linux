#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Sanity-check a packed boot image before it goes near the phone.
# Usage: tools/verify-image.sh [boot.img]
set -uo pipefail

IMG=${1:-Redmi10c-base/out/ubuntu-dualboot/boot-linux.img}
exec python3 - "$IMG" <<'PYEOF'
import struct, sys

path = sys.argv[1]
d = open(path, "rb").read()
ok = True

def check(name, cond, detail=""):
    global ok
    if not cond:
        ok = False
    print(("  ok    " if cond else "  FAIL  ") + name + (("  " + detail) if detail else ""))

check("magic ANDROID!", d[:8] == b"ANDROID!")
hv = struct.unpack_from("<I", d, 0x28)[0]
ps = struct.unpack_from("<I", d, 0x24)[0] or 2048
ksz = struct.unpack_from("<I", d, 0x08)[0]
rsz = struct.unpack_from("<I", d, 0x10)[0]
ssz = struct.unpack_from("<I", d, 0x18)[0]
rdt = struct.unpack_from("<I", d, 0x660)[0]
hsz = struct.unpack_from("<I", d, 0x66C)[0]
dsz = struct.unpack_from("<I", d, 0x670)[0]

check("header v2", hv == 2, "got %d" % hv)
check("page size 2048", ps == 2048, "got %d" % ps)
check("header_size 0x67c", hsz == 0x67C, "got 0x%x" % hsz)
check("kernel present", ksz > 0, "%d bytes" % ksz)
check("ramdisk present", rsz > 0, "%d bytes" % rsz)
check("dtb size set", dsz > 0, "%d bytes" % dsz)

def pages(n):
    return ((n + ps - 1) // ps) * ps

off = ps + pages(ksz) + pages(rsz) + pages(ssz) + pages(rdt)
dtb = d[off:off + dsz]
check("dtb magic", dtb[:4] == b"\xd0\x0d\xfe\xed")

def walk(buf):
    import struct as s
    o1 = s.unpack_from(">I", buf, 8)[0]
    o2 = s.unpack_from(">I", buf, 12)[0]
    p, path, out = o1, [], []
    while True:
        tok = s.unpack_from(">I", buf, p)[0]; p += 4
        if tok == 1:
            e = buf.index(b"\0", p); nm = buf[p:e].decode("latin1"); p = (e + 4) & ~3
            if nm: path.append(nm)
        elif tok == 2:
            if path: path.pop()
        elif tok == 3:
            ln, noff = s.unpack_from(">II", buf, p); p += 8
            n = buf[o2 + noff:buf.index(b"\0", o2 + noff)].decode("latin1")
            v = buf[p:p + ln]; p = (p + ln + 3) & ~3
            out.append(("/" + "/".join(path), n, v))
        elif tok == 9:
            break
    return out

props = {("/" + "" if p == "/" else p, n): v for p, n, v in walk(dtb)} if dtb[:4] == b"\xd0\x0d\xfe\xed" else {}
board = props.get(("/", "qcom,board-id"), b"")
bid = struct.unpack(">I", board[:4])[0] if len(board) >= 4 else 0
check("board-id 0x40022 (fog)", bid == 0x40022, "got 0x%x" % bid)
compat = props.get(("/", "compatible"), b"").decode("latin1", "replace")
check("compatible has xiaomi,fog", "xiaomi,fog" in compat, compat.replace("\0", " ").strip())

print("\n" + ("ready to flash" if ok else "DO NOT FLASH"))
sys.exit(0 if ok else 1)
PYEOF
