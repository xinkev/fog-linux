# Redmi 10C (`fog`/`rain`) — Linux bring-up runbook

Base: [Damir00109/Redmi10c](UPSTREAM.md) (GPL-2.0), mainline **v7.1.5** +
`patches/redmi10c-mainline-20260813.patch`.

**Status 2026-11-02: mainline Linux boots on this phone** (slot B) to a
framebuffer login prompt on Ubuntu 24.04 from `cust`; **adb over USB works**
(root shell). Slot A is stock MIUI Android and is the fallback.

---

## Device state

| Slot | Contents |
| --- | --- |
| `a` | stock MIUI 14 `V14.0.10.0.TGEEUXM` (boot/vendor_boot/vbmeta/dtbo restored from `reference/`) |
| `b` | mainline `boot_b` (header v2), custom `vbmeta_b` (`--flags 2`), `dtbo_b` erased |
| `cust` | Ubuntu 24.04 rootfs (`rain-ubuntu`, ext4, 1.8 GB image / ~514 MB sparse) |

Return to Android: `fastboot --set-active=a && fastboot reboot`.

## Using adb (quick)

`make adb` prints what adb is currently talking to and the cookbook.

| `adb devices -l` shows | What it is | Next |
| --- | --- | --- |
| `rain device` | Linux from slot B | `adb shell` (root) |
| `… recovery product:fog` | PBRP recovery (RAM boot) | `make test SKIP_CUST=1` |
| `… product:fog_eea` | stock Android, slot A | `make test SKIP_CUST=1` |
| `unauthorized` | adbd up, host key missing | `make rootfs`, reboot |
| fastboot list | bootloader | `make test` |

`adb shell uname -r` disambiguates: `7.x` is the Linux port; a 4.19 kernel is
PBRP or Android.

```sh
adb shell 'uname -a; id'              # root on rain-ubuntu
adb shell dmesg -w                    # live kernel log
adb pull /var/log/rain-boot-report.txt
adb push file /usr/local/sbin/        # userspace edits need no cust reflash
adb forward tcp:2222 tcp:22           # with: adb shell systemctl enable --now ssh
adb exec-out cat /dev/fb0 > screen.raw
adb shell rm /etc/rain-autoreboot     # stop the 45 s self-reboot
adb reboot bootloader
```

This adbd reports "authentication not required"; the host key is a fallback.
`make adb` never flashes or changes the phone.

---

## Host prerequisites

- macOS + OrbStack (arm64, 8 cores) or Linux; `adb`, `fastboot`.
- ~20 GB free; two docker images from `build/Dockerfile` / `build/Dockerfile.rootfs`.
- Docker state must stay inside the workspace:

```sh
export DOCKER_CONFIG="$PWD/.docker"
```

---

## Reproduce the build (verified commands)

### 1. Kernel source + patch

```sh
cd Redmi10c-base
curl -LO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.5.tar.xz
tar -xf linux-7.1.5.tar.xz -C mainline/ && mv mainline/linux-7.1.5 mainline/linux-7.1.y
cd mainline/linux-7.1.y
patch -p1 --batch < ../../patches/redmi10c-mainline-20260813.patch
# fog-specific USB/adb fix (32-bit DWC3 DMA + real PHY rails):
patch -p1 --batch < ../../../patches/fog-adb-usb.patch
```

`make patch` applies `patches/fog-adb-usb.patch` idempotently, and
`make kernel` / `make image` depend on it.

**Gotchas**

- Use `patch -p1`, **not** `git apply`: inside this clone `git apply` resolves
  paths against the repo root and silently sprays files into `Redmi10c-base/`.
- Our unit is `fog` and reports `qcom,board-id = <0x40022>`; the repo DTS
  hardcodes `<0x60022>` (their `rain`). Fix before building or the kernel dies
  with no USB and no console:

```sh
sed -i '' 's/qcom,board-id = <0x60022 0x00>/qcom,board-id = <0x40022 0x00>/' \
  arch/arm64/boot/dts/qcom/sm6225-xiaomi-fog.dts
```

