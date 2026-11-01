# Redmi 10C (`fog`/`rain`) — Linux bring-up runbook

Base: [Damir00109/Redmi10c](UPSTREAM.md) `v7.3.0` (GPL-2.0) — kernel **7.3** +
`kernel.patch`, Ubuntu **26.04.1** on `cust`.

**Status 2026-11-02: v7.3.0 boots on this `fog` unit** via RAM boot
(`fastboot boot`): Ubuntu 26.04, root adb, DRM panel 720x1650 + fbcon,
Wi-Fi driver up and scanning, touch driver probes but firmware download fails
(known issue below). Slot A is stock MIUI Android and is the fallback.

---

## Device state

| Slot | Contents |
| --- | --- |
| `a` | stock MIUI 14 `V14.0.10.0.TGEEUXM` (untouched) |
| `b` | legacy 7.1.5 `boot_b` / Ubuntu 24.04 rootfs (still bootable fallback) |
| `cust` | Ubuntu 26.04.1 rootfs (`rain-ubuntu`, ext4 1800 MB / 1.5 GB sparse) |

Return to Android: `fastboot --set-active=a && fastboot reboot`.

## Using adb (quick)

`make adb` prints what adb is currently talking to and the cookbook.

| `adb devices -l` shows | What it is | Next |
| --- | --- | --- |
| `rain device` + kernel 7.3 | Linux, RAM boot | `adb shell` (root) |
| `rain device` + kernel 7.1.5 | legacy Linux on slot B | `make test` replaces it |
| `… recovery product:fog` | PBRP recovery (RAM boot) | `make test` |
| `… product:fog_eea` | stock Android, slot A | `make test` |
| `unauthorized` | adbd up, host key missing | rebuild rootfs (`make rootfs`) |
| fastboot list | bootloader | `make test` |

```sh
adb shell 'uname -a; id'              # root on rain-ubuntu
adb shell dmesg -w                    # live kernel log
adb shell 'cat /sys/class/drm/card0-DSI-1/status'   # connected
adb shell 'cat /sys/class/graphics/fb0/virtual_size' # 720,1650
adb push file /usr/local/sbin/        # userspace edits need no cust reflash
adb forward tcp:2222 tcp:22           # with: adb shell systemctl enable --now ssh
adb exec-out cat /dev/fb0 > screen.raw
```

This adbd reports "authentication not required"; the rootfs build installs
this host's key as a fallback.

---

## Host prerequisites

- macOS + Docker (arm64; the build is native, no qemu) or Linux; `adb`,
  `fastboot`, `gh` (firmware release download).
- ~25 GB free (kernel source/build + 26.04 image + sparse image).
- Docker state must stay inside the workspace:

```sh
export DOCKER_CONFIG="$PWD/.docker"
```

`make base` builds the `fog-v730` container (Ubuntu 24.04 + gcc, dtc, zstd,
e2fsprogs, rsync, img2simg, sudo).

---

## Reproduce the build (v7.3.0, verified 2026-11-02)

Everything is driven by `make`; each step is idempotent.

### 0. One-time base

```sh
make base
```

- worktree `Redmi10c-base/v730` at `origin/v7.3.0`
- firmware `firmware-2026.09.25` (61 MB) → `initramfs/lib/firmware`,
  `vendor-qcom/`, `sensors/`
- Ubuntu 26.04 cloud rootfs (241 MB) → `rootfs/cache/`
- container `fog-v730`

### 1. Kernel

```sh
make kernel
```

- `kernel.patch` on a **linux-7.3** tarball (tag `v7.3`; the tarball is used
  because a shallow git clone from kernel.org took >30× longer here)
- our fog deltas via `tools/v730-fog-dts.py`:
  - `qcom,board-id` `0x60022` → `0x40022`
  - HS-PHY: `vdda-pll` = PM6125 **L4** 0.88 V (upstream also binds it to L12),
    L12 pinned 1.8 V, L15 pinned 3.232 V, `xo_board` ref only (no `cfg_ahb`)
- `Image.gz`, `dtbs`, `modules modules_install`

Verified: `Image.gz` 9.8 MB, DTB 51 KB, `board-id 0x40022`;
upstream's `snps,dis-64bit-dma` (in `sm6225.dtsi`) supplies the 32-bit DMA
cap that we used to carry as a local patch.

### 2. Boot image

```sh
make image
make verify
```

`rootfs/tools/pack-boot-linux.sh` packs kernel + pivot initramfs (88 MB
firmware → 42 MB cpio.zst) → **52.07 MiB**, header v2. `make verify` checks
header, DTB magic, board-id and `xiaomi,fog`.

### 3. Rootfs (Ubuntu 26.04 on cust)

```sh
make rootfs          # IMG_SIZE_MB=1800 by default
```

Runs upstream's `rootfs/build-rootfs.sh` in a privileged arm64 container:
26.04 cloud image → chroot apt (~200 packages) → `rain-overlay` (82 files) →
ext4 1800 MB + sparse. The only local change is `OUT` being overridable so
the tree is built on the container's disk (mknod is denied on the macOS bind
mount).

Verified: `PRETTY_NAME="Ubuntu 26.04.1 LTS"`, sparse 1.5 GB, boots to
`adb shell` as root.

### 4. Boot test

```sh
make test            # RAM boot: fastboot boot, wait adb, capture, return to fastboot
```

Writes `docs/.scratch/adb-check.txt` (identity, systemd, display, touch,
wifi). No slot is written, so the retry counter cannot be burned.

`make test-slot` is the legacy flash path; avoid it (see AGENTS.md §5).

