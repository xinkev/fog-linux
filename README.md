# Redmi 10C (`fog`) — mainline Linux

Repo: `git@github.com:xinkev/fog-linux.git` · open work lives in **Issues**.

Kernel **7.3** + Ubuntu **26.04.1** from `cust`, based on upstream
[Damir00109/Redmi10c](https://github.com/Damir00109/Redmi10c) `v7.3.0`.
Slot A is stock MIUI Android and is the fallback.

Boots by **RAM boot** (`fastboot boot`) — writes no A/B slot. Persistent
slot-B install is possible but costs a retry each test (see AGENTS.md §5).

| Works (verified on this unit) | Known broken |
|---|---|
| Ubuntu 26.04 from `cust`, root **adb over USB** | **touch**: FTS probes, firmware download fails (`crc abnormal`) |
| DRM panel 720x1650 + fbcon (`card0-DSI-1: connected`) | Bluetooth: `hci0 frame reassembly failed` |
| Wi-Fi driver up, scans SSIDs (`wlan0`) | `regulatory.db` missing in initramfs |
| Charger/gauge, Type-C, keys, vibrator | WLAN MAC is upstream's (hardcoded in DTS) |
| Android on slot A untouched, 2 SIMs intact | audio/modem/GPS/sensors: upstream says working, **not verified here** |

Roadmap: **touch FW** (pull vendor blob from this phone) · Wi-Fi/BT polish ·
P2 grow `cust` (issue #4) · then audio/modem/GPU.

## Resuming in a new session

```
make doctor      # what exists here, what the phone is doing
gh issue list    # open work (issue #7 = this v7.3.0 sync)
```

Then read **RUNBOOK → Reproduce the build** and **RUNBOOK → Known issues**
before driving the phone.

## Commands

| Command | Does |
|---|---|
| `make doctor` | preflight: container, worktree, firmware, kernel, images, phone state |
| `make adb` | what adb is talking to (Linux/PBRP/Android) + cookbook |
| `make base` | worktree `v7.3.0` + firmware + 26.04 cloud image + `fog-v730` container |
| `make kernel` | kernel 7.3 + our fog DTS deltas (board-id, HS-PHY) + modules |
| `make image` | pack `boot-linux.img` (pivot initramfs) + `make verify` |
| `make rootfs` | build Ubuntu 26.04 `cust` image (sparse) |
| `make test` | RAM boot → wait adb → capture `adb-check.txt` → back to fastboot |
| `make test-slot` | legacy: flash slot B + cust (burns a retry if it fails) |
| `make verify` | boot image header / DTB / board-id check |
| `make logs` | summary of the last report pulled via PBRP |
| `make android` | back to stock MIUI |

## Layout

```
tools/        v730-build, build-rootfs-v730, v730-fog-dts, testboot-loop, doctor, verify-image, adb-status
build/        Dockerfile.v730 + the legacy 7.1.5 overlay/helpers (rain-reboot-bootloader)
Redmi10c-base/v730/   upstream v7.3.0 worktree (gitignored; kernel, rootfs, firmware)
docs/         CHANGELOG (why) · specs/ (design) · .scratch/ (logs, gitignored)
RUNBOOK.md    how to build, flash, recover, read logs        <- reference
UPSTREAM.md   the repo we started from, and where we diverge
```

## License

GPL-2.0-only — see [LICENSE](LICENSE). Port, patches and tooling derive from
[Damir00109/Redmi10c](https://github.com/Damir00109/Redmi10c) (GPL-2.0); see
[UPSTREAM.md](UPSTREAM.md). No vendor firmware, images or keys are included.

## Read next

- [RUNBOOK.md](RUNBOOK.md) — commands, recovery, known issues
- [UPSTREAM.md](UPSTREAM.md) — base, divergences, alternatives checked
- [docs/specs/2026-11-02-sync-v730.md](docs/specs/2026-11-02-sync-v730.md) — this sync
- [docs/CHANGELOG.md](docs/CHANGELOG.md) — newest first
