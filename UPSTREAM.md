# Upstream base

[Damir00109/Redmi10c](https://github.com/Damir00109/Redmi10c) — GPL-2.0,
branch **`v7.3.0`** (5abe3ee, 2026-10-27), checked out in the gitignored
`Redmi10c-base/v730/` worktree.

It is **rain/fog**, not rain-only. Upstream's README says "codename `rain`,
variant `fog`", ships `sm6225-xiaomi-fog.dts`, and its `STATUS.md` was
verified on a `fog`/`rain` unit with the same panel (Xinli FT8006S), touch
(FocalTech `xinli`), charger (smb1351), gauge (sh366101) and Type-C
(wusb3801) as ours. There is one SoC tree (`sm6225.dtsi`) and one board DTS.

Our unit is the EEA `fog` SKU (board-id `0x40022`), theirs is `rain`
(`0x60022`) — that is the whole split.

## What v7.3.0 gives us

Kernel **7.3** (`kernel.patch` + `kernel.config`), Ubuntu **26.04.1**
rootfs (`rootfs/build-rootfs.sh` + 82-file `rain-overlay`), pivot initramfs
with firmware, and upstream-verified display (DRM/DSI + fbcon), touch,
Wi-Fi (ath10k_snoc + NM), BT + A2DP, audio, modem/LTE, GPS stack, sensors,
SD, suspend/resume and USB adb.

`build.sh` builds the kernel + busybox/tinyalsa + a **rescue image**
(`boot-display-console-rescue.img`, 53 MiB). The production boot image is
`rootfs/tools/pack-boot-linux.sh` → `boot-linux.img` (52 MiB).

## Divergences

| Item | Upstream (`rain` unit) | Here (`fog` unit) |
|---|---|---|
| `qcom,board-id` | `0x60022` (still in v7.3.0) | `0x40022` (`tools/v730-fog-dts.py`) |
| USB HS PHY `vdda-pll` | PM6125 **L12** (1.8 V class) | PM6125 **L4** (0.88 V) |
| L12 / L15 setpoint | min..max range (SPMI settles at min) | pinned 1.8 V / 3.232 V |
| HS PHY clocks | `rpmcc XO` + `gcc cfg_ahb` | `xo_board` only (driver force-enables GCC via MMIO) |
| 32-bit DWC3 DMA | `snps,dis-64bit-dma` in `sm6225.dtsi` | same (our old `force-32bit-dma` patch is legacy) |
| Test loop | manual | `tools/testboot-loop.sh`, RAM boot by default |
| rootfs build | host Ubuntu + `sudo` + loop mounts | same script in a privileged arm64 container; `OUT` moved to container disk |
| vbmeta_b | stock/verifying | `--flags 2` (from the 7.1.5 work; still on the phone) |

The HS-PHY delta is the one that mattered on this unit: with `vdda-pll` on
L12 the PHY core never got its 0.88 V rail and the UDC reported
`not attached` in the 7.1.5 tree.

## Works there, not here (v7.3.0 on `fog` EEA)

| Feature | Upstream | Here |
|---|---|---|
| Touch | works | driver probes, firmware download fails (`crc abnormal`, boot id 0x00) |
| Bluetooth | HCI up, A2DP | `hci0: Frame reassembly failed (-84)` |
| Wi-Fi | connected via NM | driver up, scans; not joined (no credentials yet) |
| regulatory.db | in initramfs | missing (build host lacked `wireless-regdb`) |
| WLAN MAC | their unit's MAC in DTS | same MAC baked in — must be replaced with ours |

## Works here, not there

- Nothing device-specific yet; the divergences above are the fog fixes.

## Alternatives checked (2026-11-02)

- **Nura/pmOS `xiaomi-fog`** — **archived**; device page says mainline "no",
  screen partial, touch / USB-net / battery work. Kernel package
  `linux-postmarketos-qcom-sm6225` is a 6.1 fork of
  `TQMatvey/linux-sm6225` (last activity 2024-06) — dead branch, not a base.
  USBNET id `05c6:9039` is its only durable fact for us.
- **Android device trees** — `alternoegraha/device_xiaomi_fog` (lineage-23),
  `dblenk-project/device_xiaomi_fog`, TWRP trees. Hardware reference only.
- **lk2nd** — no SM6225 device DTS (`lk2nd/device/dts` = msm*/mdm9607 only).
- **Mainline Linux** — no `sm6225*.dts` in
  `arch/arm64/boot/dts/qcom/Makefile` (only sm6115 / sm4250 bengal). There is
  no upstream DTS to switch to.
