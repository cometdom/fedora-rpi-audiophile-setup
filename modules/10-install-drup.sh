#!/bin/bash
#
# 10-install-drup — orchestrate the DirettaRendererUPnP install.
#
# Flow (asks Y/N upfront — module is optional):
#   1. Detect SUDO_USER (DRUP install.sh refuses root)
#   2. Detect Diretta SDK under /home/$SUDO_USER/DirettaHostSDK_*
#      (SDK download is manual — licence "personal use only" — diretta.link)
#   3. Install ethtool (used by start-renderer at runtime)
#   4. Interactive NIC selection (Diretta side + control-point side). We
#      need to know these to post-process /etc/default/diretta-renderer
#      afterwards. We also persist the Diretta MTU via a universal
#      systemd-udevd .link drop-in (ensure_diretta_mtu_link) — this works
#      under BOTH NetworkManager and systemd-networkd. DRUP's install.sh
#      additionally prompts for MTU and writes it via nmcli (NM-only); that
#      duplicate prompt is harmless — the .link is what reliably applies.
#   5. git clone DRUP into $HOME/DirettaRendererUPnP (as $SUDO_USER)
#   6. Run ./install.sh --full as $SUDO_USER in a real TTY (~30 min for the
#      FFmpeg build); skipped if the binary already exists. --full calls
#      run_full_installation directly, bypassing DRUP's interactive menu so
#      its destructive "Aggressive Fedora optimization" entry (menu option 7
#      — removes firewalld/SELinux/polkit/journald, swaps sshd→dropbear,
#      reboots, and has wiped a tester's RT kernel) is unreachable. The
#      FFmpeg-version sub-prompt still appears; on Pi we steer the user
#      to option 2 (7.1.1 minimal) — safest choice for low-RAM boards.
#   7. Run systemd/install-systemd.sh as root (copies binary, conf, service)
#   8. Post-process /etc/default/diretta-renderer: set INTERFACE,
#      TARGET_INTERFACE, TARGET
#   9. systemctl enable (don't start — service waits for next reboot)
#

set -euo pipefail

readonly _DRUP_REPO_URL="https://github.com/cometdom/DirettaRendererUPnP.git"
readonly _DRUP_CONF_FILE="/etc/default/diretta-renderer"
readonly _DRUP_SERVICE="diretta-renderer.service"

log_step "Install DirettaRendererUPnP"

if ! ask_yes_no "Install DirettaRendererUPnP?" Y; then
    log_info "Skipping DRUP install."
    return 0 2>/dev/null || exit 0
fi

# --- 1. Detect the unprivileged user that ran sudo ----------------------

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
    log_error "DRUP's install.sh refuses to run as root."
    log_error "Please launch this wizard via 'sudo' from a regular user account (not a direct root login)."
    exit 1
fi
_drup_user="$SUDO_USER"
_drup_home=$(getent passwd "$_drup_user" | cut -d: -f6)
if [[ -z "$_drup_home" || ! -d "$_drup_home" ]]; then
    log_error "Cannot resolve home directory of user '${_drup_user}'."
    exit 1
fi
log_info "DRUP will be built as user '${_drup_user}' (home: ${_drup_home})."

# --- 2. Find the manually-downloaded Diretta SDK ------------------------

_drup_sdk=$(find "$_drup_home" -maxdepth 1 -type d -name 'DirettaHostSDK_*' 2>/dev/null \
    | sort -V | tail -1)
if [[ -z "$_drup_sdk" ]]; then
    log_error "Diretta SDK not found under ${_drup_home}/DirettaHostSDK_*"
    log_error ""
    log_error "The SDK is licensed 'for personal use only' and must be downloaded manually:"
    log_error "  1. Visit https://www.diretta.link/hostsdk.html"
    log_error "  2. Download the latest DirettaHostSDK_*.tar.zst"
    log_error "  3. Copy it to ${_drup_home}/ on this host"
    log_error "  4. Extract:  tar --zstd -xf DirettaHostSDK_*.tar.zst"
    log_error "  5. Re-run:   sudo ./setup.sh --only install-drup"
    exit 1
fi
log_info "Found Diretta SDK: ${_drup_sdk}"

# --- 3. Pre-install build prerequisites ---------------------------------
#
# Defensive: DRUP install.sh runs its own 'install_base_dependencies' step
# but some pre-flight checks (e.g. invoking a tool before the dnf install
# block) can fail when the tool is missing. Installing the same list ahead
# of time makes install.sh's step a no-op and avoids that class of fail.
# ethtool stays in the list because start-renderer uses it at runtime.

log_info "Installing DRUP build prerequisites"
run_cmd dnf -y install \
    git gcc-c++ make pkg-config wget nasm yasm \
    libupnp-devel ethtool python3

