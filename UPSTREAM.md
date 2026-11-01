# Upstream base

[Damir00109/Redmi10c](https://github.com/Damir00109/Redmi10c) — GPL-2.0.
Cloned at `Redmi10c-base/` (keeps its own `.git`; not tracked here).
Kernel 7.1.5 + `patches/redmi10c-mainline-20260813.patch` (upstream now also
ships `20260831`; our local patch applies on top of either).

It is a starting point, not a target. Their board is `rain`; ours is `fog`
(board-id `0x40022` vs `0x60022`), so the two are expected to drift.

Use it for: kernel tree, patch set, DTS, mkbootimg, `pack-ubuntu-boot.sh`,
`pivot-init`. Record every divergence below — future debugging will ask
"does it work there but not here?".

## Divergences

| Item | Upstream (`rain`) | Here (`fog`) |
|---|---|---|
| `qcom,board-id` | `0x60022` | `0x40022` |
| `vbmeta_b` | stock/verifying | `--flags 2` (verification off) |
| Test loop | manual | `tools/testboot-loop.sh` (unattended, adb-aware) |
| Logs without a console | serial/UART | report written into `cust`, pulled via PBRP |
| USB DMA | 64-bit mask, ring happens to land <4 GiB | `snps,force-32bit-dma` (`patches/fog-adb-usb.patch`) |
| USB PHY rails | dummy `vreg_usb_*` | real PM6125 L4/L12/L15 + `GCC_QUSB2PHY_PRIM_BCR` |
| adb | FunctionFS + `adbd` from staged debs | same, plus host-key install in `make rootfs` |
| `usb-force.py` | repo pokes | DCTL stop/start removed (corrupts the event ring) |

## Works there, not here

| Feature | Upstream | Here |
|---|---|---|
| `sm6225-xiaomi-fog-sm6115.dts` | boots | crash-loops before userspace (UFS/GPU off → no logs) |

## Works here, not there

- USB enumeration + adb (2026-11-02) — see RUNBOOK → USB / adb. The upstream
  tree works too; our fix makes it deterministic instead of allocation luck.

## Prior art checked (2026-11-02)

- **Upstream `Damir00109/Redmi10c`** already had ADB on mainline 7.1.5:
  `notes/adb-serve/`, `tools/rain-overlay/.../usb-adb-gadget.sh`,
  `adbd.service`. This is the stack we adopted.
- **Archived postmarketOS port `xiaomi-fog`** (downstream 4.19.306, kernel
  `TQMatvey/linux-sm6225`): USB networking/RNDIS "works" per the archived
  wiki page; it confirms the USB hardware path on `fog` but does not provide
  adb or mainline code. The USBNET id is `05c6:9039`.