### 5. vbmeta_b (already done once; only for slot boot)

```sh
python3 tools/avb/avbtool.py make_vbmeta_image --flags 2 \
  --padding_size 4096 --output Redmi10c-base/v730/rootfs/out/vbmeta_b.img
fastboot flash vbmeta_b ...
```

---

## Flash (RAM boot is the default)

```sh
fastboot boot Redmi10c-base/v730/rootfs/out/boot-linux.img   # no slot write
fastboot flash cust Redmi10c-base/v730/rootfs/out/linux_rootfs.sparse.img
```

For a persistent slot-B install (only if RAM boot is refused): erase
`dtbo_b`, flash `boot_b` + `vbmeta_b` + `cust`, `--set-active=b`, reboot.
Read AGENTS.md §5 first — a failed slot boot burns one of 7 retries.

Boot takes ~35 s to adb. Success: `adb devices` → `rain device`, display
shows the fbcon console, `card0-DSI-1` is `connected`.

---

## Diagnosing a failed boot

| Symptom | Cause |
| --- | --- |
| No USB, no adb, no fastboot, screen dark | ABL rejected the DTB (board-id?) or early panic — check `make verify` |
| Comes up as Android (`product:fog_eea`, kernel 4.19) | **slot retry counter**, not vbmeta — see below |
| Boots, no adb | `systemctl status adbd usb-adb-gadget`, `cat /sys/class/udc/*/state` |
| adb up, no touch | FTS firmware download fails (see known issues) |
| `systemctl is-system-running` = starting | `systemctl list-jobs`; `rain-gps.service` blocks for a minute without network |
| `qbootctl.service` failed | normal for RAM boot — there is no boot slot to mark good |

### Slot retry counter (the silent fallback)

`fastboot --set-active=b` sets `slot-retry-count:b = 7`, clears
`slot-unbootable:b`, and reboots into slot B. ABL decrements on every
attempt; a kernel that dies before userspace (no `markBootSuccessful`) burns
all 7 in seconds, then ABL boots Android — which looks like "image rejected".
Check `fastboot getvar slot-retry-count:b` (7 fresh, 0 exhausted). Prefer
RAM boot: it writes no slot.

### Known issues (v7.3.0 on this unit)

- **Touch**: `fts_ts` probes, input device appears, but
  `fts_read: crc abnormal, status c3` and `boot id 0x00 0x00` at boot. The
  initramfs ships upstream's `focaltech_ts_fw_xinli.bin` (their unit). Next
  step: pull `/vendor/firmware/focaltech_ts_fw_xinli.bin` from *this* phone
  (PBRP + super partition) and compare; if identical, look at SPI bitbang
  timing.
- **`regulatory.db`**: missing from the initramfs (cfg80211 loads it before
  `switch_root`); Wi-Fi still scans. Add `wireless-regdb` to the build image
  and copy it into the initramfs.
- **WLAN MAC**: upstream DTS hardcodes an OEM WLAN MAC ("OEM WLAN MAC from
  Android") — that is *their* unit's MAC. Replace with ours from
  `persist/wlan_mac.bin`, or remove the property.
- **Bluetooth**: `hci0: Frame reassembly failed (-84)` at boot; not
  investigated.
- **GPS**: `rain-gps.service` runs, XTRA fetch fails without network; the
  service blocks `is-system-running` for ~60 s.

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
written by this runbook.

---

## Reading Linux logs without a console

```sh
fastboot boot reference/pbrp-fog-boot.img      # RAM boot, writes no slot
adb wait-for-device                            # PBRP gives root adb
adb shell 'mkdir -p /cust && mount -t ext4 -o ro /dev/block/sda8 /cust && \
           cat /cust/var/log/rain-boot-report.txt; umount /cust'
```

The 26.04 rootfs has no `rain-autoreboot`/report service any more, so
`make test` talks to adb directly and returns to fastboot with the
`rain-reboot-bootloader` helper (systemd's `/sbin/reboot` cannot pass a
reboot reason; the helper issues `reboot(2)` with `RESTART2 "bootloader"`).

## Automation

- `make test` / `tools/testboot-loop.sh` — RAM boot, wait for adb, capture
  identity/display/touch/wifi into `docs/.scratch/adb-check.txt`, return to
  fastboot. `RAM_BOOT=0` selects the legacy slot path.
- `tools/watch-boot.sh` — classify a boot (`LINUX`/`ANDROID`/`FASTBOOT`/`HUNG`).
- `tools/serial-probe.py` — stdlib CDC-ACM probe (legacy ACM console).

## USB / adb

Upstream `v7.3.0` carries the 32-bit DMA cap as `snps,dis-64bit-dma` in
`sm6225.dtsi` and force-enables the GCC USB clocks/GDSC in the femto driver.
Our `fog` delta on top is the HS-PHY supply map (L4 0.88 V for `vdda-pll`,
L12 1.8 V, L15 3.232 V, no `cfg_ahb`): upstream binds `vdda-pll` to L12 too,
which on this unit leaves the PHY without its 0.88 V core rail.

Historical dead ends (do not re-run):

- Never stop/start `DCTL` from userspace while a gadget is bound.
- `DWC3_DCTL_RUN_STOP` is **bit 31**.
- `DSTS.USBLNKST` alone is not evidence; trust `udc state: configured` plus
  host-side `adb devices`.
- `qcom,dwc3` glue claiming GCC clocks/GDSC/BCR leaves the controller
  running but endpoint events never complete — use the thin DT.
- `sm6225-xiaomi-fog-sm6115.dts` ("thin" image) crash-loops before userspace
  and has no log path; not a test vehicle.
