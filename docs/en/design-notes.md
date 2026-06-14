# Design Notes

Concise record of the design decisions taken when bootstrapping this project (2026-05-14). Read this before adding a new module or changing the architecture so you don't fight choices that were made on purpose.

## Scope

Turn a **clean Fedora 43 or 44 minimal install** into a tuned audiophile playback host for [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) and/or [slim2Diretta](https://github.com/cometdom/slim2Diretta).

**In scope:**
- x86_64 Fedora 43 or 44 (the two currently-supported Fedora releases — keeps testing surface small, accommodates users that started on 43 and those landing fresh on 44)
- All system-level tunings already documented in DRUP / slim2Diretta READMEs and wrapper scripts
- Optional install + configuration of DRUP and/or slim2Diretta

**Out of scope (for v0.1):**
- Raspberry Pi / ARM64 / other distros — would be a separate sibling repo if demand emerges
- Disabling IPv6 — **IPv6 is REQUIRED for the Diretta protocol**, must stay enabled
- Per-module rollback machinery — user can re-run with corrections; idempotency makes this safe
- Compile vanilla preempt-rt kernel from source — superseded by the COPR path below; could be a v0.3 advanced option

## Key architectural choices

### RT kernel via COPR, not from-source

Use `@kernel-vanilla/stable` COPR (maintained by Thorsten Leemhuis since 2012):

```bash
sudo dnf -y copr enable @kernel-vanilla/stable
sudo dnf install kernel-rt kernel-rt-core kernel-rt-modules
```

Reference: https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories

PREEMPT_RT is non-negotiable — it is the project pillar and the rest of the
stack (preflight, tuner, docs) assumes it. The vmlinuz to set as default is
located **via RPM** (`rpm -q kernel-rt-core` → `/boot/vmlinuz-<V-R.arch>`),
not by file-name matching, and `01-kernel-rt` **verifies `CONFIG_PREEMPT_RT=y`
by content** before `grubby --set-default` — a kernel's RT-ness is not
reliably visible in its file name. The previously installed kernel is not
removed, so a bad boot is one GRUB menu pick away from recovery.

**A `kernel-cachyos-rt` choice was prototyped and rejected** (v1.x branch):
the ecosystem (DRUP Fedora guide, Auke, forum) favours CachyOS-RT, but on
the maintainer's hardware `kernel-cachyos-rt` failed to boot — unacceptable
for an option aimed at newbies. The RPM-based detection and the RT
content-check above are the robustness gains kept from that prototype. The
non-RT `kernel-cachyos-lto` was never in scope (it drops PREEMPT_RT); note
there is no ready-made RT+LTO package anyway (RT is GCC-only, LTO non-RT-only).

**Pre-condition:** Secure Boot must be OFF in BIOS (the vanilla kernels
can't be signed). The `00-preflight` module enforces this.

### Modular dispatcher

`setup.sh` discovers and runs `modules/NN-name.sh` files in numbered order. Each module does ONE thing and can be invoked alone via `--only <name>`. Module discovery logic lives in `lib/common.sh` (`list_modules`, `resolve_module_path`).

Modules **must** be idempotent: every module first checks "already applied?" and skips if so. Re-running `setup.sh` should converge, not break.

### Single run, single reboot

The wizard configures everything in one pass — kernel install, GRUB cmdline, systemd-networkd switch, tmpfs, etc. The user reboots **once at the end**. No intermediate reboots, no state-resume machinery.

This works because:
- All changes are filesystem-level (not runtime-dependent on the new kernel)
- The wizard can configure GRUB to boot the newly-installed `kernel-rt` by default, and that takes effect on reboot
- Anything that needs runtime application (sysfs writes, systemd starts) is handled by the existing `start-renderer.sh` / `start-slim2diretta.sh` wrappers and their associated systemd services

### Reuse, don't rewrite

The installer is an **orchestrator**. It does not duplicate logic from existing assets:

| Asset | Reused by |
|---|---|
| `DirettaRendererUPnP/diretta-renderer-tuner.sh` (+ `-nosmt` variant) | Module `02-system-tuning` |
| `DirettaRendererUPnP/start-renderer.sh` | Module `10-install-drup` writes the `.conf` it consumes |
| `DirettaRendererUPnP/install.sh` | Module `10-install-drup` invokes it |
| `slim2Diretta/install.sh` | Module `11-install-slim2diretta` invokes it |
| `slim2Diretta/start-slim2diretta.sh` | Module `11-install-slim2diretta` writes the env file it consumes |

If a tuning is already implemented by a reusable asset, the installer calls that asset. If not (e.g. systemd-networkd switch, tmpfs, swap-disable), the installer ships its own module.

### CLI surface

- `sudo ./setup.sh` — full interactive wizard
- `sudo ./setup.sh --dry-run` — preview every action, apply nothing
- `sudo ./setup.sh --only <module>` — run a single module by short name (e.g. `kernel-rt`)
- `sudo ./setup.sh --help` — usage + list of available modules

No `--verbose` flag: a full timestamped log is always written to `/var/log/audiophile-setup/<YYYYMMDD-HHMMSS>.log`. Console output stays concise.

No `--config <file>` mode for v0.1 — purely interactive. Will be added later if needed for unattended provisioning (Ansible-like use case).

## Documentation

English-first (max international reach, consistent with DRUP / slim2Diretta READMEs). French and Spanish translations will follow once the English content is stable. Each translation starts with:

```html
<!-- Translated from EN docs v0.X — last sync: YYYY-MM-DD -->
```

so we can tell when a translation is in sync with the source.

The companion guide `docs/en/fedora-43-minimal-install.md` covers the **pre-requisite**: how to install Fedora 43 minimal custom (BIOS settings, ISO choice, partitioning, package selection). The wizard itself **assumes** the user has a clean base — it does not bootstrap from a live ISO.

## Style and conventions

- Bash, `set -euo pipefail` at the top of every script
- 4-space indent
- Shellcheck-clean (run `shellcheck modules/*.sh lib/*.sh setup.sh` before committing)
- Logging via `log_info` / `log_warn` / `log_error` / `log_step` from `lib/common.sh`
- Side effects via `run_cmd <cmd...>` (honors `DRY_RUN`)
- Module filename: `NN-short-name.sh` where `NN` is the execution order (00..99)
- Each module is `source`d from `setup.sh`, not run as a subprocess — they share `lib/common.sh` and globals

## Origin

Bootstrap session: 2026-05-14, branch `main`, initial commit. See `git log --reverse` to walk the history from the start.

## Testers

The ARM port was hardened on real hardware by early testers on the Audiophile Style forum (the maintainer owns no Pi). Their reports drove several fixes: **Auke** — the tuner `pipefail` abort on ARM and Fedora's `zram-generator` swap persistence (with patches); **ditusade** — first Pi 5 end-to-end proof and the RT-kernel-default (`+rt` vmlinuz) bug; **Progman** — first Pi 4 run, the low-RAM FFmpeg 7.1 / no-LTO path, and the full-install resilience. See the README for details.
