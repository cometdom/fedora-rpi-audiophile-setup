# fedora-rpi-audiophile-setup

Turn a clean **Fedora 44 Server (ARM64)** install on a **Raspberry Pi 5** into a tuned audiophile playback host, ready to run [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) and/or [slim2Diretta](https://github.com/cometdom/slim2Diretta).

> 🆕 **First time installing Linux on a Raspberry Pi?** Read the step-by-step newbie walkthrough first — it takes you from a bare Pi 5 to first listening test, no prior knowledge assumed.
> Available in: **English** ([web](docs/en/newbie-walkthrough.md) · [PDF](https://github.com/cometdom/fedora-rpi-audiophile-setup/releases/latest/download/newbie-walkthrough-en.pdf)) · **Français** ([web](docs/fr/newbie-walkthrough.md) · [PDF](https://github.com/cometdom/fedora-rpi-audiophile-setup/releases/latest/download/newbie-walkthrough-fr.pdf))

> **Status: v2.4.2** — Production-ready on Fedora 44 ARM64 (Raspberry Pi 5). Full functional parity with the [x86_64 sibling](https://github.com/cometdom/fedora-audiophile-setup). All modules implemented and validated on real hardware.

## What it does

An interactive Bash wizard that, in a single run, applies all the system-level tuning that has been documented and battle-tested for low-latency network audio playback on Linux:

- Installs the **PREEMPT_RT kernel** from the official Fedora [`@kernel-vanilla/stable` COPR](https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories) and sets it as the default boot entry (RT-ness verified by content before switching the default)
- Configures kernel cmdline for **CPU isolation** (`isolcpus`, `nohz_full`, `rcu_nocbs`, `irqaffinity`, optional `nosmt`)
- Lets you **keep NetworkManager (tuned)** or **switch to systemd-networkd** — your call. The default keeps NM (safer on SSH-only hosts, `nmtui` available); networkd is opt-in for the most deterministic stack.
- Sets the CPU governor to **performance**, disables C-states, no_turbo
- Pins NIC IRQs and audio threads to dedicated cores via the [DRUP tuner scripts](https://github.com/cometdom/DirettaRendererUPnP/blob/main/diretta-renderer-tuner.sh)
- Configures **MTU (up to 16128)** and ethtool link tuning on the Diretta NIC (during the DRUP / slim2Diretta install steps, where the right NIC is known)
- Moves `journald` to RAM and optionally `/var/log` + `/var/tmp` to tmpfs (reduces disk activity during playback)
- Disables `swap`, sets `vm.swappiness=0`
- Disables unneeded services (bluetooth, cups, etc.)
- Applies a `tuned` profile geared for latency
- Optionally installs and configures DirettaRendererUPnP, slim2Diretta and/or slim2UPnP (a Slimproto→UPnP bridge that pairs with DRUP for LMS)
- Optionally runs the **entire root filesystem from RAM** (module 14): full overlayfs mode via a custom dracut initramfs module (zero disk/SD I/O during playback), or `systemd.volatile=state` for a lighter `/var`-only approach
- Optional Raspberry Pi hardware tweaks (opt-in): disable the onboard Wi-Fi + Bluetooth radios, and/or disable HDMI output on a headless host

After a single reboot, your audio host is fully tuned and ready.

## Requirements

- **Fedora 44 Server (ARM64)** on a **Raspberry Pi 5** (4 GB or 8 GB). The Pi 5 is the recommended target — its 4-core Cortex-A76 leaves enough headroom for one system core plus three isolated audio cores (`isolcpus=1-3`).
- Root access
- Internet connection (to fetch the kernel COPR and dependencies)
- A handful of host packages installed before running the wizard:

  ```bash
  sudo dnf -y install git curl grubby dnf-plugins-core tar
  ```

  `git` lets you clone this repo; `tar` extracts the Diretta SDK archive (no longer bundled in the Fedora 44 custom base); the others are used by the wizard itself (`curl` to fetch upstream scripts, `grubby` to set the kernel-rt as the default boot entry, `dnf-plugins-core` for `dnf copr enable`). Note: unlike the x86_64 wizard, no `mokutil` and no Secure Boot precondition — Secure Boot is not exposed by Raspberry Pi firmware.

> **Raspberry Pi 4 — experimental.** The Pi 4 is not an official target yet, but it *should* work: `00-preflight` warns rather than blocks on a non-Pi-5 board, and the Diretta build target is auto-detected from the page size (the Pi 4's 4 KiB pages → the `aarch64-linux-15` SDK variant, vs the Pi 5's 16 KiB `…-15k16`). Two things to know before trying:
> - **Use an 8 GB Pi 4, or answer N to "Build with Clang + LTO".** The LTO FFmpeg build can peak at 4–6 GB, and `09-swap-disable` turns swap off before the build runs — on a 2–4 GB board it may be OOM-killed. (Same caveat applies to a 4 GB Pi 5.)
> - The build is slower than on a Pi 5 (Cortex-A72 vs A76), and the [newbie walkthrough](docs/en/newbie-walkthrough.md) is worded for the Pi 5 (e.g. it mentions the Pi 5's 27 W PSU — the Pi 4 uses a 15 W USB-C supply); the steps are otherwise the same.
>
> If you try it, a short report (works / what broke) is very welcome — it's what would promote the Pi 4 from "should work" to a supported target.

## Quick start

```bash
git clone https://github.com/cometdom/fedora-rpi-audiophile-setup.git
cd fedora-rpi-audiophile-setup
sudo ./setup.sh
```

The wizard opens with an **interactive numbered menu** :

```
What do you want to do?

   1) Full install              all modules in order (recommended)
   2) 00 preflight            — verify Fedora 44 / aarch64 / IPv6
   3) 01 kernel-rt            — install the PREEMPT_RT kernel...
   ...
  18) 99 finalize             — sanity check + offer reboot
  19) Exit

Choose [1]:
```

Press Enter (or `1`) for the full install. Any other number runs that single module standalone. The two-digit prefix shown next to each name (`00`, `01`, …, `99`) is the module number — that's the same `NN` you'll see in the file names (`modules/NN-name.sh`) and in the documentation; the leading number (`2)`, `3)`, …) is the menu choice. They differ because the menu has extra entries (Full install, Exit) that aren't modules.

Use `--dry-run` to preview every action without applying changes — works with both the menu and `--only`:

```bash
sudo ./setup.sh --dry-run
```

Power-user shortcut: skip the menu and re-run a single module by name:

```bash
sudo ./setup.sh --only kernel-rt
```

### Unattended mode

For scripted installs — a kickstart `%post`, CI, or fleet provisioning — the whole wizard can run without a TTY:

```bash
sudo ./setup.sh --unattended
sudo ./setup.sh --unattended --answers my-answers.env
```

Every prompt takes its default; an answers file overrides any of them through `UA_<KEY>` variables (one per prompt — the full list, with each prompt's default, is in [`extras/answers-example.env`](extras/answers-example.env)):

```bash
# my-answers.env — headless appliance: RAM mode on, no Diretta apps
UA_RAM_MODE_ACTION=e
UA_RAM_MODE_STRATEGY=V
UA_RAM_MODE_ENABLE=Y
UA_DRUP_INSTALL=N
UA_S2D_INSTALL=N
```

`--dry-run --unattended` previews the whole run, answers included. An invalid answer that a prompt loop keeps rejecting aborts the run (fail-fast) rather than looping forever.

## Documentation

- **[Newbie walkthrough](docs/en/newbie-walkthrough.md)** — start here if you've never installed Linux on a Raspberry Pi. Goes from a bare Pi 5 to first listening test, no prior knowledge assumed. (**Français :** [guide pas à pas pour débutant](docs/fr/newbie-walkthrough.md))
- [Post-install tuning reference](docs/en/post-install-tuning.md) — what each module does, and why.
- [Diretta NIC toggle](docs/en/diretta-net-toggle.md) — companion tool (`scripts/diretta-net-toggle.sh`) to temporarily bridge the LAN and Diretta NICs so the target is reachable from the LAN (e.g. to check/update its firmware) without recabling, then switch back for listening. systemd-networkd only. (**Français :** [bascule NIC Diretta](docs/fr/diretta-net-toggle.md))
- [Unattended answers contract](docs/en/unattended-answers-contract.md) — the `UA_<KEY>` stability guarantee for anyone automating `setup.sh --unattended` (kickstart, CI, or a GUI/web frontend).

## Roadmap

### Released

- [x] **v1.0.0** — First tagged ARM64 release. Wizard runs end-to-end on a Raspberry Pi 5 (Fedora 44 ARM64, PREEMPT_RT kernel from `@kernel-vanilla/stable`, DRUP + slim2Diretta). Validated on real hardware by Auke, ditusade and Progman.
- [x] **v1.0.1** — Wi-Fi NIC detection fix in the USB-NIC probing path
- [x] **v1.0.2** — Newbie walkthrough updated to cover slim2UPnP (module 12) prompts in the step-by-step table (EN + FR)
- [x] **v1.0.3** — DRUP tuner re-pinned to a fixed upstream commit (grubby cmdline regression fix)
- [x] **v1.1.0** — Wizard menu sample and documentation refreshed for modules 12 (slim2UPnP) and 13 (Pi tweaks)
- [x] **v1.2.0** — Universal Diretta MTU persistence via a systemd-udevd `.link` drop-in — works under **both** NetworkManager and systemd-networkd
- [x] **v1.3.0** — `diretta-net-toggle` companion tool: temporarily bridge LAN + Diretta NICs so the target is reachable from the LAN without recabling, then switch back for listening. systemd-networkd only.
- [x] **v1.4.0** — Module number (`NN`) shown next to each menu row for easier cross-reference with file names and documentation
- [x] **v1.5.0** — Stable interface naming by MAC (opt-in, default Y): NICs renamed to `eth-lan` / `eth-diretta` via udev `.link` drop-ins. CPU max-frequency cap (`/etc/default/audiophile-cpu-states`). Memory/MM jitter reducers (THP, KSM, NUMA balancing).
- [x] **v2.0.0** — **RAM mode** (module 14): run the entire root filesystem from RAM via full overlayfs (custom dracut initramfs module, zero disk/SD I/O during playback) or `systemd.volatile=state` (lightweight `/var`-only variant). Per-core CPU tuning CLI (`scripts/cpu-states-tune.sh`). Functional parity with `fedora-audiophile-setup` v2.0.0. Validated on ARM64 (Fedora 44, Pi 5) by Auke.
- [x] **v2.1.0** — `99-finalize` reporting fixes: DRUP false-negative in the systemctl check, slim2UPnP detection added (with a binary fallback), extended RAM-mode live status.
- [x] **v2.2.0** — FFmpeg 8.0.1 minimal confirmed working on Pi 5 (`10-install-drup`), FFmpeg menu references updated for DRUP v2.5.7, and a **RAM-mode warning at wizard launch**: `setup.sh` now warns *before any action* when the running session discards writes on reboot (overlayfs: everything is lost; `systemd.volatile`: `/var` only). Detection reads `/proc/cmdline` (the kernel actually running), not `grubby` (which reports the *next* boot). Reported by Auke.
- [x] **v2.3.0** — **Unattended mode** (`--unattended`, `--answers`): the entire wizard runs without a TTY, every prompt driven by `UA_<KEY>` environment variables. Enables scripted appliance builds, kickstart `%post`, and CI provisioning. `extras/answers-example.env` lists all keys with their defaults. Ported from the x86 sibling (Bertrand Clech / renesenses), with Pi-specific keys (`PI_TWEAKS`, `PI_TWEAKS_WIFI_BT`, `PI_TWEAKS_HDMI`).
- [x] **v2.3.1** — RAM-mode disable bug fix: id-based BLS targeting fixes `Disable` sometimes leaving `audiophile.overlay=1` in the boot cmdline (ambiguous `grubby --update-kernel=DEFAULT` resolution when the recovery entry shares a kernel path). The module now reads `saved_entry` from grubenv, edits the BLS entry directly, and verifies every add/remove. A reboot prompt is offered immediately after disable. Reported and fixed by Auke.
- [x] **v2.3.2** — RAM-mode preflight `/boot` space check: `dracut -f` briefly needs room for the old *and* new initramfs at once (it writes a `.tmp` file next to the existing image before replacing it) — a small `/boot` with several kernels retained can run out mid-rebuild with a cryptic zstd "No space left on device" error. The module now checks free space before calling dracut and fails with an actionable message instead. Ported from the x86 sibling after a user report (hd3291).
- [x] **v2.3.3** — Module 04's optional `/var/tmp` tmpfs (256M) starved dracut's own initramfs build directory on every subsequent kernel update — the same cryptic "No space left on device" as v2.3.2, but from a different cause: plenty of room on `/boot`, none in dracut's scratch space. Now redirects dracut's `tmpdir` to `/tmp` (not resized by this repo) alongside the `/var/tmp` tmpfs entry. Ported from the x86 sibling after a live diagnosis on Dominique's TuneOS box.
- [x] **v2.4.0** — RAM-mode gains a **Persistent paths** option (module 14, new `P` menu choice): bind-mount an app's mutable state from `/home` (untouched by either RAM-mode strategy) onto the path it actually expects, so it survives reboots even though `/var` — or all of `/` under overlay — is otherwise wiped every time. Auto-detects installed apps and offers two verified presets (Lyrion Music Server, Tune Server's self-updating `/opt/tune`), migrates existing data on first enable, and a symmetric removal restores it. Independent of the Enable/Disable choice. Ported from the x86 sibling, inspired by a HiFi-forum member's manual LMS bind-mount setup; validated end-to-end on real hardware (add, reboot-survival, remove/restore) — one stdin-redirection bug in the removal prompt found and fixed along the way.
- [x] **v2.4.1** — Newbie walkthrough (EN + FR) updated to cover v2.4.0's `P` (Persistent paths) prompt for module 14.
- [x] **v2.4.2** — Two Persistent-paths bugs found while wiring this into Tune OS, reported by Bertrand Clech (renesenses): the Tune Server preset only detected `tune-server.service` — a name inferred from the binary/`WorkingDirectory`, never actually confirmed against a real unit file — and so silently never matched Tune OS's real unit (`tune.service`); no error, no prompt, just skipped. Separately, `RAM_MODE_ACTION=e` never reached the persistent-paths questions in a single unattended pass (the dispatch was a single-choice `case`), so `UA_RAM_PERSIST_TUNE=Y` had no effect unless the wizard was re-run separately with `action=p`. Fixed: the preset now checks a comma-separated list of candidate unit names (`tune.service,tune-server.service`), and enabling RAM mode (`E`) now automatically walks into the Persistent-paths questions right after — one pass covers both. Ported from the x86 sibling.

### Planned

- [ ] Optional advanced path: compile the vanilla PREEMPT_RT kernel from source
- [x] Optional config-file mode for unattended provisioning

## Optional companion — Lyrion Music Server (LMS)

`extras/lyrion-fedora.sh` is an **optional** installer for [Lyrion Music Server](https://lyrion.org/) (formerly Logitech Media Server), contributed by tester **Auke**. It is **not** part of the wizard's main install — run it on its own:

```bash
sudo ./extras/lyrion-fedora.sh
```

LMS is a music **server** (library, scanning, transcoding, web UI on `:9000`). The audiophile-preferred topology runs it on a **separate box** and keeps this Pi a minimal player — co-locate it on the same Pi only if you don't have another server. It pairs naturally with the **slim2Diretta** player (module 11) for a self-contained server + player on one Pi. The menu also offers a **cpu0-only** mode that pins LMS to core 0, leaving the isolated audio cores free.

Arch-aware: the LMS RPM is **noarch** (one package for every architecture), so the same auto-resolved download works on both aarch64 and x86_64, and the only arch-specific bit (the bundled `sox` helper path, `Bin/<arch>-linux/`) is derived at runtime. Originally tested on aarch64 (Raspberry Pi); an x86_64 confirming run is welcome.

## Versioning

Releases follow [semver](https://semver.org/) (`vMAJOR.MINOR.PATCH`) and are marked with **annotated** git tags (`git tag -a`).

**A published tag is never rewritten or force-moved.** Once `vX.Y.Z` is pushed, it points at that commit forever — safe to pin against in downstream projects, packaging, or CI.

## License

[MIT](LICENSE)

## Credits

This installer orchestrates and builds on the work of:

- [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) by Dominique COMET (cometdom)
- [slim2Diretta](https://github.com/cometdom/slim2Diretta) by Dominique COMET (cometdom)
- The Fedora Kernel Vanilla repositories maintained by [Thorsten Leemhuis (knurd)](https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories)
- All the testers and contributors of the Diretta audiophile community

### Raspberry Pi early testers

Special thanks to the early testers on the Audiophile Style forum who ran this build on real Pi 4/5 hardware, reported precise bugs, and often supplied the fix:

- **Auke** — diagnosed the tuner's `pipefail` abort on ARM (all four x86-only `/proc/cpuinfo` greps, with a `bash -x` trace) and Fedora's `zram-generator` swap persistence; provided patches and documentation notes.
- **ditusade** — first proved the full stack on a Pi 5, and surfaced the RT kernel not being set as the default boot entry (the `+rt` vmlinuz mismatch).
- **Progman** — first Pi 4 run; validated the low-RAM FFmpeg 7.1 / no-LTO build path, and surfaced the full-install fragility now hardened with per-module resilience.
