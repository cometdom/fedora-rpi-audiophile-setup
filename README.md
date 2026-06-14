# fedora-rpi-audiophile-setup

Turn a clean **Fedora 44 Server (ARM64)** install on a **Raspberry Pi 5** into a tuned audiophile playback host, ready to run [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) and/or [slim2Diretta](https://github.com/cometdom/slim2Diretta).

> **Status: WORK IN PROGRESS — early bootstrap.**
> This repo is the **ARM64 sibling** of [`fedora-audiophile-setup`](https://github.com/cometdom/fedora-audiophile-setup) (the x86_64 wizard, production at v1.5.0). The codebase is forked from the x86_64 wizard's `main` at `49114a9` and will be adapted module by module so the same workflow runs on a Raspberry Pi 5 host. Until that adaptation is complete you should expect rough edges — the x86_64 repo's `00-preflight` rejects non-x86_64 architectures, the `02-system-tuning` tuner has Intel/AMD vendor checks, and several optimisations are Intel-specific (`intel_pstate/no_turbo`, `intel_pstate/max_perf_pct`). All of those need ARM-aware equivalents or graceful skips.
>
> **What already works on this exact stack** (confirmed 2026-06-05 by an early tester on a Raspberry Pi 5 running Fedora 44 ARM64 with the `@kernel-vanilla/stable` COPR's aarch64 PREEMPT_RT kernel `7.0.11-301.vanilla.fc44.aarch64+rt`):
> - DRUP installed and running, ping latency ~50 µs over `eth-diretta` at MTU 9014
> - `isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3 irqaffinity=0` for 4-core isolation (one system core, three audio cores)
> - DRUP build target `aarch64-linux-15k16` for the Pi 5's 16 KiB pages
>
> **Track the x86_64 repo for the canonical design**; the docs and per-module rationale there apply almost verbatim to ARM64 — only the mechanism (Intel-specific syscalls, package names, etc.) needs porting.

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
- Optionally installs and configures DirettaRendererUPnP and/or slim2Diretta

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
   2) 00 preflight            — verify Fedora 43 / x86_64 / Secure Boot OFF / IPv6
   3) 01 kernel-rt            — install the PREEMPT_RT kernel...
   ...
  14) 99 finalize             — sanity check + offer reboot
  15) Exit

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

## Documentation

- **[Newbie walkthrough](docs/en/newbie-walkthrough.md)** — start here if you've never installed Linux. Goes from empty mini-PC to first listening test, no prior knowledge assumed. (**Français :** [guide pas à pas pour débutant](docs/fr/newbie-walkthrough.md))
- [Fedora 43 minimal install (custom)](docs/en/fedora-43-minimal-install.md) — terser install reference.
- [Post-install tuning reference](docs/en/post-install-tuning.md) — what each module does, and why.
- [Diretta NIC toggle](docs/en/diretta-net-toggle.md) — companion tool (`scripts/diretta-net-toggle.sh`) to temporarily bridge the LAN and Diretta NICs so the target is reachable from the LAN (e.g. to check/update its firmware) without recabling, then switch back for listening. systemd-networkd only. (**Français :** [bascule NIC Diretta](docs/fr/diretta-net-toggle.md))

## Roadmap

### Released

**Forked from** `fedora-audiophile-setup` at commit `49114a9` (post-v1.5.0). All historical x86_64 releases above that point are inherited in the git history of this repo. New tagged releases here will use ARM-specific version numbers (the first one will be `v0.1` — bootstrap).

### Inherited from fedora-audiophile-setup (x86_64)

- [x] v1.0 → v1.5 — entire feature set of the x86_64 wizard, see the [upstream Roadmap](https://github.com/cometdom/fedora-audiophile-setup#roadmap)

### ARM-specific work to land

- [x] **`00-preflight`** — replace the `[[ "$arch" == "x86_64" ]]` hard-fail with an `aarch64` allow path; drop Secure Boot check (no equivalent on RPi firmware); keep IPv6 and Fedora 44 checks
- [x] **`02-system-tuning`** — the DRUP `diretta-renderer-tuner.sh` (and its `-nosmt` variant) is now **arch-aware upstream**: on aarch64 `/proc/cpuinfo` carries none of the x86 topology fields, so physical-core detection falls back to sysfs `core_id` → else `nproc` (purely additive, x86 path unchanged). On the Pi 5 this yields the `isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3 irqaffinity=0` template. Module 02 here is unchanged — it fetches the fixed tuner from upstream. _Untested on hardware — awaiting a Pi 5 tester._
- [x] **`06-cpu-states`** — already arch-agnostic: the boot script is best-effort, so the `intel_pstate` knobs (`no_turbo`, `max_perf_pct`) simply fall through to the generic `cpufreq` paths on ARM (governor=performance pins the clock; per-core `scaling_max_freq` caps it). No behaviour change was needed — only the stale "x86_64 only" comments were corrected to acknowledge the Pi 5 (cpufreq-dt). Memory/MM jitter reducers (THP, KSM, NUMA balancing) are arch-agnostic and untouched. _Untested on hardware — awaiting a Pi 5 tester._
- [x] **`10-install-drup`** — the build target is auto-detected: DRUP's `Makefile` reads `uname -m` + `getconf PAGESIZE` and picks `aarch64-linux-15k16` on the Pi 5 (16 KiB pages) or `aarch64-linux-15` on the Pi 4 (4 KiB), so no `ARCH_NAME` override is needed. Module 10 now runs `./install.sh --full` (bypasses DRUP's menu, so the destructive "Aggressive Fedora optimization" option is unreachable) and warns the user to pick **FFmpeg 7.1** at the version sub-prompt — the default 8.0.1 is reported to fail on the Pi 5 (tester Dave). _Untested on hardware — awaiting a Pi 5 tester._
- [x] **`11-install-slim2diretta`** — like module 10: the build target is auto-detected (slim2Diretta's `CMakeLists.txt` reads `uname -m` + `getconf PAGESIZE`, with a devicetree-model fallback, → `aarch64-linux-15k16` on the Pi 5), so no override is needed; module 11 now runs `./install.sh --full` to bypass the menu and make its "Aggressive Fedora optimization" entry unreachable. No FFmpeg-version concern here (slim2Diretta links the distro `ffmpeg-free-devel`, it doesn't build FFmpeg from source). _Untested on hardware — awaiting a Pi 5 tester._
- [x] **Newbie walkthrough (EN + FR)** — Part A rewritten Pi-native in both languages: hardware (Pi 5, PSU, active cooler, SD/NVMe, RTL8156 USB-NIC), no-BIOS note, download the aarch64 `.raw.xz`, write to SD (Pi Imager/Etcher), first-boot text setup, grow the root filesystem (`parted` + `resize2fs`), note the IP. Parts B/C/TL;DR de-x86'd (dropped `mokutil`, fixed the clone URL that still pointed at the x86 repo), and a "pick FFmpeg 7.1" row added to §13.
- [ ] **First `v0.1` tag** — once preflight + system-tuning + DRUP install run cleanly on a vanilla Fedora 44 ARM64 Pi 5 image, with no manual patches

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
