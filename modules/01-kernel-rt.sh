#!/bin/bash
#
# 01-kernel-rt — install the PREEMPT_RT kernel (@kernel-vanilla/stable) and
# set it as the default GRUB boot entry.
#
# Reference: https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories
#
# A CachyOS-RT option was prototyped but dropped: kernel-cachyos-rt failed
# to boot on the maintainer's hardware — unacceptable for an option aimed at
# newbies. The robustness work from that prototype is kept here:
#   - vmlinuz located via RPM (not by file-name grepping)
#   - CONFIG_PREEMPT_RT verified by content before set-default
#
# Idempotent: if kernel-rt is installed and the default boot entry already
# points at its vmlinuz, the module does nothing.
#
# Pre-conditions enforced by 00-preflight: Fedora 43/44, x86_64, Secure Boot OFF.
#

set -euo pipefail

readonly _KR_COPR="@kernel-vanilla/stable"
readonly _KR_CORE_PKG="kernel-rt-core"      # owns the vmlinuz (drives detection)
readonly _KR_PKGS=(kernel-rt kernel-rt-core kernel-rt-modules)

log_step "Install PREEMPT_RT kernel (@kernel-vanilla/stable)"

_kernel_check_internet() {
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS -m 5 -o /dev/null https://fedoraproject.org 2>/dev/null; then
            return 0
        fi
    elif command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 3 fedoraproject.org >/dev/null 2>&1; then
            return 0
        fi
    fi
    log_error "Cannot reach the network — installing the kernel requires internet access (COPR). Check your connection and retry."
    exit 1
}

# Print the kernel-rt /boot vmlinuz (newest), or empty. We ask the RPM which
# file it actually installed (rpm -ql) instead of reconstructing the name from
# V-R-A: the vanilla RT kernel's vmlinuz carries a localversion suffix that the
# RPM N-V-R-A does NOT — e.g. RPM 7.0.12-301.vanilla.fc44.aarch64 but file
# /boot/vmlinuz-7.0.12-301.vanilla.fc44.aarch64+rt. The reconstructed path
# wouldn't exist, so the RT kernel was never set as default (seen on a Pi 5).
_kernel_find_vmlinuz() {
    local nvra v kver
    nvra=$(rpm -q "$_KR_CORE_PKG" 2>/dev/null | sort -V | tail -1 || true)
    [[ -n "$nvra" ]] || return 0
    # Prefer the /boot/vmlinuz the package owns.
    v=$(rpm -ql "$nvra" 2>/dev/null | grep -m1 '^/boot/vmlinuz-' || true)
    if [[ -n "$v" && -f "$v" ]]; then
        echo "$v"
        return 0
    fi
    # Fallback: derive the real kernel version (incl. the +rt localversion)
    # from the /lib/modules/<kver> directory the package owns, then the
    # conventional /boot path.
    kver=$(rpm -ql "$nvra" 2>/dev/null | sed -n 's#^/lib/modules/\([^/]*\)/.*#\1#p' | sort -u | tail -1)
    [[ -n "$kver" ]] || return 0
    v="/boot/vmlinuz-${kver}"
    [[ -f "$v" ]] && echo "$v"
}

_kernel_default_is_chosen() {
    local def want
    def=$(grubby --default-kernel 2>/dev/null || true)
    want=$(_kernel_find_vmlinuz)
    [[ -n "$want" && "$def" == "$want" ]]
}

_kernel_already_done() {
    local p
    for p in "${_KR_PKGS[@]}"; do
        has_package "$p" || return 1
    done
    _kernel_default_is_chosen
}

_kernel_enable_copr() {
    if ! has_package dnf-plugins-core; then
        log_info "Installing dnf-plugins-core (required for 'dnf copr')."
        run_cmd dnf -y install dnf-plugins-core
    fi
    log_info "Enabling COPR ${_KR_COPR}"
    run_cmd dnf -y copr enable "$_KR_COPR"
}

_kernel_install_packages() {
    log_info "Installing ${_KR_PKGS[*]}"
    run_cmd dnf -y install "${_KR_PKGS[@]}"
}

_kernel_set_default() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would locate the kernel-rt vmlinuz and set it as GRUB default via grubby."
        return 0
    fi
    local vmlinuz
    vmlinuz=$(_kernel_find_vmlinuz)
    if [[ -z "$vmlinuz" ]]; then
        log_error "kernel-rt is installed but no matching /boot/vmlinuz-* was found. Cannot set the default GRUB entry."
        exit 1
    fi

    # Safety net: the whole project depends on PREEMPT_RT. Verify by content
    # (a kernel's RT-ness is not reliably visible in its file name). If the
    # config isn't readable, warn but proceed (don't block on a corner case).
    local kver cfg
    kver="${vmlinuz##*/vmlinuz-}"
    cfg="/boot/config-${kver}"
    if [[ -r "$cfg" ]]; then
        if grep -q '^CONFIG_PREEMPT_RT=y' "$cfg"; then
            log_info "Verified PREEMPT_RT: ${cfg} has CONFIG_PREEMPT_RT=y"
        else
            log_error "Safety check failed: ${vmlinuz} is NOT a PREEMPT_RT kernel (no CONFIG_PREEMPT_RT=y in ${cfg}). Refusing to set it as default."
            exit 1
        fi
    else
        log_warn "Cannot verify PREEMPT_RT (${cfg} not readable) — proceeding; kernel-rt is expected to be RT."
    fi

    log_info "Setting default GRUB entry: ${vmlinuz}"
    run_cmd grubby --set-default="$vmlinuz"
}

# --- Dispatch -------------------------------------------------------------

if _kernel_already_done; then
    log_info "kernel-rt already installed and set as the default boot entry — skipping."
    return 0 2>/dev/null || exit 0
fi

_kernel_check_internet

if ! ask_yes_no "Install the PREEMPT_RT kernel from ${_KR_COPR} (recommended)?" Y KERNEL_RT; then
    log_warn "User declined the RT kernel. The audiophile setup will be incomplete; subsequent modules may misbehave."
    return 0 2>/dev/null || exit 0
fi

_kernel_enable_copr
_kernel_install_packages
_kernel_set_default

log_info "kernel-rt installed and set as default. It will boot at next reboot."
