# AGENTS.md

Occasional guessing is fine but almost always prefer evidence based approach. Follow literally.

## 0. Git = durable knowledge, not working state
- **In git:** specs, runbooks/procedures, changelog.
- **Never in git:** todos, live status, scratch notes. Those go to GitHub
  Issues or `docs/.scratch/` (gitignored, deleted when the task closes).

## 1. Before work

Start every session with `make doctor` and `gh issue list`; the open work lives
in issues, not in this tree. `make doctor` says whether the phone is Linux
(`adb shell` is root), PBRP, Android or fastboot; `make adb` prints the adb
cookbook.

**From Linux, `adb reboot bootloader` only does a normal reboot** — systemd
cannot pass a reboot reason, so ABL picks a slot instead of fastboot. Use
`make bootloader` (`tools/to-bootloader.sh`): it pushes the static helper that
issues `reboot(2)` with `RESTART2 "bootloader"`, then waits for fastboot. The
same command is harmless when the phone is already in fastboot.

| Task | Artifact |
| --- | --- |
| New design | `docs/specs/<date>-<slug>.md` — goal, non-goals, acceptance, risks |
| Multi-step | GitHub Issue on `xinkev/fog-linux` — **not in git**. Fallback until `gh` is installed: `docs/.scratch/plans/<date>-<slug>.md` |
| Port-level | edit `RUNBOOK.md` / `UPSTREAM.md` / `README.md` in place |

## 2. Layout
`README.md` entry point · `RUNBOOK.md` how · `UPSTREAM.md` base + divergences ·
`docs/CHANGELOG.md` why · `tools/` scripts · `build/` docker + overlay ·
`docs/.scratch/` logs and plans (gitignored) · `Redmi10c-base/` upstream clone (gitignored).

## 3. After work
- Append to `docs/CHANGELOG.md` (newest first):
  `- <date> — <what> — <why> — files: … — verified: …`
- Status at milestones only ("P1 done"). No per-task checkboxes, no todo lists.

## 4. Hygiene
- Bullets; link, don't copy. Trivial fix → changelog line only.
- Never commit secrets, IMEI, serials, MACs, vendor firmware, or build outputs.

## 5. Never iterate on the A/B slots

Flashing `boot_b` + `--set-active=b` is a money sink on this device. ABL hands a
slot 7 retries (`slot-retry-count`, reset by `--set-active`); Linux never calls
`markBootSuccessful`, so every test boot spends one, and at 0 ABL marks the slot
unbootable and silently boots Android. The result looks like "our image was
rejected" when nothing is wrong with the image — and each wasted cycle costs a
~90 s Android boot plus a model round.

- **A test boot that lands in Android is a slot-accounting artifact, not
  evidence about the kernel or DTB.** Never draw a conclusion from it.
- Prefer `fastboot boot <img>` (RAM boot): it writes no slot and cannot corrupt
  slot state. Fall back to slot flashing only if RAM boot refuses the image.
- If a slot boot is unavoidable: flash, then `fastboot --set-active=b`, then
  verify `current-slot: b` and `slot-retry-count:b: 7` immediately before
  `fastboot reboot`. `--set-active` does **not** reboot by itself.
- `tools/testboot-loop.sh` already encodes all of this; use it instead of
  driving fastboot by hand.
