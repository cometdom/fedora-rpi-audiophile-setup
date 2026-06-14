# Post-Install Tuning Reference

This document explains every tuning the wizard applies — what it changes, why it matters for audio playback, where the change is persisted, and how to revert it manually if needed.

The wizard always writes a full log to `/var/log/audiophile-setup/<timestamp>.log` so you can see exactly what happened on your specific machine.

## Module execution order

The modules in `modules/` are numbered (`00-` through `99-`) and executed in that order. You can run a single module with `sudo ./setup.sh --only <name>`.

| # | Module | What it does | Status |
|---|--------|--------------|--------|
| 00 | preflight | Verify Fedora 43/44, x86_64, Secure Boot off, IPv6 on; auto-install curl/mokutil/grubby/dnf-plugins-core | Done |
| 01 | kernel-rt | Install PREEMPT_RT kernel from `@kernel-vanilla/stable` COPR, verify RT by content, set it as the default GRUB entry | Done |
| 02 | system-tuning | Run the DRUP `diretta-renderer-tuner` (`apply`) for isolcpus/IRQ/slice/governor | Done |
| 03 | network-stack | Optional MAC-based NIC rename (`eth-lan`, `eth-diretta`); then keep NetworkManager (tuned) or switch to systemd-networkd | Done |
| 04 | tmpfs-disk | Make journald volatile, optionally move `/var/log` and `/var/tmp` to tmpfs | Done |
| 05 | services-cleanup | Disable bluetooth/cups/avahi/etc.; optionally disable firewalld and SELinux | Done |
| 06 | cpu-states | governor=performance, disable turbo/boost, disable deep c-states (systemd oneshot) | Done |
| 07 | sysctl-network | Bump global socket buffers (`rmem_max` / `wmem_max` / backlog). MTU + ethtool live in 10/11. | Done |
| 08 | tuned-profile | Install tuned, apply the `latency-performance` profile | Done |
| 09 | swap-disable | `swapoff -a` + `vm.swappiness=0` + comment swap out of `/etc/fstab` | Done |
| 10 | install-drup | Install DirettaRendererUPnP via its own `install.sh`, wire up `/etc/default/diretta-renderer` | Done |
| 11 | install-slim2diretta | Install slim2Diretta via its own `install.sh`, wire up `/etc/default/slim2diretta` | Done |
| 99 | finalize | Sanity-check every module's mark, then offer a reboot | Done |

---

## Module details