### 2. Kernel + DTB

```sh
cd Redmi10c-base
mkdir -p out/linux-7.1.5 && cp configs/rain-fog-working.config out/linux-7.1.5/.config
docker run --rm -v "$PWD":/src -w /src fog-build:latest bash -lc '
  make -C mainline/linux-7.1.y O=/src/out/linux-7.1.5 ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- -j8 olddefconfig Image.gz dtbs'
```

### 3. busybox (static aarch64)

```sh
docker run --rm -v "$PWD":/src -w /src/tools/busybox-src fog-build:latest bash -lc '
  cp ../../configs/busybox-1.36.1.config .config
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j8 oldconfig busybox
  mkdir -p ../../out/initramfs-root/bin
  cp busybox ../../out/initramfs-root/bin/busybox'
```

### 4. Boot image (header v2)

Must run **inside the container** — `pack-ubuntu-boot.sh` executes the
aarch64 `busybox` to enumerate applets, which fails on the Mac host.

```sh
mkdir -p out/ubuntu-dualboot/twrp/images
docker run --rm -v "$PWD":/src -w /src fog-build:latest bash tools/pack-ubuntu-boot.sh
# -> out/ubuntu-dualboot/boot-linux.img (~18.35 MiB)
```

Verify: header version 2, kernel ≈18 MB, dtb ≈29 KB, `board-id = <0x40022>`.

### 5. Rootfs (Ubuntu 24.04 on cust)

debootstrap **must** target a docker volume: the macOS bind mount breaks
`tar`/hardlinks mid-extraction (`Tried to extract package, but tar failed`).

```sh
docker volume create fogrf
docker run --rm -v fogrf:/rf fog-rootfs:latest \
  debootstrap --arch=arm64 noble /rf/rootfs http://ports.ubuntu.com/ubuntu-ports

# repo provisioning script, with shims (no sudo/qemu in container; native arm64)
docker run --rm --privileged -v "$PWD":/src -v fogrf:/src/out/ubuntu-dualboot \
  -w /src -e DEBIAN_FRONTEND=noninteractive fog-rootfs:latest bash -lc '
    cp /bin/true /usr/bin/qemu-aarch64
    printf "#!/bin/sh\nexec \"\$@\"\n" > /usr/local/bin/sudo; chmod +x /usr/local/bin/sudo
    bash tools/build-ubuntu-dualboot.sh'
```

The script leaves chroot `/proc` and `/sys` mounted, so its own rsync fails
(code 23) and produces an incomplete image. Rebuild the image with excludes:

```sh
docker run --rm --privileged -v "$PWD/out/ubuntu-dualboot":/out -v fogrf:/rf \
  fog-rootfs:latest bash -lc '
    IMG=/out/linux_rootfs.img; rm -f "$IMG" /out/linux_rootfs.sparse.img
    dd if=/dev/zero of="$IMG" bs=1M count=1800 status=none
    mkfs.ext4 -q -L rain-ubuntu -O ^metadata_csum_seed "$IMG"
    mkdir -p /mnt/root && mount -o loop "$IMG" /mnt/root
    rsync -aHAX --numeric-ids --exclude=/proc/* --exclude=/sys/* \
      --exclude=/dev/* --exclude=/tmp/* --exclude=/run/* /rf/rootfs/ /mnt/root/
    umount /mnt/root
    img2simg "$IMG" /out/linux_rootfs.sparse.img'
```

Gate: `/sbin/init` resolves to `/usr/lib/systemd/systemd` inside the image.

### 6. vbmeta_b (verification disabled)

README Step 6 omits this command, but the stock `vbmeta_b` verifies and
**silently rejects** an unsigned `boot_b` — ABL then falls back to Android.

```sh
python3 ../tools/avb/avbtool.py make_vbmeta_image --flags 2 \
  --padding_size 4096 --output out/ubuntu-dualboot/vbmeta_b.img
```

