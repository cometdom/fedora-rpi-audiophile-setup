#!/bin/bash
#
# 99-finalize — sanity-check the host state and offer a reboot.
#
# Runs last. Touches nothing: inspects the marks each module leaves behind
# and reports OK / skipped per module, then offers to reboot so kernel-rt
# and every boot-time piece (GRUB cmdline, tmpfs, NIC MTU, services) takes
# effect.
#
# All checks are non-fatal — a [--] line means the matching module was
# skipped or its target is optional, not that the wizard failed.
#

set -euo pipefail

log_step "Finalize — sanity check"

_fin_ok()   { log_info "  [OK] $*"; }
_fin_skip() { log_warn "  [--] $*"; }

# --- kernel-rt installed AND default GRUB entry ---
if has_package kernel-rt && has_package kernel-rt-core; then
    _fin_default_kernel=$(grubby --default-kernel 2>/dev/null || true)
    if [[ "$_fin_default_kernel" == *rt* ]]; then
        _fin_ok "kernel-rt installed; default boot entry: $(basename "$_fin_default_kernel")"
    else
        _fin_skip "kernel-rt installed but default boot entry is not -rt: $(basename "${_fin_default_kernel:-unknown}")"
    fi
else
    _fin_skip "kernel-rt not installed"
fi

# --- system tuning (DRUP tuner artefacts) ---
if find /etc/systemd/system -maxdepth 1 -name 'cpu-performance-diretta*.service' -type f 2>/dev/null | grep -q .; then
    _fin_ok "DRUP tuner artefacts present (cpu-performance-diretta*.service)"
else
    _fin_skip "DRUP tuner artefacts not detected (module 02 skipped?)"
fi

# --- network stack ---
_fin_nm_active=0; is_service_active NetworkManager   && _fin_nm_active=1
_fin_nd_active=0; is_service_active systemd-networkd && _fin_nd_active=1
if   [[ $_fin_nm_active -eq 1 && $_fin_nd_active -eq 0 ]]; then _fin_ok "Network stack: NetworkManager"
elif [[ $_fin_nm_active -eq 0 && $_fin_nd_active -eq 1 ]]; then _fin_ok "Network stack: systemd-networkd"
elif [[ $_fin_nm_active -eq 1 && $_fin_nd_active -eq 1 ]]; then _fin_skip "Both NM and networkd active — broken state"
else _fin_skip "Neither NetworkManager nor systemd-networkd active"
fi

# --- journald volatile ---
if [[ -f /etc/systemd/journald.conf.d/99-audiophile-volatile.conf ]] \
    && grep -q '^Storage=volatile' /etc/systemd/journald.conf.d/99-audiophile-volatile.conf; then
    _fin_ok "journald: Storage=volatile drop-in installed"
else
    _fin_skip "journald: volatile drop-in not installed (module 04 skipped?)"
fi

# --- tmpfs entries for /var/log and /var/tmp ---
if awk '$1=="tmpfs" && ($2=="/var/log" || $2=="/var/tmp"){f=1} END{exit !f}' /etc/fstab; then
    _fin_ok "tmpfs entries for /var/log and/or /var/tmp in /etc/fstab"
else
    _fin_skip "no tmpfs entries in fstab (optional — user declined or module 04 skipped)"
fi

# --- RAM mode (module 14) ---
_fin_ram_kargs=$(grubby --info DEFAULT 2>/dev/null \
    | grep '^args=' | head -1 \
    | sed 's/^args="//; s/"$//' || true)
_fin_ram_dracut_conf="/etc/dracut.conf.d/99-audiophile-ram-overlay.conf"

if [[ "$_fin_ram_kargs" == *"systemd.volatile=state"* ]]; then
    _fin_ok "RAM mode: volatile (/var in RAM via systemd.volatile=state)"
elif [[ "$_fin_ram_kargs" == *"audiophile.overlay=1"* ]]; then
    if [[ -f "$_fin_ram_dracut_conf" ]]; then
        _fin_ok "RAM mode: overlayfs enabled (dracut module present)"
    else
        _fin_skip "RAM mode: audiophile.overlay=1 in cmdline but dracut conf missing — re-run module 14"
    fi
else
    _fin_skip "RAM mode not enabled (module 14 skipped or disabled)"
fi

# --- cpu-states service ---
if systemctl is-enabled --quiet audiophile-cpu-states.service 2>/dev/null; then
    _fin_ok "audiophile-cpu-states.service enabled"
else
    _fin_skip "audiophile-cpu-states.service not enabled (module 06 skipped?)"
fi

# --- firewalld + SELinux (set by module 05) ---
if is_service_active firewalld 2>/dev/null; then
    _fin_skip "firewalld is active (kept by user choice)"
