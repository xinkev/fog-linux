# Redmi 10C (`fog`) — mainline Linux

Repo: `git@github.com:xinkev/fog-linux.git` · open work lives in **Issues**.

Linux boots on slot **B**; stock MIUI stays on slot **A** as the fallback.
One blocker left: USB never enumerates.

| Works | Broken |
|---|---|
| Ubuntu 24.04 from `cust`, framebuffer console + login | USB gadget — no adb, no serial console |
| Test boot returns to fastboot by itself; logs pulled via PBRP | GPU scanout, audio, modem, camera, GPS, sensors |
| Android on slot A untouched, 2 SIMs intact | |

Roadmap: **P2** grow `cust` → ~20 GB · **P3** Wi-Fi/BT/display/touch · **P4** GPU, audio, modem.

## Commands

| Command | Does |
|---|---|
| `make test` | flash → boot → self-reboot → pull logs (unattended, ~4 min) |
| `make logs` | summary of the last pulled boot report |
| `make rootfs` | install `build/overlay/` into the `cust` image |
| `make image` | rebuild `boot-linux.img` |
| `make kernel` | rebuild kernel + DTBs |
| `make android` | back to stock MIUI |

`make test` reflashes `cust` too; `make test SKIP_CUST=1` skips that (~2 min).

## Layout

```
tools/        testboot-loop, watch-boot, serial-probe
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
