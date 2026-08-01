#!/bin/bash
#
# 05-services-cleanup — disable services an audiophile playback host never needs.
#
# Strategy:
#   - Fixed list of "always disable" units (bluetooth, cups, avahi, abrt*,
#     packagekit, udisks2, fwupd*, dnf-makecache.timer, *-updatedb.timer)
#     processed silently in batch.
#   - Two interactive prompts (default Y on a dedicated audio host on a
#     trusted LAN, consistent with the DRUP Fedora install guide):
#       - Disable firewalld (also avoids the install.sh firewall-prompt
#         abort the wizard now handles defensively)
#       - Disable SELinux (SELINUX=disabled, applied immediately as
#         permissive via setenforce + persisted in /etc/selinux/config)
#
# Each unit is probed for existence before action so the module is portable
# across Fedora minimal / Server / Workstation variants. State is inspected
# via 'systemctl is-enabled' so 'static' units (e.g. cups.service activated
# by cups.socket) are handled cleanly: stop if running, but don't try to
# 'disable' them (which would error).
#

set -euo pipefail

readonly _SVC_ALWAYS_DISABLE=(
    bluetooth.service
    cups.service
    cups.socket
    cups-browsed.service
    ModemManager.service
    packagekit.service
    packagekit-offline-update.service
    udisks2.service
    avahi-daemon.service
    avahi-daemon.socket
    abrtd.service
    abrt-journal-core.service
    abrt-oops.service
    abrt-xorg.service
    abrt-vmcore.service
    fwupd.service
    fwupd-refresh.service
    fwupd-refresh.timer
    dnf-makecache.timer
    mlocate-updatedb.timer
    plocate-updatedb.timer
)

log_step "Disable unneeded services"

_svc_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

_svc_handle() {
    local svc="$1"
    if ! _svc_exists "$svc"; then
        return 0
    fi
    local state
    state=$(systemctl is-enabled "$svc" 2>/dev/null || true)
    case "$state" in
        enabled|enabled-runtime)
            log_info "Disabling ${svc}"
            run_cmd systemctl disable --now "$svc"
            ;;
        static)
            # Can't disable a static unit, but if it's currently running
            # we want to stop it. Its activators (sockets, timers) are in
            # our list and will be disabled, so it won't come back.
            if is_service_active "$svc"; then
                log_info "${svc}: static — stopping the running instance."
                run_cmd systemctl stop "$svc"
            else
                log_info "${svc}: static, not running — nothing to do."
            fi
            ;;
        masked|disabled|alias|indirect|generated|transient)
            log_info "${svc}: already ${state} — skipping."
            ;;
        "")
            log_info "${svc}: state unknown (likely absent) — skipping."
            ;;
        *)
            log_info "${svc}: state '${state}' — skipping."
            ;;
    esac
}

# --- Batch disable --------------------------------------------------------

for _svc in "${_SVC_ALWAYS_DISABLE[@]}"; do
    _svc_handle "$_svc"
done

# --- Interactive: firewalld ----------------------------------------------

if _svc_exists firewalld.service && is_service_enabled firewalld.service; then
    if ask_yes_no "Disable firewalld? (Audiophile host on a trusted LAN doesn't need it; matches the DRUP Fedora guide.)" Y FIREWALLD_DISABLE; then
        log_info "Disabling firewalld.service"
        run_cmd systemctl disable --now firewalld.service
    else
        log_info "Keeping firewalld active."
    fi
fi

# --- Interactive: SELinux ------------------------------------------------

if [[ -f /etc/selinux/config ]] && command -v getenforce >/dev/null 2>&1; then
    _selinux_current=$(getenforce 2>/dev/null || echo "Disabled")
    if [[ "$_selinux_current" == "Disabled" ]]; then
        log_info "SELinux is already Disabled — nothing to do."
    elif ask_yes_no "Disable SELinux? (Zero overhead on a dedicated audio host; matches the DRUP Fedora guide.)" Y SELINUX_DISABLE; then
        log_info "Relaxing SELinux to permissive at runtime (setenforce 0)."
        run_cmd setenforce 0
        log_info "Setting SELINUX=disabled in /etc/selinux/config (effective after reboot)."
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            log_info "DRY-RUN: would sed /etc/selinux/config to SELINUX=disabled"
        else
            sed -i -E 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
        fi
    else
        log_info "Keeping SELinux ${_selinux_current}."
    fi
fi

log_info "Service cleanup complete."