else
    _fin_ok "firewalld inactive"
fi
if command -v getenforce >/dev/null 2>&1; then
    _fin_se=$(getenforce 2>/dev/null || echo "?")
    case "$_fin_se" in
        Disabled)   _fin_ok "SELinux: Disabled (runtime + /etc/selinux/config)" ;;
        Permissive) _fin_ok "SELinux: Permissive (effective; reboot to apply persistent config)" ;;
        Enforcing)  _fin_skip "SELinux: Enforcing (kept by user choice)" ;;
        *)          _fin_skip "SELinux: state '${_fin_se}'" ;;
    esac
fi

# --- sysctl drop-ins ---
if [[ -f /etc/sysctl.d/99-audiophile-network.conf ]]; then
    _fin_ok "socket buffer sysctl drop-in installed"
else
    _fin_skip "socket buffer drop-in absent (module 07 skipped?)"
fi
if [[ -f /etc/sysctl.d/99-audiophile-swap.conf ]]; then
    _fin_ok "vm.swappiness sysctl drop-in installed"
else
    _fin_skip "vm.swappiness drop-in absent (module 09 skipped?)"
fi

# --- tuned profile ---
if command -v tuned-adm >/dev/null 2>&1; then
    _fin_tuned=$(tuned-adm active 2>/dev/null | sed -n 's/^Current active profile: //p')
    if [[ "$_fin_tuned" == "latency-performance" ]]; then
        _fin_ok "tuned profile: latency-performance"
    else
        _fin_skip "tuned profile is '${_fin_tuned:-<none>}' (expected latency-performance)"
    fi
else
    _fin_skip "tuned not installed (module 08 skipped?)"
fi

# --- swap status ---
if awk 'NR > 1 {f=1} END {exit !f}' /proc/swaps 2>/dev/null; then
    _fin_skip "swap is currently active — fstab changes apply on reboot"
else
    _fin_ok "no active swap"
fi

# --- Diretta NIC MTU (the live values, regardless of who set them) ---
# Show all physical ethernet NICs with their current MTU. A jumbo MTU
# (>1500) usually means DRUP or slim2Diretta install.sh tuned that NIC.
_fin_jumbo_found=0
for _fin_dev in /sys/class/net/*; do
    _fin_name=$(basename "$_fin_dev")
    [[ "$_fin_name" == "lo" ]] && continue
    [[ "$(readlink -f "$_fin_dev")" == *"/devices/virtual/"* ]] && continue
    [[ "$(cat "${_fin_dev}/type" 2>/dev/null)" == "1" ]] || continue
    _fin_mtu=$(cat "${_fin_dev}/mtu" 2>/dev/null || echo "?")
    if (( _fin_mtu > 1500 )); then
        _fin_ok "NIC ${_fin_name}: MTU ${_fin_mtu} (jumbo)"
        _fin_jumbo_found=1
    fi
done
if [[ $_fin_jumbo_found -eq 0 ]]; then
    _fin_skip "no NIC with jumbo MTU detected — Diretta link will use 1500 bytes"
fi

# --- Renderer services ---
if systemctl list-unit-files diretta-renderer.service 2>/dev/null | grep -q diretta-renderer; then
    if systemctl is-enabled --quiet diretta-renderer.service 2>/dev/null; then
        _fin_ok "diretta-renderer.service enabled (DRUP)"
    else
        _fin_skip "diretta-renderer.service installed but not enabled"
    fi
else
    _fin_skip "DirettaRendererUPnP not installed (module 10 skipped)"
fi
if systemctl list-unit-files slim2diretta.service 2>/dev/null | grep -q slim2diretta; then
    if systemctl is-enabled --quiet slim2diretta.service 2>/dev/null; then
        _fin_ok "slim2diretta.service enabled"
    else
        _fin_skip "slim2diretta.service installed but not enabled"
    fi
else
    _fin_skip "slim2Diretta not installed (module 11 skipped)"
fi

# --- Reboot prompt ---
echo
log_step "Reboot required"
log_info "Apply kernel-rt, the new GRUB cmdline, tmpfs mounts, and NIC MTU by rebooting."
log_info ""
log_info "After reboot, verify with:"
log_info "    uname -r                          # should contain 'rt'"
log_info "    cat /proc/cmdline                 # should contain isolcpus / nohz_full / rcu_nocbs"
log_info "    systemctl status diretta-renderer # if you installed DRUP"
log_info "    systemctl status slim2diretta     # if you installed slim2Diretta"
log_info ""

if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: not offering to reboot."
elif ask_yes_no "Reboot now?" N; then
    log_info "Rebooting…"
    run_cmd systemctl reboot
else
    log_info "Reboot skipped. Run 'sudo reboot' yourself when you're ready."
fi