# --- 4. NIC selection ----------------------------------------------------

# Physical ethernet interfaces — any link state. A Diretta target NIC
# typically has carrier=down at install time (target not yet powered or
# cabled), so filtering on operstate=up would hide it.
_drup_eth_ifaces() {
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

# Annotate an interface with its link state and IPv4 (if any) for the menu.
_drup_describe_iface() {
    local iface="$1" state addr
    state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "?")
    addr=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')
    if [[ -n "$addr" ]]; then
        printf '%s  (link %s, %s)' "$iface" "$state" "$addr"
    else
        printf '%s  (link %s, no IPv4)' "$iface" "$state"
    fi
}

# IMPORTANT: the menu must print to stderr — the caller captures stdout via
# $(_drup_pick_iface ...) to get the chosen iface, so anything written to
# stdout BEFORE the final echo would be silently swallowed (user would see
# only "Number [1]:" without the menu above it).
_drup_pick_iface() {
    local prompt="$1"; shift
    local choices=("$@")
    {
        echo
        echo "${prompt}"
        local i
        for i in "${!choices[@]}"; do
            printf "  %d) %s\n" "$((i+1))" "$(_drup_describe_iface "${choices[i]}")"
        done
    } >&2
    while true; do
        read -r -p "Number [1]: " _pick
        _pick="${_pick:-1}"
        if [[ "$_pick" =~ ^[1-9][0-9]*$ ]] && (( _pick >= 1 && _pick <= ${#choices[@]} )); then
            echo "${choices[$((_pick-1))]}"
            return 0
        fi
        echo "Invalid choice." >&2
    done
}

mapfile -t _drup_ifaces < <(_drup_eth_ifaces)
if [[ ${#_drup_ifaces[@]} -eq 0 ]]; then
    log_error "No physical ethernet interface found — cannot configure DRUP."
    exit 1
elif [[ ${#_drup_ifaces[@]} -eq 1 ]]; then
    _drup_diretta_iface="${_drup_ifaces[0]}"
    _drup_control_iface="${_drup_ifaces[0]}"
    log_info "Single NIC '${_drup_diretta_iface}' will serve both UPnP (control points) and Diretta target."
else
    _drup_diretta_iface=$(_drup_pick_iface "Which NIC is connected to the Diretta target (audio side)?" "${_drup_ifaces[@]}")
    if [[ ${#_drup_ifaces[@]} -eq 2 ]]; then
        for _iface in "${_drup_ifaces[@]}"; do
            [[ "$_iface" != "$_drup_diretta_iface" ]] && _drup_control_iface="$_iface"
        done
    else
        # 3+ NICs: ask explicitly
        _drup_remaining=()
        for _iface in "${_drup_ifaces[@]}"; do
            [[ "$_iface" != "$_drup_diretta_iface" ]] && _drup_remaining+=("$_iface")
        done
        _drup_control_iface=$(_drup_pick_iface "Which NIC is the control-point side (UPnP: Audirvana/Roon)?" "${_drup_remaining[@]}")
    fi
    log_info "Diretta NIC:       ${_drup_diretta_iface}"
    log_info "Control-point NIC: ${_drup_control_iface}"
fi

# Persist the Diretta NIC MTU via a universal systemd-udevd .link drop-in
# (works under NetworkManager AND systemd-networkd — unlike the nmcli path
# in DRUP install.sh, which is a no-op under networkd).
ensure_diretta_mtu_link "$_drup_diretta_iface"

# Ensure NetworkManager has a connection profile for the Diretta NIC. If it
# doesn't, DRUP install.sh later fails to persist the MTU ("Could not find
# NetworkManager connection for <iface>") because the NIC is unmanaged. The
# NIC is typically link-down at this stage (Diretta target not powered yet),
# so NM never auto-created a profile. Create a minimal one: link-local on
# both IPv4 and IPv6 (Diretta speaks L2/raw sockets — no IP needed on the
# Diretta link), autoconnect on so it survives reboots.
ensure_diretta_nm_connection "$_drup_diretta_iface"

# --- 5. git clone DRUP as the unprivileged user --------------------------
#
# Note: MTU prompt + persistence intentionally skipped here. DRUP's own
# install.sh has a "=== Network Configuration ===" section that asks the
# Diretta NIC, jumbo Y/N, and MTU (9014 / 16128) and writes the value via
# nmcli. We let it own that interaction so the user answers only once.

_drup_dir="${_drup_home}/DirettaRendererUPnP"
if [[ -d "${_drup_dir}/.git" ]]; then
    log_info "DRUP repo already cloned at ${_drup_dir}"
else
    log_info "Cloning DRUP repo to ${_drup_dir} (as ${_drup_user})"
    run_cmd sudo -u "$_drup_user" git clone "$_DRUP_REPO_URL" "$_drup_dir"
fi

# --- 5b. Stop a running renderer before (re)installing -------------------
#
# On a re-install, the old binary at /opt/diretta-renderer-upnp is still
# executing, so copying a freshly built one over it fails with "Text file
# busy". Stop the service first (it's enabled, not started, at the end of this
# module — it comes back on the next reboot). No-op on a first install.
# Reported by tester Auke.
if is_service_active "$_DRUP_SERVICE"; then
    log_info "Stopping the running ${_DRUP_SERVICE} before (re)installing."
    run_cmd systemctl stop "$_DRUP_SERVICE" || true
fi

# --- 6. Run DRUP install.sh as the user (TTY-direct, ~30 min) ------------

_drup_binary="${_drup_dir}/bin/DirettaRendererUPnP"
_drup_run_install=1
if [[ -f "$_drup_binary" ]]; then
    log_info "DRUP binary already exists at ${_drup_binary}."
    if ! ask_yes_no "Re-run ./install.sh (e.g. to rebuild with Clang+LTO or a different option)?" N; then
        log_info "Keeping the existing binary — skipping ./install.sh."
        _drup_run_install=0
    fi
fi

if [[ "$_drup_run_install" -eq 1 ]]; then
    # Clang + LTO build is reported to improve audio quality on both DRUP
    # and slim2Diretta. install.sh auto-installs clang and lld when LLVM=1
    # is set, BUT we pre-install them ourselves anyway — same defensive
    # reasoning as for cmake on module 11: an install.sh pre-check that
    # invokes clang before its own dnf install would otherwise fail.
    _drup_llvm_prefix=""
    if ask_yes_no "Build DRUP with Clang + LTO (recommended for sound quality)?" Y; then
        _drup_llvm_prefix="LLVM=1 "
        if ! has_package clang || ! has_package lld; then
            log_info "Pre-installing clang and lld for the LLVM build."
            run_cmd dnf -y install clang lld
        fi
        log_info "Will pass LLVM=1 to ./install.sh."
    fi

    log_warn "About to run DRUP ./install.sh --full as user '${_drup_user}'."
    log_warn "It compiles FFmpeg from source — expect ~30 minutes."
    # FFmpeg menu (as of DRUP v2.5.7):
    # (Fedora 44 ARM64, confirmed by Auke 2026-06-27). Pick either:
    #   option 1 — FFmpeg 7.1.1 full build (/usr/local)
    #   option 2 — FFmpeg 7.1.1 minimal audio (/usr)  ← recommended for Pi
    #   option 3 — FFmpeg 8.1.2 minimal audio (/usr)  ← default
    log_info "When it asks which FFmpeg to build, choose option 2 (7.1.1 minimal) on the Pi."
    log_info "  Smallest footprint, safest on low-RAM boards. Option 3 (8.1.2 minimal) may also work."
    # Known upstream bug: install.sh's "Configure firewall to allow UPnP
    # traffic?" step calls firewall-cmd unconditionally and aborts on rc!=0
    # when firewalld is inactive. Warn the user up front so they answer N.
    if ! is_service_active firewalld; then
        log_warn "firewalld is NOT running. When install.sh asks"
        log_warn "  'Configure firewall to allow UPnP traffic?', answer N."
        log_warn "Answering Y aborts install.sh (upstream bug)."
    fi
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would execute as ${_drup_user}: cd ${_drup_dir} && ${_drup_llvm_prefix}./install.sh --full"
    else
        # Direct exec (no run_cmd / tee pipe) so install.sh keeps its TTY.
        # -i = login shell so PATH/HOME are clean for the user. --full runs
        # run_full_installation directly (no menu → the aggressive-optimization
        # entry is unreachable). Temporarily disable set -e so an install.sh
        # hiccup at the firewall step (or similar) doesn't kill our wizard —
        # we judge success by whether the binary was produced.
        set +e
        sudo -u "$_drup_user" -i bash -c "cd '${_drup_dir}' && ${_drup_llvm_prefix}./install.sh --full"
        _drup_rc=$?
        set -e
        if [[ ! -f "$_drup_binary" ]]; then
            log_error "DRUP install.sh exited (rc=${_drup_rc}) and ${_drup_binary} was not produced."
            log_error "If it aborted on 'Configure firewall to allow UPnP traffic?' with firewalld off,"
            log_error "answer N to that prompt and re-run: sudo ./setup.sh --only install-drup"
            exit 1
        fi
        if [[ $_drup_rc -ne 0 ]]; then
            log_warn "DRUP install.sh exited with rc=${_drup_rc} but the binary is present — continuing."
        fi
    fi
fi

# --- 7. Install the systemd service via DRUP's own installer -------------

log_info "Running ${_drup_dir}/systemd/install-systemd.sh (root) to deploy /opt/diretta-renderer-upnp + service unit."
if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would execute: bash ${_drup_dir}/systemd/install-systemd.sh"
else
    bash "${_drup_dir}/systemd/install-systemd.sh"
fi

# --- 8. Post-process /etc/default/diretta-renderer -----------------------

# install-systemd.sh only copies the template when the conf doesn't exist;
# either way we (re)apply our three known variables idempotently.
_drup_set_conf_var() {
    local var="$1" val="$2"
    if [[ ! -f "$_DRUP_CONF_FILE" ]]; then
        return 0
    fi
    if grep -qE "^${var}=" "$_DRUP_CONF_FILE"; then
        sed -i -E "s|^${var}=.*$|${var}=\"${val}\"|" "$_DRUP_CONF_FILE"
    else
        echo "${var}=\"${val}\"" >> "$_DRUP_CONF_FILE"
    fi
}

# Translate the user-picked iface names to their stable rename targets
# (eth-lan / eth-diretta) when a matching /etc/systemd/network/*.link drop-in
# exists. This makes the wrapper config survive PCI re-enumeration even when
# the user runs this module BEFORE the post-stable-naming reboot (kernel
# still uses enpXsY, but the .link already promises eth-*). stable_name_for
# returns the original iface unchanged when no .link matches, so this is a
# no-op for hosts where stable naming wasn't set up.
_drup_control_iface_conf=$(stable_name_for "$_drup_control_iface")
_drup_diretta_iface_conf=$(stable_name_for "$_drup_diretta_iface")
if [[ "$_drup_control_iface_conf" != "$_drup_control_iface" ]]; then
    log_info "Mapping control NIC ${_drup_control_iface} → ${_drup_control_iface_conf} (stable name, applied at next boot)."
fi
if [[ "$_drup_diretta_iface_conf" != "$_drup_diretta_iface" ]]; then
    log_info "Mapping Diretta NIC ${_drup_diretta_iface} → ${_drup_diretta_iface_conf} (stable name, applied at next boot)."
fi

log_info "Setting INTERFACE / TARGET_INTERFACE / TARGET in ${_DRUP_CONF_FILE}"
if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would set INTERFACE=${_drup_control_iface_conf}, TARGET_INTERFACE=$([[ "$_drup_control_iface" == "$_drup_diretta_iface" ]] && echo '<empty: single NIC>' || echo "${_drup_diretta_iface_conf}"), TARGET=1"
else
    _drup_set_conf_var INTERFACE "$_drup_control_iface_conf"
    if [[ "$_drup_control_iface" == "$_drup_diretta_iface" ]]; then
        # Single-NIC: leave TARGET_INTERFACE empty so DRUP auto-detects.
        _drup_set_conf_var TARGET_INTERFACE ""
    else
        _drup_set_conf_var TARGET_INTERFACE "$_drup_diretta_iface_conf"
    fi
    _drup_set_conf_var TARGET 1
fi

# --- 9. Web config UI (browser, port 8080) — optional --------------------
#
# install.sh --full does NOT install the web UI; it's a separate step
# (./install.sh --webui) that copies webui/ and runs a small Python server as
# diretta-renderer-webui.service on :8080. python3 was pre-installed above.
if ask_yes_no "Install the DirettaRendererUPnP web config UI (browser, port 8080)?" Y; then
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would run (as ${_drup_user}): cd ${_drup_dir} && ./install.sh --webui"
    else
        log_info "Installing the DRUP web UI via ./install.sh --webui"
        # Same TTY-direct, non-fatal pattern as the main install.sh run.
        set +e
        sudo -u "$_drup_user" -i bash -c "cd '${_drup_dir}' && ./install.sh --webui"
        _drup_webui_rc=$?
        set -e
        if [[ $_drup_webui_rc -ne 0 ]]; then
            log_warn "Web UI install exited (rc=${_drup_webui_rc}). The renderer itself is unaffected."
            log_warn "  Re-run later with: cd ${_drup_dir} && ./install.sh --webui"
        else
            log_info "Web UI enabled — reachable at http://<this-host>:8080 after reboot."
        fi
    fi
fi

# --- 10. Enable the service (don't start — wait for reboot) --------------

run_cmd systemctl enable "$_DRUP_SERVICE"

log_info "DRUP installed. The service is enabled and will start at next reboot."
log_info "Review ${_DRUP_CONF_FILE} before reboot if you need to tune CPU affinity, IRQ pinning, buffers, etc."
