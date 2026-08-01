#!/bin/bash
#
# 11-install-slim2diretta — orchestrate the slim2Diretta install.
#
# Standalone (not coupled to 10-install-drup): a user may want only
# slim2Diretta.
#
# Flow:
#   1. Detect SUDO_USER (slim2Diretta install.sh refuses root)
#   2. Find Diretta SDK under /home/$SUDO_USER/DirettaHostSDK_*
#   3. Install ethtool (used by start-slim2diretta at runtime)
#   4. Interactive NIC selection (Diretta side). Needed to post-process
#      /etc/default/slim2diretta afterwards. We persist the Diretta MTU via
#      a universal systemd-udevd .link drop-in (ensure_diretta_mtu_link) —
#      works under NetworkManager AND systemd-networkd. slim2Diretta's
#      install.sh "5) Configure network" also prompts MTU via nmcli
#      (NM-only); harmless duplicate — the .link is what reliably applies.
#   5. Ask optional LMS server IP (empty → auto-discover via Slimproto)
#   6. git clone slim2Diretta into $HOME/slim2Diretta (as $SUDO_USER)
#   7. Run ./install.sh --full as $SUDO_USER in a real TTY. --full calls
#      run_full_installation directly (deps, optional codecs, Diretta SDK
#      check, CMake build, network + firewall config, systemd service) and
#      deploys /usr/local/bin/slim2diretta + service + conf itself. Going
#      through --full bypasses install.sh's interactive menu, so its
#      destructive "Aggressive Fedora optimization" entry (same footgun as
#      DRUP — strips security services, swaps sshd→dropbear, reboots) is
#      unreachable. The codec-selection prompt still appears; the network
#      step is redundant with our .link MTU drop-in (harmless).
#
#   Build target needs no help: slim2Diretta's CMakeLists.txt auto-detects
#   the SDK variant from `uname -m` + `getconf PAGESIZE` (+ a devicetree
#   model fallback), picking aarch64-linux-15k16 on the Pi 5 automatically.
#   8. Post-process /etc/default/slim2diretta: set TARGET, TARGET_INTERFACE,
#      optionally SLIM2DIRETTA_OPTS with the LMS IP.
#   9. systemctl enable (no start — service waits for next reboot).
#

set -euo pipefail

readonly _S2D_REPO_URL="https://github.com/cometdom/slim2Diretta.git"
readonly _S2D_CONF_FILE="/etc/default/slim2diretta"
readonly _S2D_SERVICE="slim2diretta.service"

log_step "Install slim2Diretta"

if ! ask_yes_no "Install slim2Diretta?" Y S2D_INSTALL; then
    log_info "Skipping slim2Diretta install."
    return 0 2>/dev/null || exit 0
fi

# --- 1. Detect unprivileged user -----------------------------------------

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
    log_error "slim2Diretta's install.sh refuses to run as root."
    log_error "Please launch this wizard via 'sudo' from a regular user account."
    exit 1
fi
_s2d_user="$SUDO_USER"
_s2d_home=$(getent passwd "$_s2d_user" | cut -d: -f6)
if [[ -z "$_s2d_home" || ! -d "$_s2d_home" ]]; then
    log_error "Cannot resolve home directory of user '${_s2d_user}'."
    exit 1
fi
log_info "slim2Diretta will be built as user '${_s2d_user}' (home: ${_s2d_home})."

# --- 2. Find the Diretta SDK ---------------------------------------------

_s2d_sdk=$(find "$_s2d_home" -maxdepth 1 -type d -name 'DirettaHostSDK_*' 2>/dev/null \
    | sort -V | tail -1)
if [[ -z "$_s2d_sdk" ]]; then
    log_error "Diretta SDK not found under ${_s2d_home}/DirettaHostSDK_*"
    log_error "Download manually from https://www.diretta.link/hostsdk.html (licence: personal use only),"
    log_error "extract it to ${_s2d_home}/, then re-run: sudo ./setup.sh --only install-slim2diretta"
    exit 1
