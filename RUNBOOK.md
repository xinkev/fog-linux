# Redmi 10C (`fog`/`rain`) — Linux bring-up runbook

Base: [Damir00109/Redmi10c](UPSTREAM.md) (GPL-2.0), mainline **v7.1.5** +
`patches/redmi10c-mainline-20260813.patch`.

**Status 2026-11-01: mainline Linux boots on this phone** (slot B) to a
framebuffer login prompt on Ubuntu 24.04 running from `cust`. USB gadget
(adb/ACM console) is **not** up yet — see *Known gaps*. Slot A is stock MIUI
Android and is the fallback.

---

## Device state

| Slot | Contents |
| --- | --- |
| `a` | stock MIUI 14 `V14.0.10.0.TGEEUXM` (boot/vendor_boot/vbmeta/dtbo restored from `reference/`) |
| `b` | mainline `boot_b` (header v2), custom `vbmeta_b` (`--flags 2`), `dtbo_b` erased |
| `cust` | Ubuntu 24.04 rootfs (`rain-ubuntu`, ext4, 1.8 GB image / ~514 MB sparse) |

Return to Android: `fastboot --set-active=a && fastboot reboot`.

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
```

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

Boot takes ~20–25 s. Success signal is **on the phone**: framebuffer console
then `rain-ubuntu login:`. The host sees no USB device yet, so `adb devices`
stays empty — that is not a failure of the boot.

Login: `root` / `rain` (need an OTG keyboard until USB gadget works).

---

## Diagnosing a failed boot

| Symptom | Cause |
| --- | --- |
| No USB, no adb, no fastboot, screen dark/hung | ABL rejected our DTB or kernel panicked early — check `qcom,board-id` (0x40022) and that `boot_b` is header v2 |
| Comes up as Android (`product:fog_eea`, kernel 4.19) | **usually the slot retry counter, not vbmeta** — see below; check `getvar slot-retry-count:b` |
| Boots, no `adb`/`/dev/ttyACM*` | expected today: no gadget unit in rootfs (pivot-init unbinds UDC before `switch_root`) |

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

## Known gaps after first light

- **USB gadget does not enumerate.** Software side is correct (`udc:
  4e00000.usb`, gadget bound, `gettyGS0: active`) but `udc state` stays
  `not attached` and the host never enumerates.
  - **Ruled out (2026-11-01):** EUD hijack. Downstream DT puts
    `qcom,msm-eud@1610000` at `reg = <0x1610000 0x2000>, <0x1612000 0x1000>`,
    and both `EUD_CSR_EUD_EN` (0x1611014) and `EUD_EN2` (0x1612000) read 0 on
    a live boot — the debug block is not stealing the port. Those pages are
    still safe to read (they are unclaimed by mainline, so keep the read last
    and after a `sync`, as `boot-report.sh` does).
  - **Controller is running:** `DWC3_DCTL_RUN_STOP` is **bit 31**, not bit 0
    (`drivers/usb/dwc3/core.h`). `DCTL = 0x80f00000` means running; decoding
    bit 0 makes it look halted and sends you chasing a non-bug.
  - **Do not stop/start `DCTL` from userspace.** `usb-force.py` used to clear
    and re-set RUN_STOP "to hand the controller back to the driver" — that
    restarts the controller behind dwc3's back, leaves the event ring stale,
    and produces the `unknown endpoint event 0` storm. Removing it dropped the
    spam from 82 to 21 occurrences per boot. Never write `0x4e0c704` from
    userspace while a gadget is bound.
  - **Open:** `DSTS.USBLNKST` reads `0 (on)` with a non-zero `SOFFN` on some
    boots and `3 (disconnected)` on others, i.e. the PHY does assert D+ at
    least briefly, but the host never sees a device — consistent with a stale
    event ring / failed control endpoint rather than a dead PHY.
  - The sm6115 board (`sm6225-xiaomi-fog-sm6115.dts`, "thin" image) is **not**
    a viable test vehicle: it crash-loops before userspace (burns the whole
    slot retry counter in ~90 s) and, with UFS and GPU disabled, it has no
    rootfs, no report file and no `ramoops` node, so it cannot log anything.
    Test USB on `sm6225-xiaomi-fog.dts`, which boots and reports.
- GPU scanout, audio, modem, camera, GPS, fingerprint, NFC — as upstream
  `STATUS.md`.
