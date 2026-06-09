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

- **Fedora 44 Server (ARM64)** on a **Raspberry Pi 5** (4 GB or 8 GB). The Pi 5 is the recommended target — its 4-core Cortex-A76 leaves enough headroom for one system core plus three isolated audio cores (`isolcpus=1-3`). The Pi 4 may work but is not yet a target of this wizard.
- Root access
- Internet connection (to fetch the kernel COPR and dependencies)
- A handful of host packages installed before running the wizard:

  ```bash
  sudo dnf -y install git curl grubby dnf-plugins-core tar
  ```

  `git` lets you clone this repo; `tar` extracts the Diretta SDK archive (no longer bundled in the Fedora 44 custom base); the others are used by the wizard itself (`curl` to fetch upstream scripts, `grubby` to set the kernel-rt as the default boot entry, `dnf-plugins-core` for `dnf copr enable`). Note: unlike the x86_64 wizard, no `mokutil` and no Secure Boot precondition — Secure Boot is not exposed by Raspberry Pi firmware.

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
- [ ] **`06-cpu-states`** — `intel_pstate` knobs (`no_turbo`, `max_perf_pct`) are no-ops on ARM; rework module 06 to detect ARM and use `cpufreq` governor + per-core `scaling_max_freq` instead. Memory/MM jitter reducers (THP, KSM, NUMA balancing) are arch-agnostic and stay as-is
- [ ] **`10-install-drup`** — pass `ARCH_NAME=aarch64-linux-15k16` to DRUP's `install.sh` on the Pi 5 (16 KiB pages); use `aarch64-linux-15` if Pi 4 support is added later. NEON SIMD path is auto-detected by DRUP, no flag needed
- [ ] **`11-install-slim2diretta`** — same ARM build target nuance as module 10
- [ ] **Newbie walkthrough** — add a Pi-specific bootstrap section (writing Fedora 44 Server ARM64 to the SD card / NVMe, first boot, SSH-from-LAN setup) before §11 "Run the wizard"
- [ ] **First `v0.1` tag** — once preflight + system-tuning + DRUP install run cleanly on a vanilla Fedora 44 ARM64 Pi 5 image, with no manual patches

## License

[MIT](LICENSE)

## Credits

This installer orchestrates and builds on the work of:

- [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) by Dominique COMET (cometdom)
- [slim2Diretta](https://github.com/cometdom/slim2Diretta) by Dominique COMET (cometdom)
- The Fedora Kernel Vanilla repositories maintained by [Thorsten Leemhuis (knurd)](https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories)
- All the testers and contributors of the Diretta audiophile community