---

## Flash (slot B only)

```sh
fastboot erase dtbo_b
fastboot flash boot_b   out/ubuntu-dualboot/boot-linux.img
fastboot flash vbmeta_b out/ubuntu-dualboot/vbmeta_b.img
fastboot flash cust     out/ubuntu-dualboot/linux_rootfs.sparse.img
fastboot --set-active=b
fastboot reboot
```

Boot takes ~20–25 s. Success signal is the framebuffer console and, once
adbd starts, `adb devices` → `rain device`. Login: `root` / `rain`; adb
needs no keyboard.

---

## Diagnosing a failed boot

| Symptom | Cause |
| --- | --- |
| No USB, no adb, no fastboot, screen dark/hung | ABL rejected our DTB or kernel panicked early — check `qcom,board-id` (0x40022) and that `boot_b` is header v2 |
| Comes up as Android (`product:fog_eea`, kernel 4.19) | **usually the slot retry counter, not vbmeta** — see below; check `getvar slot-retry-count:b` |
| Boots, no `adb` | `systemctl status usb-adb-gadget adbd`, `cat /sys/class/udc/*/state`, `/var/log/rain-boot-report.txt`; `make logs` after a test |

### Slot retry counter (the silent fallback)

`fastboot --set-active=b` is not just a flag flip: it sets
`slot-retry-count:b = 7`, clears `slot-unbootable:b`, **and reboots straight
into slot B**. ABL decrements the counter on every attempt; a kernel that dies
before userspace (no boot_control HAL to call `markBootSuccessful`) burns all
7 retries in a few seconds and ABL then boots slot A — which looks exactly
like "our image was rejected", but is a crash loop.

Verify with `fastboot getvar slot-retry-count:b` (7 = fresh, 0 = exhausted)
and `slot-unbootable:b`. Before every slot-B test, re-run
`fastboot --set-active=b`; expect a ~90 s round trip when the image does not
come up.

---

## Recovery

| Symptom | Fix |
| --- | --- |
| Bad slot B | `fastboot --set-active=a && fastboot reboot` |
| `cust` corrupt | re-flash `linux_rootfs.sparse.img` |
| Need stock Android images | `reference/{boot_a,vendor_boot_a,vbmeta_a,dtbo_a}.img` |
| No fastboot | Vol-Down + Power; last resort EDL + official stock ROM |

**Never flash:** `xbl`, `abl`, `bl1/bl2/bl31`, `bootloader`, `vbmeta_a`,
`boot_a`, `persist`, `modemst*`, `fsg`, `fsc`, `devinfo`.

**SIMs:** provisioning lives in `modemst1/2`, `fsg`, `fsc`, `persist` — none
written by this runbook. Linux has no modem driver; calls/SMS/data only in
slot A.

---

## Reading Linux logs without any console

The phone writes `/var/log/rain-boot-report.txt` inside `cust` on every boot.
With no USB console, read it through recovery instead of the screen:

```sh
fastboot boot reference/pbrp-fog-boot.img      # RAM boot, writes no slot
adb wait-for-device                            # PBRP gives root adb
adb shell 'mkdir -p /cust && mount -t ext4 -o ro /dev/block/sda8 /cust && \
           cat /cust/var/log/rain-boot-report.txt; umount /cust'
```

This is also how to iterate: flash → boot → power-cycle to fastboot →
RAM-boot PBRP → pull log. `fastboot boot` can fail with
`Status read failed`; retry after `adb reboot bootloader`.
Android does not expose `/dev/mem`, so register dumps are only possible in Linux.

## Automation (no screen-watching)

- `tools/watch-boot.sh` — classify a boot: `LINUX` (serial gadget + probe),
  `ANDROID` (ABL fallback, prints product/release), `FASTBOOT`, or `HUNG`
  (timeout). Flags: `--flash`, `--reboot`, `--timeout`, `--no-probe`.
- `tools/serial-probe.py` — stdlib-only CDC-ACM probe (`/dev/cu.usbmodem*`),
  runs commands and prints output.
