#!/bin/bash
#
# lib/common.sh — shared helpers for fedora-audiophile-setup modules.
#
# Provides:
#   - log_info / log_warn / log_error / log_step
#   - ask_yes_no
#   - has_package, package_install
#   - run_cmd        (honors DRY_RUN)
#   - init_log
#   - list_modules
#   - run_all_modules / run_single_module
#

LOG_DIR="/var/log/audiophile-setup"
LOG_FILE=""

# ANSI colors
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[0;33m'
readonly C_GREEN='\033[0;32m'
readonly C_BLUE='\033[0;34m'
readonly C_BOLD='\033[1m'

# --- Logging ---------------------------------------------------------------

init_log() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

_log() {
    local color="$1" prefix="$2"; shift 2
    local msg="$*"
    local ts; ts=$(date '+%H:%M:%S')
    echo -e "${color}[${ts}] ${prefix}${C_RESET} ${msg}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "[$(date -Iseconds)] ${prefix} ${msg}" >> "$LOG_FILE"
    fi
}

log_info()  { _log "$C_BLUE"   "INFO " "$@"; }
log_warn()  { _log "$C_YELLOW" "WARN " "$@"; }
log_error() { _log "$C_RED"    "ERROR" "$@"; }
log_step()  { _log "$C_GREEN"  "STEP " "$@"; }

# --- RAM mode (volatile root) ----------------------------------------------

# Which RAM mode the RUNNING session booted with: "overlay", "volatile" or
# "none".
#
# Reads /proc/cmdline — the kernel actually running — and NOT grubby, which
# reports what the *next* boot will use. The question here is whether changes
# made right now survive a reboot, so only the live session matters. The two
# can disagree: right after Disable + before reboot, grubby says "none" while
# the session is still volatile.
current_ram_mode() {
    local cmdline
    cmdline=$(cat /proc/cmdline 2>/dev/null || true)
    if   [[ "$cmdline" == *"audiophile.overlay=1"*   ]]; then echo "overlay"
    elif [[ "$cmdline" == *"systemd.volatile=state"* ]]; then echo "volatile"
    else                                                      echo "none"
    fi
}

# Warn up-front when the running session throws writes away on reboot.
# Without this, a user can run the whole wizard (or a git pull, or an
# install) and silently lose all of it at the next boot.
warn_if_ram_mode() {
    case "$(current_ram_mode)" in
        overlay)
            log_warn "RAM mode is ACTIVE (overlayfs) — the root filesystem is a tmpfs overlay."
            log_warn "EVERYTHING written in this session is LOST on reboot: this wizard's"
            log_warn "changes, package installs, git pulls, compiled binaries. There is no"
            log_warn "in-session way to make a change permanent."
            log_warn "To persist changes: run the ram-mode module -> D) Disable, reboot, redo"
            log_warn "the changes on the disk-backed root, then Enable RAM mode again."
            ;;
        volatile)
            log_warn "RAM mode is ACTIVE (systemd.volatile=state) — /var is a tmpfs."
            log_warn "Writes under /var are LOST on reboot; /etc and /home stay on disk."
            ;;
    esac
}


# --- Prompts ---------------------------------------------------------------