The authoritative, always-current description of each module is the header comment block at the top of the corresponding `modules/NN-*.sh` file (kept in sync with the code). The interactive prompts and recommended answers are summarised in the [newbie walkthrough §13](newbie-walkthrough.md#13-answer-the-per-module-prompts). The notes below give the "what and why" at a glance.

### 00 — preflight

Hard pre-conditions, all blocking: distribution is Fedora 43 or 44, architecture is x86_64, Secure Boot is OFF (the vanilla kernel-rt can't be signed), IPv6 is enabled (the Diretta protocol requires it). As a safety net it also installs the small CLI tools the wizard itself needs (`curl`, `mokutil`, `grubby`, `dnf-plugins-core`) if they're missing.

### 01 — kernel-rt

Enables the kernel-vanilla COPR and installs the realtime kernel, then makes it the default boot entry so the single planned reboot lands on the RT kernel:

```bash
dnf -y copr enable @kernel-vanilla/stable
dnf -y install kernel-rt kernel-rt-core kernel-rt-modules
grubby --set-default=/boot/vmlinuz-<rpm-derived V-R.arch>
```

Reference: https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories.

The vmlinuz is located **via RPM** (`rpm -q kernel-rt-core` → its exact `VERSION-RELEASE.ARCH` → `/boot/vmlinuz-<that>`), not by grepping file names — a kernel's RT-ness is not reliably encoded in its name. Before switching the default, the module **verifies `CONFIG_PREEMPT_RT=y`** in the target kernel's `/boot/config-*` and refuses to proceed otherwise. Idempotent: skips when kernel-rt is already installed and already the default. A previously installed kernel is kept (roll back from the GRUB menu).

> A `kernel-cachyos-rt` choice was prototyped in a v1.x branch and dropped — it failed to boot on the maintainer's hardware. The RPM-based detection and the RT content-check are the robustness gains retained from that work.

### 02 — system-tuning

Downloads the `diretta-renderer-tuner.sh` (or its `-nosmt` variant) from DirettaRendererUPnP and runs it with `apply`. The tuner handles:

- Kernel cmdline (`isolcpus`, `nohz_full`, `rcu_nocbs`, `irqaffinity`, optional `nosmt`)
- CPU governor service (`cpu-performance-diretta*.service`)
- Systemd slice with `AllowedCPUs`
- NIC IRQ affinity service
- Thread round-robin distribution on isolated cores

Fetched fresh so the module works even without DRUP installed (slim2Diretta-only setups). The tuner is **pinned to a specific known-good DRUP commit** (not the moving `main` branch), so a broken upstream commit can't break an unattended install; the SHA is bumped only after vetting on hardware.

**ARM / Raspberry Pi note.** `detect_cpu_topology()` reads x86-only `/proc/cpuinfo` fields (`vendor_id`, `model name`, `cpu cores`, `physical id` / `core id`). On ARM those greps miss; under the tuner's `set -o pipefail` the grep's exit 1 becomes the pipeline's status (even though the trailing `awk`/`cut`/`sed`/`wc` succeed), and with `set -e` that silently aborted the tuner right after printing `INFO: Detecting CPU topology...` — before the author's own ARM fallbacks (CPU implementer, devicetree model, sysfs `core_id`) could run. The pinned commit fixes this (`|| true` on those assignments), so detection completes correctly on the Pi 5 (4 physical cores, renderer CPUs `1-3`). Diagnosed by tester Auke.

### 03 — network-stack

Two consecutive steps.

**Step 1 — Stable interface naming by MAC** *(opt-in, default Y)*. Renames physical Ethernet NICs from PCI-volatile kernel names (`enp4s0`, `enp5s0`, ...) to stable role-based names (`eth-lan`, `eth-diretta`) so the host's configuration survives any hardware change that shifts PCI enumeration: NIC swap, added PCIe card, GPU insert/remove on a host without an integrated GPU. The wizard auto-detects the LAN NIC (default-route iface) and the Diretta NIC (the other physical Ethernet, when exactly two are present), shows a confirmation prompt, then writes `/etc/systemd/network/10-lan.link` and `/etc/systemd/network/10-diretta.link`, each matching by `MACAddress=` + `Type=ether`. `Type=ether` is essential: without it the bridge that `diretta-net-toggle` creates (which clones the LAN MAC onto `br0`) would be matched ambiguously alongside the physical NIC. Finally, `dracut -f` refreshes the initramfs so the rename applies on the very next boot — applied by udev before either NetworkManager or systemd-networkd starts, so the choice in Step 2 is independent.
Skipping Step 1 leaves the kernel-assigned names in place; nothing else changes. Re-running the module after a NIC swap is the prescribed migration path — pick the same roles for the new MACs and the `.link` files are rewritten in place.

**Step 2 — Network management stack**. Interactive choice between three options:

- **K — Keep NetworkManager (tuned)** *(default)*. Installs `NetworkManager-tui` if missing (so `nmtui` is available) and disables `NetworkManager-wait-online.service` to avoid boot delays. Minimises the lockout risk on SSH-only hosts. Fine NIC-side tuning (disabling MDNS / link-local resolution on the Diretta NIC) happens later in `install-drup` / `install-slim2diretta` once the interface is known.
- **S — Switch to systemd-networkd**. Opt-in for users who observe periodic dropouts on NetworkManager (Qobuz on some hardware) or want a fully deterministic stack. Generates a `.network` file per active physical Ethernet interface from the current NM state (DHCP or static), enables `systemd-networkd` + `systemd-resolved`, disables and masks `NetworkManager`, and limits `systemd-networkd-wait-online` to the WAN interface (the one with the default route) via a drop-in so a Diretta point-to-point NIC doesn't stall the boot for two minutes. **If Step 1 set up stable naming**, the `.network` files are generated against the stable names (`10-eth-lan.network` with `Name=eth-lan` etc.) so they keep matching after the next-boot rename — single coherent reboot resolves both rename and IP config in one go.
- **N — Skip**. Leaves the network stack untouched.

Generated files carry a `# Generated by fedora-audiophile-setup` header line. If a later run picks "Keep NetworkManager" while the host is currently on networkd, the module reverts the switch safely: it re-enables / unmasks NM, disables networkd, and removes only files bearing that header — files the user wrote by hand are left alone. The Step 1 `.link` files (`10-{lan,diretta}.link`) are stack-agnostic and stay in place across K/S/N choices; they are only ever removed by the user or rewritten by a fresh run of Step 1.

### 04 — tmpfs-disk

Two steps:

1. **Journald volatile** — a drop-in under `/etc/systemd/journald.conf.d/` sets `Storage=volatile`. Logs live in `/run/log/journal/` (already a tmpfs) and are cleared on reboot. journald is restarted so it takes effect immediately.
2. **Optional `/var/log` and `/var/tmp` as tmpfs** via `/etc/fstab` (asked interactively, default yes). `/var/tmp` keeps `mode=1777`. fstab entries are tagged so re-runs are no-ops.

### 05 — services-cleanup

Disables a fixed list of services and timers an audiophile host never needs (bluetooth, cups, avahi, ModemManager, packagekit, udisks2, abrt\*, fwupd\*, `dnf-makecache.timer`, `*-updatedb.timer`). `static` units (e.g. `cups.service`) are stopped rather than disabled. Two interactive prompts, both default **Y** on a dedicated host: disable `firewalld`, and disable SELinux (`setenforce 0` + `SELINUX=disabled` in `/etc/selinux/config`).

### 06 — cpu-states

Installs a systemd oneshot service plus its `/usr/local/sbin` script that, on every boot:

- sets `scaling_governor=performance` on every CPU
- disables turbo/boost (Intel pstate `no_turbo`, fallback `cpufreq/boost` for AMD/acpi-cpufreq)
- *(optional)* caps the max CPU frequency to `CPU_MAX_PCT` % of the hardware max — configured via `/etc/default/audiophile-cpu-states`. Intel pstate uses `max_perf_pct`; everything else falls back to writing `scaling_max_freq` per CPU. Empty/unset = no cap.
- disables c-states deeper than C0/C1 (cpuidle `state2+`)
- applies audio-friendly memory/MM tunings — removes the usual sources of background MM jitter: **Transparent Huge Pages** off (`enabled` and `defrag` → `never`, so `khugepaged` doesn't periodically scan/defrag), **Kernel Samepage Merging** off (`/sys/kernel/mm/ksm/run = 0`, no periodic page-merge scan), and **NUMA balancing** off (`/proc/sys/kernel/numa_balancing = 0`, no async page migration between NUMA nodes — a no-op on single-socket mini-PCs but consistent).

Best-effort writes (missing sysfs nodes skipped). Coexists with the DRUP tuner's governor service — both write the same values.

**Tuning the max-freq cap without re-running the wizard.** Edit `/etc/default/audiophile-cpu-states` (`CPU_MAX_PCT=50`, `=75`, empty…), then `sudo systemctl restart audiophile-cpu-states.service`. Audiophile lore: lower peak frequency draws less current → less perceived electrical noise on the DAC analog rail (subjective; Diretta itself needs very little CPU, so there is ample headroom to try lower values).

### 07 — sysctl-network

Strictly host-wide socket-buffer knobs, written to `/etc/sysctl.d/99-audiophile-network.conf` and reloaded via `sysctl --system`:

| Knob | Value | Purpose |
|---|---|---|
| `net.core.rmem_max` / `wmem_max` | 16 MB | Max per-socket buffer a process can request. |
| `net.core.rmem_default` / `wmem_default` | 4 MB | Buffer for sockets that don't request explicitly. |
| `net.core.optmem_max` | 64 KB | Ancillary cmsg room (multicast, hw-timestamping). |
| `net.core.netdev_max_backlog` | 5000 | Packets buffered between NIC IRQ and userland reads. |

**MTU and ethtool link tuning are not done here.** On a Diretta host there are typically two NICs (WAN/LAN at MTU 1500, Diretta point-to-point up to MTU 16128), and only the install modules know which NIC is which — so the MTU (a universal systemd-udevd `.link` drop-in, NM- and networkd-proof) and ethtool live in `10-install-drup` / `11-install-slim2diretta`.

### 08 — tuned-profile

Installs `tuned` if absent, enables it, and applies the built-in `latency-performance` profile. tuned is a conservative baseline; modules 06 and 07 layer their explicit values on top via systemd units that run after `multi-user.target`, so our values win on any overlap. Idempotent: skips the `tuned-adm profile` call when the target profile is already active.

### 09 — swap-disable

Four steps. **Step 0 — zram-generator (Fedora-specific).** Fedora installs `zram-generator`, which at every boot creates a compressed swap device (`/dev/zram0`) via `systemd-zram-setup@zram0.service` — entirely outside `/etc/fstab`. `swapoff -a` clears it at runtime, but the generator re-creates it on the next boot, so without this step swap silently returns. The module writes an empty `/etc/systemd/zram-generator.conf` (overrides the `/usr/lib` default → no `[zram0]` section → no device) and masks the unit; both are idempotent and a no-op when `zram-generator` isn't installed. (Found by tester Auke; affects x86 and ARM alike.) **Steps 1–3:** `swapoff -a` (probed via `/proc/swaps` first), `vm.swappiness=0` via `/etc/sysctl.d/99-audiophile-swap.conf`, and active swap lines in `/etc/fstab` commented out with a recognisable tag. fstab is backed up before edit. awk matches the fstab `swap` fstype on field 3, so device paths containing "swap" don't false-positive.

### 10 — install-drup

Optional (asked up front). Detects `SUDO_USER` (DRUP `install.sh` refuses root) and the manually-downloaded Diretta SDK under `~/DirettaHostSDK_*`. Pre-installs build deps, lets the user pick the Diretta-side NIC, then writes the **canonical Diretta `.link` drop-in** (`ensure_diretta_mtu_link` in `lib/common.sh`) at `/etc/systemd/network/10-diretta.link` — a single file matched by `MACAddress=` + `Type=ether` that carries three things at once: the rename to `eth-diretta` (if Step 1 of module 03 hadn't already established it), the chosen MTU, and a set of offload-off directives (`GenericSegmentationOffload`, `TCPSegmentationOffload`, `GenericReceiveOffload`, `LargeReceiveOffload`) — Diretta uses raw L2 frames that consumer NICs sometimes mishandle under hardware offloads, so these are always disabled on the Diretta NIC. udev applies only the first matching `.link` per device, so combining rename + MTU + offloads in a single file is mandatory (a separate MTU `.link` would be silently skipped — this was a real bug in pre-stable-naming installs). Read at coldplug, so it works under **both** NetworkManager and systemd-networkd; legacy `50-audiophile-diretta-*.link` files from earlier wizard versions are migrated (MTU value preserved, file removed) on the next module run. The module also pre-creates a NetworkManager profile for the NIC (using the stable name when configured) so DRUP `install.sh`'s own nmcli MTU step doesn't error (NM only); any legacy `diretta-<old-pci-name>` profile from a previous install is deleted as part of the migration. Then it clones DRUP, runs `./install.sh` (optionally `LLVM=1` for a Clang+LTO build), then `systemd/install-systemd.sh`, and post-processes `/etc/default/diretta-renderer` (`INTERFACE`, `TARGET_INTERFACE`, `TARGET` — written with the stable names when configured). DRUP's installer prompts for MTU again (nmcli-based, NM-only) — a harmless duplicate; give the same answer. Service is enabled but not started — it waits for the reboot.

### 11 — install-slim2diretta

Same shape as module 10, for slim2Diretta. Standalone (works without DRUP). Lighter — no FFmpeg-from-source. Reuses the Diretta-NIC choice, asks an optional LMS server IP, runs slim2Diretta's interactive `install.sh` (which deploys the binary, service and config itself), then post-processes `/etc/default/slim2diretta` (`TARGET`, `TARGET_INTERFACE`, optional `SLIM2DIRETTA_OPTS`). Service enabled, not started.

### 12 — pi-tweaks

Optional Raspberry Pi hardware tweaks, **entirely opt-in** (a gate prompt plus a per-tweak prompt, all default N). Pi-specific; reduces RF noise and background activity on a headless audio host.

- **Wi-Fi + Bluetooth off.** Primary method: blacklist the kernel modules (`brcmfmac`/`brcmutil` for Wi-Fi, `btbcm`/`hci_uart` for Bluetooth) in `/etc/modprobe.d/99-audiophile-disable-radios.conf`, then `dracut -f` so the blacklist is honoured at boot. Also `rfkill`-blocks them immediately, and — best-effort — appends `dtoverlay=disable-wifi`/`disable-bt` if a Pi `config.txt` is found (`/boot/efi`, `/boot/firmware`, `/boot`); Fedora's firmware-partition layout varies, so the module blacklist is what does the real work. Undo: delete the file, `sudo dracut -f`, reboot.
- **HDMI output off.** Adds `video=HDMI-A-1:d video=HDMI-A-2:d` to the kernel cmdline via `grubby` (idempotent). **Headless only — no console video afterwards**; only enable it where you can administer over SSH. Undo: `sudo grubby --update-kernel=ALL --remove-args="video=HDMI-A-1:d video=HDMI-A-2:d"`.

The module blacklist and the kernel cmdline are the reliable parts; the `config.txt` overlay is best-effort. _Untested on hardware — awaiting a Pi tester._

### 99 — finalize

Pure inspection — touches nothing. For each module the wizard ran, the finalizer looks for the mark that module would have left (kernel-rt installed and default boot entry, journald drop-in, fstab tmpfs entries, sysctl drop-ins, `audiophile-cpu-states.service`, tuned profile, swap status, jumbo MTU on a NIC, the renderer services). Each line prints either `[OK]` or `[--]`. A `[--]` is not a failure — it just means the matching module was skipped or its target was optional.

After the summary, the user is prompted `Reboot now? [y/N]` (default N — gives you time to inspect first). The whole point of the wizard is to apply everything in one pass and reboot once; the finalizer is where that reboot happens (or where you copy the suggested verification commands and reboot yourself).

---

## Reverting

The wizard does **not** provide a per-module rollback (a deliberate design choice — see [design-notes](design-notes.md)). It is safe to re-run instead: every module is idempotent and converges rather than stacking changes.

To undo a change by hand, the generated artefacts are easy to find — they are tagged or live in well-known paths:

- Files carrying a `# Generated by fedora-audiophile-setup` (or `# audiophile-setup`) header: the systemd-networkd `.network` files, the journald and sysctl drop-ins, the swap fstab lines.
- `audiophile-cpu-states.service` + `/usr/local/sbin/audiophile-cpu-states.sh`.
- `tuned-adm profile balanced` reverts module 08.
- `grubby --set-default` to an earlier kernel reverts the boot side of module 01 (the package can stay installed).
- The DRUP / slim2Diretta services have their own `uninstall-systemd.sh` (DRUP) / reinstall path.

`fstab` is backed up to `fstab.audiophile-bak.<timestamp>` before the swap edit, so the original is always recoverable.
