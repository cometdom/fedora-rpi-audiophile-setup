#!/bin/bash
#
# 00-preflight — verify hard pre-conditions and install the small set of CLI
# tools the wizard depends on at runtime.
#
# Order:
#   1. Distribution is Fedora 44            (blocking)
#   2. Architecture is aarch64              (blocking — Raspberry Pi 5 expected)
#   3. Install missing wizard prerequisites (curl, grubby, tar,
#      dnf-plugins-core) — safety net so the user can forget the documented
#      'dnf install' step and still get a clean run.
#   4. IPv6 is enabled                      (blocking)
#
# Differences from the x86_64 sibling repo (fedora-audiophile-setup):
#   - Architecture check accepts aarch64 instead of x86_64.
#   - Secure Boot check removed entirely. The Raspberry Pi firmware does not
#     expose a Secure Boot path that mokutil can query, and the vanilla
#     PREEMPT_RT kernel from the @kernel-vanilla/stable COPR boots fine on
#     a stock Pi 5 with no signature pre-condition. mokutil is therefore
#     dropped from the prerequisite install list too.
#   - Fedora 43 dropped from the supported list. Fedora 43 aarch64 was
#     functional but Pi 5 hardware support was less mature; the confirmed
#     working stack (Dave, 2026-06-05) is Fedora 44 only. This can be
#     relaxed later if/when an early tester validates 43 on Pi 5.
#   - Device-model log line: if /sys/firmware/devicetree/base/model is
#     readable, the detected model (e.g. "Raspberry Pi 5 Model B Rev 1.0")
#     is printed for support/debugging. Non-blocking — anything aarch64
#     proceeds, even a non-Pi board, on the understanding that the wizard
#     is tuned for the Pi 5 specifically and a different board may need
#     manual adjustments downstream.
#
# Checks 1-2 and 4 are blocking and not gated by DRY_RUN — a dry-run that
# skipped them would hide blockers the real run will hit anyway. The
# safety-net install at #3 goes through run_cmd, so DRY_RUN previews it
# without actually installing.
#

set -euo pipefail

log_step "Preflight checks"

_preflight_check_os() {
    if [[ ! -r /etc/os-release ]]; then
        log_error "Cannot read /etc/os-release — unsupported system."
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "fedora" ]]; then
        log_error "Unsupported distribution: ${ID:-unknown}. This wizard targets Fedora 44 (ARM64) only."
        exit 1
    fi
    case "${VERSION_ID:-}" in
        44) ;;
        *)
            log_error "Unsupported Fedora release: ${VERSION_ID:-unknown}. This wizard targets Fedora 44 (ARM64) only."
            exit 1
            ;;
    esac
    log_info "OS: Fedora ${VERSION_ID} (${VARIANT_ID:-unspecified variant})"
}

_preflight_check_arch() {
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "aarch64" ]]; then
        log_error "Unsupported architecture: ${arch}. This wizard targets aarch64 (Raspberry Pi 5) only. The x86_64 sibling is https://github.com/cometdom/fedora-audiophile-setup ."
        exit 1
    fi
    log_info "Architecture: ${arch}"

    # Device-tree model: informative log, not a gate. Strip the trailing
    # NUL that the kernel writes at the end of the model string.
    local model_path="/sys/firmware/devicetree/base/model"
    if [[ -r "$model_path" ]]; then
        local model
        model=$(tr -d '\0' < "$model_path" 2>/dev/null || true)
        if [[ -n "$model" ]]; then
            log_info "Board: ${model}"
            if [[ "$model" != *"Raspberry Pi 5"* ]]; then
                log_warn "This wizard is tuned for the Raspberry Pi 5 specifically. The board reports '${model}' — proceeding, but some module defaults (4-core isolation template, jumbo MTU choice, etc.) may need manual adjustment."
            fi
        fi
    fi
}

_preflight_install_tools() {
    local missing=()
    command -v curl   >/dev/null 2>&1 || missing+=(curl)
    command -v grubby >/dev/null 2>&1 || missing+=(grubby)
    command -v tar    >/dev/null 2>&1 || missing+=(tar)
    has_package dnf-plugins-core      || missing+=(dnf-plugins-core)

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "Required CLI tools already present (curl, grubby, tar, dnf-plugins-core)."
        return 0
    fi
    log_info "Installing missing wizard prerequisites: ${missing[*]}"
    run_cmd dnf -y install "${missing[@]}"
}

_preflight_check_ipv6() {
    if [[ ! -d /proc/sys/net/ipv6 ]]; then
        log_error "IPv6 is disabled at the kernel level (likely 'ipv6.disable=1' on the kernel cmdline). IPv6 is REQUIRED by the Diretta protocol."
        exit 1
    fi
    local disabled
    disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [[ "$disabled" != "0" ]]; then
        log_error "IPv6 is disabled (net.ipv6.conf.all.disable_ipv6=${disabled}). IPv6 is REQUIRED by the Diretta protocol — re-enable it before continuing."
        exit 1
    fi
    log_info "IPv6: enabled (OK)"
}

_preflight_check_os
_preflight_check_arch
_preflight_install_tools
_preflight_check_ipv6

log_info "Preflight: all checks passed."
