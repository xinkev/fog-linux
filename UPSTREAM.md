# Upstream base

[Damir00109/Redmi10c](https://github.com/Damir00109/Redmi10c) — GPL-2.0.
Cloned at `Redmi10c-base/` (keeps its own `.git`; not tracked here).
Kernel 7.1.5 + `patches/redmi10c-mainline-20260813.patch`.

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
| Test loop | manual | `tools/testboot-loop.sh` (unattended) |
| Logs without a console | serial/UART | report written into `cust`, pulled via PBRP |
| `usb-force.py` | repo pokes | DCTL stop/start removed (corrupts the event ring) |

## Works there, not here

| Feature | Upstream | Here |
|---|---|---|
| USB enumeration | works on their sm6115 board | never enumerated; see RUNBOOK → Known gaps |
| `sm6225-xiaomi-fog-sm6115.dts` | boots | crash-loops before userspace (UFS/GPU off → no logs) |

## Works here, not there

- (none yet)