fi
log_info "Found Diretta SDK: ${_s2d_sdk}"

# --- 3. Pre-install build prerequisites ---------------------------------
#
# Defensive: slim2Diretta install.sh installs the same list under its
# "Full installation" path, but on a clean Fedora minimal that path can
# trip on a pre-check (e.g. cmake invoked before its own dnf install).
# Installing ahead of time makes install.sh's step a no-op.

log_info "Installing slim2Diretta build prerequisites"
run_cmd dnf -y install \
    gcc-c++ make cmake pkg-config \
    flac-devel ethtool python3

# --- 4. NIC selection ----------------------------------------------------
#
# Note: MTU prompt + persistence intentionally skipped here. slim2Diretta's
# own install.sh menu includes "5) Configure network" which prompts for the
# Diretta NIC + MTU and persists via nmcli. We let it own that interaction
# so the user answers MTU only once.

# List physical ethernet interfaces — any link state. Diretta target NIC
# often has carrier=down at install time (target not yet powered or cabled).
_s2d_eth_ifaces() {
    local sys iface typ
    for sys in /sys/class/net/*; do
        iface=$(basename "$sys")
        [[ "$iface" == "lo" ]] && continue
        [[ "$(readlink -f "$sys")" == *"/devices/virtual/"* ]] && continue
        # Skip wireless (wlan0 is type 1 like ethernet); Diretta/LAN are wired.
        [[ -e "${sys}/phy80211" || -d "${sys}/wireless" ]] && continue
        typ=$(cat "${sys}/type" 2>/dev/null || echo "")
        [[ "$typ" == "1" ]] || continue
        echo "$iface"
    done
}
_s2d_describe_iface() {
    local iface="$1" state addr
    state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "?")
    addr=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')
    if [[ -n "$addr" ]]; then
        printf '%s  (link %s, %s)' "$iface" "$state" "$addr"
    else
        printf '%s  (link %s, no IPv4)' "$iface" "$state"
    fi
}

mapfile -t _s2d_ifaces < <(_s2d_eth_ifaces)
if [[ ${#_s2d_ifaces[@]} -eq 0 ]]; then
    log_error "No physical ethernet interface found — cannot configure slim2Diretta."
    exit 1
elif [[ ${#_s2d_ifaces[@]} -eq 1 ]]; then
    _s2d_diretta_iface="${_s2d_ifaces[0]}"
    log_info "Single NIC '${_s2d_diretta_iface}' will be used as the Diretta NIC."
else
    echo
    echo "Which NIC is connected to the Diretta target (audio side)?"
    for i in "${!_s2d_ifaces[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "$(_s2d_describe_iface "${_s2d_ifaces[i]}")"
    done
    while true; do
        _s2d_pick="$(resolve_input S2D_DEVICE_PICK "Number [1]:")"
        _s2d_pick="${_s2d_pick:-1}"
        if [[ "$_s2d_pick" =~ ^[1-9][0-9]*$ ]] && (( _s2d_pick >= 1 && _s2d_pick <= ${#_s2d_ifaces[@]} )); then
            _s2d_diretta_iface="${_s2d_ifaces[$((_s2d_pick-1))]}"
            break
        fi
        echo "Invalid choice."
    done
fi

# Ensure NetworkManager has a profile for the Diretta NIC (otherwise
# slim2Diretta install.sh's "Configure network" step can't persist MTU
# via nmcli — same root cause as DRUP install.sh).
# Persist the Diretta NIC MTU via a universal systemd-udevd .link drop-in
# (works under NetworkManager AND systemd-networkd).
ensure_diretta_mtu_link "$_s2d_diretta_iface"

ensure_diretta_nm_connection "$_s2d_diretta_iface"

# --- 5. Optional LMS server IP -------------------------------------------

echo
_s2d_lms_ip="$(resolve_input S2D_LMS_IP "LMS server IP (leave empty for Slimproto auto-discovery):")"
if [[ -n "${_s2d_lms_ip}" ]]; then
    _s2d_opts="-s ${_s2d_lms_ip}"
    log_info "slim2Diretta will connect to LMS at ${_s2d_lms_ip}."
else
    _s2d_opts=""
    log_info "slim2Diretta will auto-discover the LMS server."
fi

# --- 6. Clone slim2Diretta as the user -----------------------------------

_s2d_dir="${_s2d_home}/slim2Diretta"
if [[ -d "${_s2d_dir}/.git" ]]; then
    log_info "slim2Diretta repo already cloned at ${_s2d_dir}"
else
    log_info "Cloning slim2Diretta repo to ${_s2d_dir} (as ${_s2d_user})"
    run_cmd sudo -u "$_s2d_user" git clone "$_S2D_REPO_URL" "$_s2d_dir"
fi

# --- 6b. Stop a running player before (re)installing ---------------------
#
# On a re-install, the old /usr/local/bin/slim2diretta is still executing, so
# overwriting it fails with "Text file busy". Stop the service first (it's
# enabled, not started, at the end of this module — it returns on the next
# reboot). No-op on a first install. (Same fix as module 10, reported by Auke.)
if is_service_active "$_S2D_SERVICE"; then
    log_info "Stopping the running ${_S2D_SERVICE} before (re)installing."
    run_cmd systemctl stop "$_S2D_SERVICE" || true
fi

# --- 7. Run install.sh as the user (TTY-direct) --------------------------

_s2d_binary="/usr/local/bin/slim2diretta"
_s2d_run_install=1
if [[ -x "$_s2d_binary" ]]; then
    log_info "slim2Diretta binary already installed at ${_s2d_binary}."
    if ! ask_yes_no "Re-run ./install.sh (e.g. to rebuild with Clang+LTO or a different option)?" N S2D_RERUN; then
        log_info "Keeping the existing binary — skipping ./install.sh."
        _s2d_run_install=0
    fi
fi

if [[ "$_s2d_run_install" -eq 1 ]]; then
    # Clang + LTO build. install.sh auto-installs clang and lld when LLVM=1
    # is set, BUT we pre-install them ourselves — same defensive reasoning
    # as for cmake (an install.sh pre-check that invokes clang before its
    # own dnf install would otherwise fail).
    _s2d_llvm_prefix=""
    if ask_yes_no "Build slim2Diretta with Clang + LTO (recommended for sound quality)?" Y S2D_CLANG_LTO; then
        _s2d_llvm_prefix="LLVM=1 "
        if ! has_package clang || ! has_package lld; then
            log_info "Pre-installing clang and lld for the LLVM build."
            run_cmd dnf -y install clang lld
        fi
        log_info "Will pass LLVM=1 to ./install.sh."
    fi

    log_warn "About to run slim2Diretta ./install.sh --full as user '${_s2d_user}'."
    log_warn "Answer its interactive prompts (codec selection menu, etc.)."
    # Same upstream firewall caveat as DRUP — if firewalld is off, the
    # install.sh network-config step aborts on a Y to the firewall prompt.
    if ! is_service_active firewalld; then
        log_warn "firewalld is NOT running. When install.sh asks"
        log_warn "  'Configure firewall ...?', answer N."
        log_warn "Answering Y aborts install.sh (upstream bug)."
    fi
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would execute as ${_s2d_user}: cd ${_s2d_dir} && ${_s2d_llvm_prefix}./install.sh --full"
    else
        # Direct exec; capture rc so an install.sh hiccup doesn't kill us.
        # --full runs run_full_installation directly (no menu → the aggressive-
        # optimization entry is unreachable). Success = the binary at
        # /usr/local/bin/slim2diretta exists.
        set +e
        sudo -u "$_s2d_user" -i bash -c "cd '${_s2d_dir}' && ${_s2d_llvm_prefix}./install.sh --full"
        _s2d_rc=$?
        set -e
        if [[ ! -x "$_s2d_binary" ]]; then
            log_error "slim2Diretta install.sh exited (rc=${_s2d_rc}) and ${_s2d_binary} was not produced."
            log_error "If it aborted on a firewall prompt with firewalld off, answer N and re-run:"
            log_error "  sudo ./setup.sh --only install-slim2diretta"
            exit 1
        fi
        if [[ $_s2d_rc -ne 0 ]]; then
            log_warn "slim2Diretta install.sh exited with rc=${_s2d_rc} but the binary is present — continuing."
        fi
    fi
fi

# --- 8. Post-process /etc/default/slim2diretta ---------------------------

_s2d_set_conf_var() {
    local var="$1" val="$2"
    if [[ ! -f "$_S2D_CONF_FILE" ]]; then
        return 0
    fi
    if grep -qE "^${var}=" "$_S2D_CONF_FILE"; then
        sed -i -E "s|^${var}=.*$|${var}=\"${val}\"|" "$_S2D_CONF_FILE"
    else
        echo "${var}=\"${val}\"" >> "$_S2D_CONF_FILE"
    fi
}

# Translate the user-picked Diretta iface to its stable rename target
# (eth-diretta) when /etc/systemd/network/10-diretta.link exists. stable_name_for
# returns the iface unchanged when no .link matches, so this is a no-op for
# hosts where stable naming wasn't set up.
_s2d_diretta_iface_conf=$(stable_name_for "$_s2d_diretta_iface")
if [[ "$_s2d_diretta_iface_conf" != "$_s2d_diretta_iface" ]]; then
    log_info "Mapping Diretta NIC ${_s2d_diretta_iface} → ${_s2d_diretta_iface_conf} (stable name, applied at next boot)."
fi

log_info "Setting TARGET / TARGET_INTERFACE${_s2d_opts:+ / SLIM2DIRETTA_OPTS} in ${_S2D_CONF_FILE}"
if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would set TARGET=1, TARGET_INTERFACE=${_s2d_diretta_iface_conf}${_s2d_opts:+, SLIM2DIRETTA_OPTS=${_s2d_opts}}"
else
    _s2d_set_conf_var TARGET 1
    _s2d_set_conf_var TARGET_INTERFACE "$_s2d_diretta_iface_conf"
    if [[ -n "$_s2d_opts" ]]; then
        _s2d_set_conf_var SLIM2DIRETTA_OPTS "$_s2d_opts"
    fi
fi

# --- 9. Web config UI (browser, port 8081) — optional --------------------
#
# install.sh --full does NOT install the web UI; ./install.sh --webui copies
# webui/ and runs a small Python server as slim2diretta-webui.service on :8081.
# slim2Diretta's --webui asks its own Y/N, so we don't add a second prompt
# here — we just make sure python3 is present (done above) and run it.
if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would run (as ${_s2d_user}): cd ${_s2d_dir} && ./install.sh --webui"
else
    log_info "Web UI: running ./install.sh --webui (it will ask whether to install the port-8081 UI)."
    # Same TTY-direct, non-fatal pattern as the main install.sh run.
    set +e
    sudo -u "$_s2d_user" -i bash -c "cd '${_s2d_dir}' && ./install.sh --webui"
    _s2d_webui_rc=$?
    set -e
    if [[ $_s2d_webui_rc -ne 0 ]]; then
        log_warn "Web UI step exited (rc=${_s2d_webui_rc}). The player itself is unaffected."
        log_warn "  Re-run later with: cd ${_s2d_dir} && ./install.sh --webui"
    fi
fi

# --- 10. Enable service (don't start — wait for reboot) ------------------

run_cmd systemctl enable "$_S2D_SERVICE"

log_info "slim2Diretta installed. The service is enabled and will start at next reboot."
log_info "Review ${_S2D_CONF_FILE} before reboot to tune player name, codec options, CPU affinity, etc."