- Rootfs overlay in `build/overlay/` (installed into the ext4 image):
  - `usb-gadget.service` / `usb-gadget.sh` — binds the UDC as CDC-ACM.
  - `usb-force.service` / `usb-force.py` — re-applies the repo's PHY/GDSC
    pokes from userspace before binding.
  - `getty@ttyGS0` override — root autologin on the serial console.
  - `rain-boot-report.service` — writes USB/gadget diagnostics to VT 2 so a
    human can read them without a keyboard; copy in `/var/log/rain-boot-report.txt`.
  - `rain-reboot-bootloader` — static aarch64 helper that reboots to fastboot
    (`reboot(2)` with the `"bootloader"` reason). Not in git; rebuild inside
    `fog-build` with
    `aarch64-linux-gnu-gcc -static -O2 -o rain-reboot-bootloader rain-reboot-bootloader.c`.
- `fastboot --set-active=<slot>` costs **~90 s** on this unit (ABL slot
  rewrite); skip it when the slot is already current — flash + `fastboot
  reboot` is ~13 s.

## USB / adb (resolved 2026-11-02)

`adb devices` shows `rain device`; `adb shell` is root. The UDC reports
`configured` and `endpoint-event spam: 0`. Two independent faults had to go:

1. **DT ownership.** USB must use the upstream *thin* DT: bare
   `snps,dwc3`, femto PHY with the XO ref, and the USB clocks in
   `protected-clocks`. QSCRATCH/GDSC/AHB2PHY are driven by the femto
   driver's `force_usb_clks()` and by initramfs. A `qcom,dwc3` glue node
   that claimed GCC clocks/GDSC/BCR kept the controller running but never
   completed endpoint events. (That glue was our addition; upstream
   deliberately omits it.)
2. **64-bit DMA placement.** `GHWPARAMS0.AWIDTH = 64`, so dwc3 set a 64-bit
   DMA mask and the event ring landed at `0x1_022fc000`. This USB master
   never wrote there: every event read back as zero
   (`unknown endpoint event 0`), ep0 never completed and the host never
   enumerated. `snps,force-32bit-dma` (`patches/fog-adb-usb.patch`) moves
   the ring to `0x43800000`; spam drops 111 → 0 and adbd binds.

Userspace: `usb-adb-gadget.service` builds `g1` with `ffs.adb`, then
`adbd.service` runs Debian's `adbd`. Ubuntu noble has no adbd package;
`tools/fetch-adbd-debs.sh` stages trixie arm64 debs and `make rootfs`
installs them. This adbd build reports "authentication not required";
`make rootfs` still installs this host's key at `/data/misc/adb/adb_keys`.

The image self-reboots 45 s after the boot report
(`/etc/rain-autoreboot`). For a persistent adb session:

```sh
adb shell rm /etc/rain-autoreboot
```

Historical dead ends (kept so they are not re-run):

- EUD is not hijacking the port (`0x1611014`, `0x1612000` read 0).
- `DWC3_DCTL_RUN_STOP` is **bit 31**; `DCTL = 0x80f00000` means running.
- Never stop/start DCTL (`0x4e0c704`) from userspace while a gadget is
  bound; it restarts the controller behind dwc3 and corrupts the ring.
- `DSTS.USBLNKST` alone is not evidence (0 vs 3 varies with host retries);
  trust `udc state: configured` plus a host-side `adb devices`.

- The sm6115 board (`sm6225-xiaomi-fog-sm6115.dts`, "thin" image) is **not**
  a viable test vehicle: it crash-loops before userspace (burns the whole
  slot retry counter in ~90 s) and, with UFS and GPU disabled, it has no
  rootfs, no report file and no `ramoops` node, so it cannot log anything.
  Test USB on `sm6225-xiaomi-fog.dts`, which boots and reports.
- GPU scanout, audio, modem, camera, GPS, fingerprint, NFC — as upstream
  `STATUS.md`.
