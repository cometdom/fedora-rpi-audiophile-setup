#!/bin/bash
#
# 02-system-tuning — apply system-level tuning via the DRUP tuner script.
#
# Delegates to diretta-renderer-tuner.sh (or its -nosmt variant) from
# DirettaRendererUPnP, which configures:
#   - kernel cmdline (isolcpus, nohz_full, rcu_nocbs, irqaffinity, opt. nosmt)
#   - cpu-performance-diretta*.service
#   - systemd slice with AllowedCPUs
#   - NIC IRQ affinity service
#   - thread round-robin on isolated cores
#
# The script is fetched fresh from raw.githubusercontent.com so this module
# is usable even when DRUP itself is not installed (e.g. slim2Diretta-only).
#
# Idempotency: if cpu-performance-diretta*.service is already installed, we
# treat the tuning as applied and skip by default (user can force re-run).
#

set -euo pipefail

# Pinned to a specific known-good commit, NOT the moving 'main' branch: the
# tuner is downloaded and executed at install time, so a broken commit on
# DRUP's main would break every wizard run (this bit us twice on ARM — a
# device-tree read and then a pipefail+grep abort, both in detect_cpu_topology,
# silently took the whole full-install down). Bump this SHA only after vetting
# a newer tuner on real hardware.
# Bump history: e901c4f = pipefail fix (|| true on the /proc/cpuinfo greps) so
# the ARM fallbacks run; ef025ef = set the kernel cmdline via grubby (Fedora/BLS)
# instead of editing /etc/default/grub + grub2-mkconfig, which silently never
# applied the CPU-isolation params on Fedora aarch64. Both found by tester Auke
# on a Pi 5. fa3ea43 (DRUP v2.5.4) = keep the systemd slice strict and reconcile
# the cpuset at runtime from start-renderer.sh, so DRUP's --cpu-* pinning (incl.
# CPU_OTHER=0 on a 4-core Pi) works without EINVAL and without permanently
# relaxing isolation; the conflicting ExecStartPost round-robin is dropped.
# Root cause + Pi 4 testing by hoorna/Alfred, x86+SMT testing by Dominique.
readonly _TUNER_COMMIT="fa3ea4329c8bb32f5ede0c47bb19f1467e433703"
readonly _TUNER_BASE_URL="https://raw.githubusercontent.com/cometdom/DirettaRendererUPnP/${_TUNER_COMMIT}"
readonly _TUNER_REGULAR="diretta-renderer-tuner.sh"
readonly _TUNER_NOSMT="diretta-renderer-tuner-nosmt.sh"
readonly _TUNER_CACHE_DIR="/var/cache/audiophile-setup"

log_step "Apply system-level tuning (DRUP tuner)"

_tuning_already_applied() {
    find /etc/systemd/system -maxdepth 1 -name 'cpu-performance-diretta*.service' -type f 2>/dev/null \
        | grep -q .
}

_tuning_check_internet() {
    if command -v curl >/dev/null 2>&1 \
        && curl -fsS -m 5 -o /dev/null https://raw.githubusercontent.com 2>/dev/null; then
        return 0
    fi
    log_error "Cannot reach raw.githubusercontent.com — the DRUP tuner script must be downloaded. Check your network and retry."
    exit 1
}

# Echoes the local path to the downloaded tuner on stdout. All log output is
# sent to stderr so it doesn't pollute the captured path.
_tuning_download() {
    local script_name="$1"
    local dest="${_TUNER_CACHE_DIR}/${script_name}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        echo "${dest}"
        return 0
    fi

    if ! mkdir -p "${_TUNER_CACHE_DIR}"; then
        log_error "Cannot create cache directory ${_TUNER_CACHE_DIR}" >&2
        exit 1
    fi
    if ! curl -fsSL -o "${dest}" "${_TUNER_BASE_URL}/${script_name}"; then
        log_error "Failed to download ${script_name} from ${_TUNER_BASE_URL}" >&2
        exit 1
    fi
    chmod +x "${dest}"
    echo "${dest}"
}

if _tuning_already_applied; then
    log_info "DRUP tuner already applied to this host (cpu-performance-diretta*.service present)."
    if ! ask_yes_no "Re-run the DRUP tuner anyway?" N; then
        return 0 2>/dev/null || exit 0
    fi
fi

_tuning_check_internet

if ask_yes_no "Use the -nosmt tuner variant (disables Hyper-Threading / SMT — recommended on Intel HT or AMD SMT CPUs for lowest jitter)?" N; then
    _tuner_script="${_TUNER_NOSMT}"
else
    _tuner_script="${_TUNER_REGULAR}"
fi

if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would download ${_TUNER_BASE_URL}/${_tuner_script} to ${_TUNER_CACHE_DIR}/"
else
    log_info "Downloading ${_tuner_script} from upstream DRUP"
fi

_tuner_path=$(_tuning_download "${_tuner_script}")

log_info "Running ${_tuner_script} apply"
# The tuner is NOT interactive — it takes a subcommand (apply / revert /
# status / detect). Pass 'apply' and use run_cmd so its output goes to the
# wizard log alongside everything else.
run_cmd "${_tuner_path}" apply

log_info "System tuning applied. The kernel cmdline change takes effect on next reboot."
