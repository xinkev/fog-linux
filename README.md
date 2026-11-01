# Redmi 10C (`fog`) — mainline Linux

Repo: `git@github.com:xinkev/fog-linux.git` · open work lives in **Issues**.

Linux boots on slot **B**; stock MIUI stays on slot **A** as the fallback.
**adb over USB works** (root shell), as does the framebuffer console.

| Works | Broken |
|---|---|
| Ubuntu 24.04 from `cust`, framebuffer console + login | USB ACM serial console (the ADB gadget owns the UDC) |
| **adb over USB** — `adb devices` → `rain device`, root shell | GPU scanout, audio, modem, camera, GPS, sensors |
| Test boot returns to fastboot by itself; logs pulled via PBRP | |
| Android on slot A untouched, 2 SIMs intact | |

Roadmap: **P2** grow `cust` → ~20 GB · **P3** Wi-Fi/BT/display/touch · **P4** GPU, audio, modem.

## Resuming in a new session

```
make doctor      # what exists here, what the phone is doing
gh issue list    # open work, newest decisions in the issue bodies
```

Then read **RUNBOOK → Using adb** before driving the phone: it has the
state table (Linux vs PBRP vs Android vs fastboot), the cookbook, the root
cause (32-bit DWC3 DMA), and the dead ends.

## Start here

```
make doctor   # what is missing on this machine / phone
make adb      # what adb is talking to + the cookbook
make test     # flash -> boot -> adb check -> self-reboot -> pull logs
```

The image self-reboots 45 s after its boot report; `adb shell rm
/etc/rain-autoreboot` keeps it up.

## Commands

| Command | Does |
|---|---|
| `make doctor` | preflight: docker images, kernel, images, phone state |
| `make adb` | what adb is talking to (Linux/PBRP/Android) + cookbook |
| `make test` | flash → boot → adb check → self-reboot → pull logs (~4 min) |
| `make test SKIP_CUST=1` | same, without the slow `cust` flash (~2 min) |
| `make logs` | summary of the last pulled boot report |
| `make rootfs` | install `build/overlay/` + adbd into the `cust` image |
| `make adbd-debs` | stage adbd debs and this host's adb public key |
| `make image` | rebuild `boot-linux.img`, then verify it |
| `make verify` | check header, DTB and board-id before flashing |
| `make kernel` | rebuild kernel + DTBs |
| `make patch` | apply `patches/fog-adb-usb.patch` (idempotent) |
| `make android` | back to stock MIUI |

## Layout

```
tools/        doctor, testboot-loop, watch-boot, serial-probe, fetch-adbd-debs
patches/      fog-adb-usb.patch (applied on top of the upstream kernel patch)
build/        Dockerfiles + overlay/ (units, scripts installed into cust)
docs/         CHANGELOG (why) · .scratch/ (logs, plans — gitignored)
RUNBOOK.md    how to build, flash, recover, read logs    <- reference
UPSTREAM.md   the repo we started from, and where we diverge
```

## License

GPL-2.0-only — see [LICENSE](LICENSE). Port, patches and tooling derive from
[Damir00109/Redmi10c](https://github.com/Damir00109/Redmi10c) (GPL-2.0); see
[UPSTREAM.md](UPSTREAM.md). No vendor firmware, images or keys are included.

## Read next

- [RUNBOOK.md](RUNBOOK.md) — commands, recovery, known gaps
- [UPSTREAM.md](UPSTREAM.md) — upstream base, works-there-not-here
- [docs/CHANGELOG.md](docs/CHANGELOG.md) — newest first