# ask_yes_no "Question?" [default=Y|N]  — sets REPLY=0 (yes) or 1 (no)
ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local hint
    [[ "$default" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"

    while true; do
        read -r -p "$prompt $hint " answer
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# --- System helpers --------------------------------------------------------

has_package() {
    rpm -q "$1" >/dev/null 2>&1
}

is_service_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

is_service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# stable_name_for <iface> — print the stable rename target configured for
# this NIC via a /etc/systemd/network/*.link drop-in that matches by MAC,
# or print <iface> unchanged if no such .link exists.
#
# Works whether <iface> is the kernel-assigned name (enpXsY) or the
# already-renamed name (eth-lan / eth-diretta), since /sys/class/net/<name>/
# address always reflects the hardware MAC.
#
# Used by modules 10/11 (and downstream wrapper config writers) to make
# /etc/default/diretta-renderer and /etc/default/slim2diretta reference
# the stable names — so the config survives PCI re-enumeration even when
# module 10/11 is run BEFORE the post-stable-naming reboot (i.e. when the
# kernel still uses enpXsY but the .link files already promise eth-*).
stable_name_for() {
    local iface="$1"
    local mac
    mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || true)
    if [[ -z "$mac" ]]; then
        echo "$iface"
        return 0
    fi
    local f name=""
    while IFS= read -r f; do
        # Match the MAC line case-insensitively (systemd accepts either case).
        if grep -qiE "^MACAddress=[[:space:]]*${mac}[[:space:]]*$" "$f" 2>/dev/null; then
            name=$(grep -oP '^Name=\K\S+' "$f" 2>/dev/null | head -1)
            if [[ -n "$name" ]]; then
                echo "$name"
                return 0
            fi
        fi
    done < <(find /etc/systemd/network -maxdepth 1 -name '*.link' -type f 2>/dev/null)
    echo "$iface"
}

# ensure_diretta_nm_connection <iface> — pre-create a minimal NetworkManager
# profile for the Diretta NIC so DRUP and slim2Diretta install.sh scripts
# (which try to persist their own MTU via nmcli) don't fail to attach.
# Shared by modules 10 and 11 so they cannot drift.
#
# No-op if NetworkManager is not active (caller is on systemd-networkd or
# both inactive). Logs a warning and returns if nmcli is missing.
#
# Stable-naming aware: if /etc/systemd/network/10-diretta.link maps the
# passed iface's MAC to a stable name (eth-diretta), the NM profile is
# created with ifname=<stable> instead of ifname=<current-pci-name>. NM
# accepts a not-yet-existing ifname — the profile sits in 'available'
# state until the next-boot rename activates it under the new name. No
# SSH lockout risk: the LAN side is on a separate NIC. Any legacy
# 'diretta-<old-pci-name>' profile from a previous wizard run is removed
# so it doesn't dangle bound to a name that disappears at next boot.
#
# Idempotent: if a profile with the canonical 'diretta-<target>' name
# already exists (single, non-duplicate), the function returns without
# re-creating it. Multiple duplicates from older buggy wizard runs are
# deleted and one clean profile is recreated. If some OTHER profile is
# already bound to the iface (e.g. an auto-created NM connection), the
# function skips creation to avoid stomping on user setup.
ensure_diretta_nm_connection() {
    local iface="$1"
    is_service_active NetworkManager || return 0
    if ! command -v nmcli >/dev/null 2>&1; then
        log_warn "NM is active but nmcli is missing — cannot pre-create profile for ${iface}."
        return 0
    fi

    # If stable-naming is set up for this NIC, target the stable name. NM
    # accepts ifname= for an interface that doesn't exist yet; the profile
    # stays dormant until the post-reboot rename creates eth-diretta. The
    # bound-check below still uses the CURRENT iface (whatever the kernel
    # currently uses) to detect existing profiles attached to the device
    # right now.
    local target_iface
    target_iface=$(stable_name_for "$iface")
    local con_name="diretta-${target_iface}"

    # Migration: if we're switching to a stable name, delete any legacy
    # 'diretta-<old-pci-name>' profile from a previous install — it would
    # otherwise dangle bound to a name that disappears at next-boot rename.
    if [[ "$target_iface" != "$iface" ]]; then
        local legacy_uuid
        while IFS= read -r legacy_uuid; do
            [[ -z "$legacy_uuid" ]] && continue
            log_info "Removing legacy NM profile 'diretta-${iface}' (UUID ${legacy_uuid}) — replaced by '${con_name}' bound to the stable name."
            run_cmd nmcli connection delete "$legacy_uuid"
        done < <(nmcli -t -f UUID,NAME connection show 2>/dev/null \
            | awk -F: -v n="diretta-${iface}" '$2==n {print $1}')
    fi

    # Count profiles named "<con_name>" by UUID. Earlier wizard versions
    # could create duplicates (DEVICE column was '--' for inactive
    # connections, missing the existence check). We now recover from any
    # leftover duplicates: delete them all and recreate a clean one.
    local -a our_uuids=()
    local uuid
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] && our_uuids+=("$uuid")
    done < <(nmcli -t -f UUID,NAME connection show 2>/dev/null \
        | awk -F: -v n="$con_name" '$2==n {print $1}')

    if [[ ${#our_uuids[@]} -gt 1 ]]; then
        log_warn "Found ${#our_uuids[@]} duplicate NM profiles named '${con_name}' — deleting all and recreating one clean."
        for uuid in "${our_uuids[@]}"; do
            run_cmd nmcli connection delete "$uuid"
        done
        # Fall through to the create step below.
    elif [[ ${#our_uuids[@]} -eq 1 ]]; then
        log_info "NM profile '${con_name}' already present (UUID ${our_uuids[0]}) — skipping."
        return 0
    fi

    # No diretta-* profile, but some OTHER profile may still be bound to
    # this iface (e.g. an auto-created one). Don't stomp on it.
    local bound
    bound=$(nmcli -t -f GENERAL.CONNECTION device show "$iface" 2>/dev/null | cut -d: -f2)
    if [[ -n "$bound" && "$bound" != "--" ]]; then
        log_info "NM profile already bound to ${iface}: '${bound}' — skipping."
        return 0
    fi

    log_info "Creating minimal NM profile '${con_name}' for ${target_iface} (link-local v4+v6, autoconnect)."
    run_cmd nmcli connection add type ethernet \
        ifname "$target_iface" \
        con-name "$con_name" \
        ipv4.method link-local \
        ipv6.method link-local \
        connection.autoconnect yes
}

# ensure_diretta_mtu_link <iface> — persist the Diretta NIC MTU, its
# stable name (eth-diretta), AND its offload-off tuning via a SINGLE
# systemd-udevd .link drop-in matched by MAC address. This is read by
# udevd at device coldplug, BEFORE and INDEPENDENTLY of whichever
# network manager is active, so it is the only place that works under
# BOTH NetworkManager and systemd-networkd. (DRUP / slim2Diretta
# install.sh also prompt for MTU and persist it via nmcli — NM-only,
# and a no-op/failure under networkd; that duplicate prompt is
# harmless: the .link is what reliably applies.)
#
# Offload disabling (gso/tso/gro/lro off): Diretta uses raw L2 frames
# and consumer NICs sometimes mishandle them under hardware offloads.
# Cost is minimal CPU added to the Diretta path, fully covered by the
# isolated audio core(s). Always-on for the Diretta NIC; no user prompt.
#
# Why a single .link doing rename + MTU (and not two separate files):
# systemd-udevd applies ONLY THE FIRST matching .link per device, in
# lexical order. If module 03's stable-naming step already wrote
# 10-diretta.link (rename by MAC → eth-diretta) and we wrote our MTU in a
# separate 50-…link, the 50- file would never be evaluated and MTUBytes=
# would be silently dropped. So we converge on ONE canonical file —
# /etc/systemd/network/10-diretta.link — that carries both the rename and
# the MTU. If a legacy 50-audiophile-diretta-*.link exists from a previous
# install (pre-stable-naming), its MTUBytes= value is migrated and the
# file is removed.
#
# Match by MAC + Type=ether: the MAC is stable across PCI re-enumeration
# (NIC swap, GPU insertion, added PCIe card), and Type=ether excludes
# virtual interfaces — important because the diretta-net-toggle bridge
# mode clones the LAN MAC onto br0; without Type=ether, a MAC-only match
# would be ambiguous between the physical NIC and the bridge.
#
# Idempotent: detects an existing MTU (canonical file or legacy file) and
# offers to keep it. DRY_RUN-aware. Shared by modules 10 and 11 so they
# cannot drift.
ensure_diretta_mtu_link() {
    local iface="$1"
    local canonical_file="/etc/systemd/network/10-diretta.link"
    local tag="# Generated by fedora-audiophile-setup"
    local mac choice mtu="" cur=""

    # Read the MAC of the passed iface. Works whether <iface> is still the
    # kernel-assigned name (enpXsY) or already the renamed name (eth-diretta)
    # — /sys/class/net/<name>/address always reflects the hardware MAC.
    mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || true)
    if [[ -z "$mac" ]]; then
        log_error "Cannot read MAC address for ${iface} (no /sys/class/net/${iface}/address) — skipping Diretta .link drop-in."
        return 1
    fi

    # Migrate any legacy 50-audiophile-diretta-*.link (older pattern that
    # silently never applied alongside a MAC-rename .link — see header).
    local legacy
    while IFS= read -r legacy; do
        local legacy_mtu
        legacy_mtu=$(grep -oP '^MTUBytes=\K[0-9]+' "$legacy" 2>/dev/null || true)
        if [[ -n "$legacy_mtu" && -z "$cur" ]]; then
            cur="$legacy_mtu"
            log_info "Found legacy MTU drop-in ${legacy} with MTUBytes=${legacy_mtu} — will migrate to ${canonical_file}."
        fi
        log_info "Removing legacy ${legacy} (superseded by ${canonical_file})."
        if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
            rm -f "$legacy"
        fi
    done < <(find /etc/systemd/network -maxdepth 1 -name '50-audiophile-diretta-*.link' -type f 2>/dev/null)

    # If the canonical file already exists with a MTUBytes=, that value
    # overrides any migrated legacy value.
    if [[ -f "$canonical_file" ]]; then
        local existing_mtu
        existing_mtu=$(grep -oP '^MTUBytes=\K[0-9]+' "$canonical_file" 2>/dev/null || true)
        if [[ -n "$existing_mtu" ]]; then
            cur="$existing_mtu"
        fi
    fi

    # Keep existing value, or prompt to reconfigure.
    if [[ -n "$cur" ]]; then
        if ! ask_yes_no "Diretta NIC MTU already configured (MTUBytes=${cur} in ${canonical_file}). Reconfigure?" N; then
            log_info "Keeping the existing MTU value for Diretta NIC (MTUBytes=${cur})."
            # If we only know the value from a legacy file just migrated, we
            # still need to write the canonical file with that value.
            if [[ ! -f "$canonical_file" ]]; then
                mtu="$cur"
            else
                return 0
            fi
        fi
    fi

    # Prompt for MTU if not carried over from the keep-path.
    if [[ -z "$mtu" ]]; then
        echo
        echo "MTU for the Diretta NIC (MAC ${mac}):"
        echo "  1) 1500   (standard)"
        echo "  2) 9014   (jumbo — recommended; RTL8156 and most jumbo-capable NICs)"
        echo "  3) 16128  (max — only if your Diretta target supports it)"
        while [[ -z "$mtu" ]]; do
            read -r -p "Choose [2]: " choice
            case "${choice:-2}" in
                1) mtu=1500 ;;
                2) mtu=9014 ;;
                3) mtu=16128 ;;
                *) echo "Invalid choice." ;;
            esac
        done
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would write ${canonical_file} (MACAddress=${mac}, Name=eth-diretta, MTUBytes=${mtu})"
        return 0
    fi

    mkdir -p /etc/systemd/network
    cat > "$canonical_file" <<EOF
${tag}
# Diretta NIC: stable name (eth-diretta) + MTU + hardware offloads off.
# udev applies only the FIRST matching .link per device, so rename, MTU, and
# offload tuning must live together in this single file. Type=ether excludes
# virtual interfaces (bridge created by diretta-net-toggle clones this MAC
# onto br0; without Type=ether the match would be ambiguous).
[Match]
MACAddress=${mac}
Type=ether

[Link]
Name=eth-diretta
MTUBytes=${mtu}
# Hardware offloads disabled on the Diretta NIC: Diretta uses raw L2 frames,
# and consumer-grade NICs sometimes corrupt those when offloads (segmentation,
# generic/large receive) re-assemble or split packets. Cost is a slightly
# higher CPU load on the Diretta path, fully absorbed by the isolated audio
# core(s). Directives unsupported by a given driver are logged as warnings by
# systemd-udevd and skipped — safe on any NIC.
GenericSegmentationOffload=false
TCPSegmentationOffload=false
GenericReceiveOffload=false
LargeReceiveOffload=false
EOF
    log_info "Wrote ${canonical_file} (MAC=${mac}, Name=eth-diretta, MTUBytes=${mtu}, offloads off). Applied by systemd-udevd at next boot (after 'sudo dracut -f' to refresh initramfs). Works under NetworkManager and systemd-networkd."
}

# --- Command execution with DRY_RUN support --------------------------------

# run_cmd <cmd...> — execute (or echo if DRY_RUN=1) a command, logging stdout/stderr.
run_cmd() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would execute: $*"
        return 0
    fi
    log_info "Executing: $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# --- Module discovery ------------------------------------------------------

# list_modules — print module names in execution order, one per line.
# Module file format: modules/NN-name.sh  → name printed as "name".
list_modules() {
    find "$MODULES_DIR" -maxdepth 1 -name '[0-9][0-9]-*.sh' -type f 2>/dev/null \
        | sort \
        | sed -E 's|.*/[0-9]+-([^/]+)\.sh|\1|'
}

# resolve_module_path <short-name> — print full path or empty if not found.
resolve_module_path() {
    local name="$1"
    find "$MODULES_DIR" -maxdepth 1 -name "[0-9][0-9]-${name}.sh" -type f 2>/dev/null \
        | head -1
}

run_all_modules() {
    # Read the list FIRST into an array, then iterate with `for`. Do NOT use
    # `while IFS= read -r module; do ... done < <(list_modules)` — that
    # redirects stdin of the whole loop body (and every module sourced from
    # it) to the list_modules pipe, which silently steals input from any
    # interactive `read` inside a module. Bug fixed: previously, ask_yes_no
    # inside a module consumed the names of the remaining modules as its
    # "answers", looping 10x on "Please answer yes or no." and prematurely
    # ending the run.
    local -a modules=()
    local m
    while IFS= read -r m; do modules+=("$m"); done < <(list_modules)

    local count=${#modules[@]}
    if [[ "$count" -eq 0 ]]; then
        log_warn "No modules found in $MODULES_DIR — nothing to do."
        return 0
    fi

    log_step "Running $count module(s) in order."
    local module path rc
    local -a failed=()
    for module in "${modules[@]}"; do
        path=$(resolve_module_path "$module")
        log_step "→ $module"
        # Run each module in a subshell so a failure — including a `set -e`
        # abort inside the module or in a helper script it calls — is
        # contained: it kills only the subshell, not the whole wizard. The
        # subshell inherits every shell variable (LOG_FILE, DRY_RUN,
        # SCRIPT_DIR, …) and the controlling terminal, so logging and
        # interactive prompts still work. Modules are independent units (each
        # is runnable via --only), so none relies on parent-shell state.
        #
        # We must NOT put the subshell in an `if`/`&&`/`||` context: bash then
        # ignores `set -e` *inside* it, so the module wouldn't abort on its own
        # errors. Instead drop the parent's `set -e` only around a bare
        # subshell call and capture its status. Each module re-enables
        # `set -euo pipefail` on its first line, so error-aborting still works
        # inside the subshell.
        set +e
        # shellcheck source=/dev/null
        ( source "$path" )
        rc=$?
        set -e
        if [[ "$rc" -eq 0 ]]; then
            continue
        fi
        # Preflight is the hard gate (architecture, OS, IPv6): if it fails,
        # nothing downstream is meaningful — abort the whole run.
        if [[ "$module" == "preflight" ]]; then
            log_error "Preflight failed (rc=$rc) — aborting. Fix the reported pre-conditions and re-run."
            exit "$rc"
        fi
        # Any other module: log loudly and keep going, so one failure no longer
        # blocks every later module (a user shouldn't have to run them by hand).
        log_error "Module '$module' failed (rc=$rc). Continuing with the remaining modules."
        log_error "  Re-run it on its own later with: sudo ./setup.sh --only $module"
        failed+=("$module")
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_warn "Finished, but ${#failed[@]} module(s) failed: ${failed[*]}"
        log_warn "Address the errors above, then re-run each with: sudo ./setup.sh --only <name>"
    else
        log_info "All $count modules completed."
    fi
}

run_single_module() {
    local name="$1"
    local path
    path=$(resolve_module_path "$name")

    if [[ -z "$path" ]]; then
        log_error "Module not found: $name"
        log_info "Available modules:"
        list_modules | sed 's/^/  /'
        exit 1
    fi

    log_step "Running single module: $name"
    # shellcheck source=/dev/null
    source "$path"
}

# module_description <path> — print the short description from the module's
# header line `# NN-name — description`. Empty if the file has no match.
module_description() {
    local path="$1"
    [[ -r "$path" ]] || return 0
    awk '
        /^# [0-9]+-[a-z0-9-]+ — / {
            sub(/^# [0-9]+-[a-z0-9-]+ — /, "");
            print;
            exit;
        }
    ' "$path"
}

# show_menu_and_dispatch — interactive numbered menu. Option 1 runs all
# modules in order (default on Enter); options 2..N run one module
# standalone; the last option exits cleanly.
#
# Each module row shows the file-prefix module number (NN) before the
# short name, e.g. "2) 00 preflight". The leading number on the line
# (1, 2, …) is the menu choice; the NN matches the modules/NN-name.sh
# file and the references used throughout the documentation. The two are
# intentionally distinct because the menu has extra entries (Full
# install, Exit) that don't map to a module.
show_menu_and_dispatch() {
    local -a names=()
    while IFS= read -r m; do names+=("$m"); done < <(list_modules)
    if [[ ${#names[@]} -eq 0 ]]; then
        log_warn "No modules found in $MODULES_DIR — nothing to do."
        return 0
    fi

    # Width of the longest "NN name" label, for visual alignment. Each
    # module row prints "NN name" (3-char prefix), so reserve length+3.
    local maxw=12  # at least as wide as "Full install"
    local n
    for n in "${names[@]}"; do
        (( ${#n} + 3 > maxw )) && maxw=$(( ${#n} + 3 ))
    done

    echo
    echo "What do you want to do?"
    echo
    printf "  %2d) %-*s   %s\n" 1 "$maxw" "Full install" "all modules in order (recommended)"
    local i=2 path desc num
    for n in "${names[@]}"; do
        path=$(resolve_module_path "$n")
        num=$(basename "$path" | sed -E 's/^([0-9]+)-.*/\1/')
        desc=$(module_description "$path")
        printf "  %2d) %-*s — %s\n" "$i" "$maxw" "$num $n" "${desc:-(no description)}"
        i=$((i+1))
    done
    local exit_idx=$i
    printf "  %2d) %-*s\n" "$exit_idx" "$maxw" "Exit"
    echo

    local choice
    while true; do
        read -r -p "Choose [1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" == "1" ]]; then
            run_all_modules
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 2 && choice < exit_idx )); then
            run_single_module "${names[$((choice-2))]}"
            return 0
        elif [[ "$choice" == "$exit_idx" ]]; then
            log_info "Bye."
            exit 0
        fi
        echo "Invalid choice. Enter a number between 1 and ${exit_idx}."
    done
}
