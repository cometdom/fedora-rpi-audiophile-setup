#!/bin/bash
#
# 12-install-slim2upnp — orchestrate the slim2UPnP install.
#
# slim2UPnP is a Slimproto→UPnP bridge by the same author as DRUP/slim2Diretta:
# it appears as a player in LMS (Lyrion Music Server) and streams to a UPnP
# renderer such as DirettaRendererUPnP. Some listeners prefer the
# LMS → slim2UPnP → DRUP → Diretta chain to slim2Diretta.
#
# Unlike DRUP/slim2Diretta it needs NO Diretta SDK and NO Diretta NIC — it
# talks to the UPnP renderer over the LAN. Its install.sh (run as root)
# auto-downloads a precompiled static binary from GitHub Releases for this arch
# (or builds from source with --build / LLVM=1 for Clang+LTO), installs
# slim2upnp.service and a web UI on :8082, but does NOT enable/start the
# service — we enable it here. Renderer + LMS settings are configured
# afterwards in that web UI.
#
# Standalone — useful once a UPnP renderer (DRUP or other) is on the network.
#

set -euo pipefail

readonly _S2U_REPO_URL="https://github.com/cometdom/slim2UPnP.git"
readonly _S2U_SERVICE="slim2upnp.service"
readonly _S2U_BINARY="/usr/local/bin/slim2upnp"

log_step "Install slim2UPnP (Slimproto → UPnP bridge)"

if ! ask_yes_no "Install slim2UPnP (an LMS player that streams to a UPnP renderer like DRUP)?" N; then
    log_info "Skipping slim2UPnP install."
    return 0 2>/dev/null || exit 0
fi

# --- Unprivileged user (for the clone location) -------------------------

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
    log_error "Please launch this wizard via 'sudo' from a regular user account (not a direct root login)."
    exit 1
fi
_s2u_user="$SUDO_USER"
_s2u_home=$(getent passwd "$_s2u_user" | cut -d: -f6)
if [[ -z "$_s2u_home" || ! -d "$_s2u_home" ]]; then
    log_error "Cannot resolve home directory of user '${_s2u_user}'."
    exit 1
fi

# --- Clone the repo as the user -----------------------------------------

_s2u_dir="${_s2u_home}/slim2UPnP"
if [[ -d "${_s2u_dir}/.git" ]]; then
    log_info "slim2UPnP repo already cloned at ${_s2u_dir}"
else
    log_info "Cloning slim2UPnP to ${_s2u_dir} (as ${_s2u_user})"
    run_cmd sudo -u "$_s2u_user" git clone "$_S2U_REPO_URL" "$_s2u_dir"
fi

# --- Stop a running instance before (re)installing ----------------------
# (overwriting /usr/local/bin/slim2upnp while it runs fails, "Text file busy")
if is_service_active "$_S2U_SERVICE"; then
    log_info "Stopping the running ${_S2U_SERVICE} before (re)installing."
    run_cmd systemctl stop "$_S2U_SERVICE" || true
fi

# --- Build choice: prebuilt static binary (default) or Clang+LTO source --

_s2u_llvm_env=""
_s2u_install_arg=""
if ask_yes_no "Build slim2UPnP from source with Clang + LTO? (default: download a prebuilt static binary — faster)" N; then
    _s2u_install_arg="--build"
    # Passed via `env` below. A "LLVM=1" coming from a variable expansion is
    # NOT recognised as a shell assignment (assignment recognition happens
    # before expansion), so `${prefix}./install.sh` would try to *run* "LLVM=1".
    _s2u_llvm_env="LLVM=1"
    log_info "Installing build prerequisites (gcc-c++, cmake, libupnp-devel, clang)."
    run_cmd dnf -y install gcc-c++ cmake libupnp-devel clang
fi

# --- Run install.sh as root (download/build + service + web UI) ----------
# install.sh refuses to run as non-root (it installs to /usr/local/bin and
# manages the service), so — unlike DRUP/slim2Diretta — we run it as root.

_s2u_run_install=1
if [[ -x "$_S2U_BINARY" ]]; then
    log_info "slim2UPnP binary already installed at ${_S2U_BINARY}."
    if ! ask_yes_no "Re-run ./install.sh (e.g. to update or switch to a source build)?" N; then
        _s2u_run_install=0
    fi
fi

if [[ "$_s2u_run_install" -eq 1 ]]; then
    log_warn "Running slim2UPnP ./install.sh ${_s2u_install_arg} (downloads the binary / builds, then installs the service + web UI)."
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would run: cd ${_s2u_dir} && env ${_s2u_llvm_env} ./install.sh ${_s2u_install_arg}"
    else
        # Capture rc so an install.sh hiccup doesn't abort the wizard; success
        # is judged by the binary existing.
        set +e
        ( cd "$_s2u_dir" && env ${_s2u_llvm_env} ./install.sh ${_s2u_install_arg} )
        _s2u_rc=$?
        set -e
        if [[ ! -x "$_S2U_BINARY" ]]; then
            log_error "slim2UPnP install.sh exited (rc=${_s2u_rc}) and ${_S2U_BINARY} was not produced."
            log_error "If it reported no published release for this arch, re-run this module and answer Y to the source build."
            exit 1
        fi
        if [[ $_s2u_rc -ne 0 ]]; then
            log_warn "install.sh exited with rc=${_s2u_rc} but the binary is present — continuing."
        fi
    fi
fi

# --- Enable the service (don't start — wait for reboot) -----------------

run_cmd systemctl enable "$_S2U_SERVICE"

log_info "slim2UPnP installed and enabled — it starts at next reboot."
log_info "After reboot, set the UPnP renderer and LMS server in the web UI: http://<this-host>:8082"
log_info "Then pick 'slim2UPnP' as the player in LMS and press play."
