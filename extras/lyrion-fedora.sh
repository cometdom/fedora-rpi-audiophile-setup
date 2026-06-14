#!/bin/bash
# =============================================================================
# lyrion-fedora.sh — Lyrion Music Server management
# Standalone script for Fedora on Raspberry Pi (aarch64)
#
# Features:
#   - Install / Update / Remove Lyrion Music Server via RPM
#   - Service control (start / stop / enable / disable)
#   - Performance tuning: CPUAffinity, Nice, dbhighmem
#   - CPU0-only mode: pin LMS to cpu0 to keep other cores free for audio
#   - Audio resampling via sox (custom-convert.conf)
#   - Scheduled tasks (nightly restart, library scan)
#   - Firewall management via firewalld
#
# Requirements:
#   - Fedora (tested on Fedora 39/40 aarch64)
#   - Raspberry Pi (any model with 4+ cores recommended for CPU0 mode)
#   - Run as root or via sudo
# =============================================================================
#
# ----------------------------------------------------------------------------
# OPTIONAL COMPANION — contributed by Auke (Audiophile Style forum), adapted
# from his DietPi script. NOT part of the wizard's main install; run it on its
# own:  sudo ./extras/lyrion-fedora.sh
#
# LMS is a music *server* (library, scanning, transcoding, web UI on :9000).
# The audiophile-preferred topology runs it on a SEPARATE box and keeps this
# host a minimal player — only co-locate it on the same Pi if you don't have
# another server.
#
# Tested on Fedora aarch64 (Raspberry Pi). On x86_64 it is EXPERIMENTAL: the
# download fallback URL, the sox-resampling Bin path (Bin/aarch64-linux/) and a
# couple of defaults assume aarch64 — paste the correct x86_64 .rpm URL when
# prompted, and expect the optional sox-resampling feature to need adjusting.
# Bundled verbatim; please report issues so a proper x86_64 pass can follow.
# ----------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# CONFIGURATION — adjust to taste
# =============================================================================

LMS_SERVICE="lyrionmusicserver"
LMS_SERVICE_LEGACY="logitechmediaserver"
LMS_USER="squeezeboxserver"
LMS_DATA_DIR="/var/lib/squeezeboxserver"
LMS_LOG_DIR="/var/log/squeezeboxserver"
LMS_SERVER_PREFS="${LMS_DATA_DIR}/prefs/server.prefs"
LMS_OVERRIDE_DIR="/etc/systemd/system/${LMS_SERVICE}.service.d"
LMS_TUNING_CONF="${LMS_OVERRIDE_DIR}/tuning.conf"
LMS_SCAN_CRON="/etc/cron.d/lms-scan"
LMS_RESTART_CRON="/etc/cron.d/lms-restart"
LMS_CHANNEL_STABLE="https://lyrion.org/lms-server-repository/stable.xml"
LMS_PORT_WEB=9000
LMS_PORT_CLI=9090
LMS_PORT_SLIM=3483

# Default CPU affinity — can be overridden by CPU0 mode
LMS_CPU_AFFINITY="${LMS_CPU_AFFINITY:-0-3}"

# Resampling paths
LMS_CONVERT_CONF="/etc/squeezeboxserver/custom-convert.conf"
LMS_RESAMPLE_SCRIPT="/usr/local/bin/lms-resample.sh"
LMS_SOX_BIN="/usr/share/squeezeboxserver/Bin/aarch64-linux/sox"

MEDIA_GROUP="audio"

# =============================================================================
# COLOURS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# PRINT HELPERS
# =============================================================================

print_success() { echo -e "  ${GREEN}✓${NC}  $*"; }
print_error()   { echo -e "  ${RED}✗${NC}  $*"; }
print_warning() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
print_info()    { echo -e "  ${BLUE}ℹ${NC}  $*"; }
print_step()    { echo -e "  ${CYAN}→${NC}  $*"; }

print_header() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# =============================================================================
# ROOT CHECK
# =============================================================================

_require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}ERROR: This script must be run as root (use sudo).${NC}" >&2
        exit 1
    fi
}

# =============================================================================
# STATE VARIABLES
# =============================================================================

LMS_INSTALLED=0
LMS_RUNNING=0
LMS_VERSION=""
LMS_DBHIGHMEM=0
LMS_UPDATE_AVAILABLE=""
LMS_COLOCATION=0
LMS_DL_URL=""
LMS_DL_VERSION=""

# =============================================================================
# SERVICE HELPERS
# =============================================================================

_service_stop_safe() {
    local svc="$1"
    local timeout="${2:-20}"
    print_step "Stopping ${svc}..."
    systemctl stop "$svc" 2>/dev/null || true
    local i=0
    while systemctl is-active "$svc" &>/dev/null && [[ $i -lt $timeout ]]; do
        sleep 1; (( i++ ))
    done
    systemctl is-active "$svc" &>/dev/null \
        && print_warning "${svc} still running after ${timeout}s" \
        || print_success "${svc} stopped"
}

_service_start_safe() {
    local svc="$1"
    local timeout="${2:-30}"
    print_step "Starting ${svc}..."
    systemctl start "$svc" 2>/dev/null || true
    local i=0
    while ! systemctl is-active "$svc" &>/dev/null && [[ $i -lt $timeout ]]; do
        sleep 1; (( i++ ))
    done
    systemctl is-active "$svc" &>/dev/null \
        && print_success "${svc} started" \
        || print_warning "${svc} did not start within ${timeout}s"
}

# =============================================================================
# BACKUP
# =============================================================================

create_backup() {
    local backup_dir="${BACKUP_DIR:-/root/lms-backups}"
    [[ ! -d "$LMS_DATA_DIR/prefs" ]] && return 0
    mkdir -p "$backup_dir"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local dest="${backup_dir}/lms-prefs-${ts}.tar.gz"
    tar czf "$dest" -C "$LMS_DATA_DIR" prefs 2>/dev/null \
        && print_info "Backup created: ${dest}" \
        || print_warning "Backup skipped (could not write to ${backup_dir})"
}

# RAM mode stubs — not applicable on Fedora/standard install, kept for API compatibility
ram_is_active()     { return 1; }
ram_is_configured() { return 1; }
_warn_if_ram_active()     { return 0; }
_warn_if_ram_configured() { return 0; }

# =============================================================================
# DETECTION
# =============================================================================

_detect_lyrion() {
    LMS_INSTALLED=0; LMS_RUNNING=0; LMS_VERSION=""; LMS_DBHIGHMEM=0; LMS_COLOCATION=0

    if rpm -q "${LMS_SERVICE}" &>/dev/null; then
        LMS_INSTALLED=1
        LMS_VERSION=$(rpm -q --queryformat '%{VERSION}' "${LMS_SERVICE}" 2>/dev/null || echo "unknown")
    elif rpm -q "${LMS_SERVICE_LEGACY}" &>/dev/null; then
        LMS_INSTALLED=1
        LMS_VERSION=$(rpm -q --queryformat '%{VERSION}' "${LMS_SERVICE_LEGACY}" 2>/dev/null || echo "8.x-legacy")
    fi

    if [[ $LMS_INSTALLED -eq 1 ]]; then
        systemctl is-active "${LMS_SERVICE}"        &>/dev/null && LMS_RUNNING=1
        systemctl is-active "${LMS_SERVICE_LEGACY}" &>/dev/null && LMS_RUNNING=1

        if [[ -f "${LMS_SERVER_PREFS}" ]]; then
            local val
            val=$(grep "^dbhighmem:" "${LMS_SERVER_PREFS}" 2>/dev/null \
                | awk '{print $2}' | tr -d '[:space:]')
            [[ "$val" == "1" ]] && LMS_DBHIGHMEM=1
        fi

        if [[ -f "${LMS_TUNING_CONF}" ]]; then
            grep -q "^CPUAffinity=0$" "${LMS_TUNING_CONF}" 2>/dev/null && LMS_COLOCATION=1
        fi
    fi
}

_detect_lms_update_available() {
    LMS_UPDATE_AVAILABLE=""
    [[ $LMS_INSTALLED -eq 0 ]] && return

    local latest=""

    local json
    json=$(curl -sf --max-time 8 \
        "https://lyrion.org/lms-server-repository/servers.json" 2>/dev/null || echo "")
    if [[ -n "$json" ]] && command -v python3 &>/dev/null; then
        latest=$(echo "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for section in ['stable', 'latest']:
        ver = d.get(section, {}).get('rpmarm64', {}).get('version', '') \
           or d.get(section, {}).get('debarm',  {}).get('version', '')
        if ver: print(ver); break
except: pass
" 2>/dev/null || echo "")
    fi

    if [[ -z "$latest" ]]; then
        local xml
        xml=$(curl -sf --max-time 8 "${LMS_CHANNEL_STABLE}" 2>/dev/null || echo "")
        [[ -n "$xml" ]] && latest=$(echo "$xml" | grep -o '<rpmarm64[^>]*>' \
            | grep -o 'version="[^"]*"' | cut -d'"' -f2 | head -1)
    fi

    if [[ -n "$latest" && -n "$LMS_VERSION" ]]; then
        # Simple version comparison (works for X.Y.Z)
        if [[ "$latest" != "$LMS_VERSION" ]]; then
            LMS_UPDATE_AVAILABLE="$latest"
        fi
    fi
}

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

_lms_active_service() {
    systemctl is-active "${LMS_SERVICE}"        &>/dev/null && echo "$LMS_SERVICE"        && return
    systemctl is-active "${LMS_SERVICE_LEGACY}" &>/dev/null && echo "$LMS_SERVICE_LEGACY" && return
    echo "$LMS_SERVICE"
}

_lms_open_ports() {
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=${LMS_PORT_WEB}/tcp  >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=${LMS_PORT_CLI}/tcp  >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=${LMS_PORT_SLIM}/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=${LMS_PORT_SLIM}/udp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        print_success "LMS ports opened in firewalld (9000, 9090, 3483 tcp+udp)"
    else
        print_info "firewalld not running — ports accessible by default"
    fi
}

# =============================================================================
# CPU AFFINITY
# =============================================================================
#
# LMS_CPU_AFFINITY controls which CPU cores LMS may use:
#
#   "0"     — CPU0 only (pin LMS to cpu0, keep cpu1-3 free for audio I/O)
#   "0-3"   — All cores (default, standard server mode)
#   "1-3"   — Cores 1-3 only (keep cpu0 free for OS/IRQ)
#
# The CPU0-only mode is useful on a dedicated RPi where the remaining
# cores are used by real-time audio processes (e.g. Diretta, Scream).

_lms_cpu_affinity_label() {
    local aff="${1:-${LMS_CPU_AFFINITY}}"
    case "$aff" in
        "0")   echo "cpu0 only  (keeps cpu1-3 free for audio)" ;;
        "0-3") echo "all cores  (cpu0-3, standard)" ;;
        "1-3") echo "cpu1-3     (keeps cpu0 free for OS/IRQ)" ;;
        *)     echo "${aff}" ;;
    esac
}

_lms_set_cpu_affinity() {
    print_header "CPU Affinity — LMS Core Pinning"
    echo "  Current setting: $(_lms_cpu_affinity_label)"
    echo ""
    echo "  On a dedicated RPi audio server, pinning LMS to cpu0 keeps"
    echo "  cpu1-3 available for real-time audio tasks (IRQs, Diretta, etc)."
    echo ""
    echo "  [1] cpu0 only     — pin LMS to cpu0, free cpu1-3 for audio  [recommended for RT audio]"
    echo "  [2] All cores     — cpu0-3  (standard, no restriction)"
    echo "  [3] cpu1-3 only   — keep cpu0 free for OS/IRQ tasks"
    echo "  [4] Custom        — enter affinity string manually"
    echo "  [0] Back"
    echo ""
    echo -n "  Choice: "; read -r c

    local new_affinity=""
    case "$c" in
        1) new_affinity="0" ;;
        2) new_affinity="0-3" ;;
        3) new_affinity="1-3" ;;
        4)
            echo ""
            echo "  Enter CPUAffinity value (e.g. '0', '0-3', '0,2', '1-3'):"
            echo -n "  > "; read -r new_affinity
            [[ -z "$new_affinity" ]] && { print_error "Empty input — cancelled"; return; }
            ;;
        0) return ;;
        *) print_error "Invalid choice"; return ;;
    esac

    LMS_CPU_AFFINITY="$new_affinity"
    print_info "CPU affinity set to: ${new_affinity}  ($(_lms_cpu_affinity_label "$new_affinity"))"
    echo ""
    echo -n "  Apply now (rewrites tuning override)? (y/n) "; read -r r
    if [[ "$r" =~ ^[Yy]$ ]]; then
        _lms_apply_service_tuning "-5"
        _lms_restart_after_change
    else
        print_info "Setting saved — apply via Performance Tuning → [1]"
    fi
}

# =============================================================================
# SERVICE TUNING OVERRIDE
# =============================================================================

_lms_apply_service_tuning() {
    local nice_val="${1:--5}"
    local cpu_affinity="${LMS_CPU_AFFINITY:-0-3}"

    mkdir -p "$LMS_OVERRIDE_DIR"
    cat > "$LMS_TUNING_CONF" << EOF
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
# Created by lyrion-fedora.sh
CPUAffinity=${cpu_affinity}
Nice=${nice_val}
IOSchedulingClass=best-effort
IOSchedulingPriority=2
LimitNOFILE=65536
Restart=on-failure
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=30
EOF
    systemctl daemon-reload
    [[ "$cpu_affinity" == "0" ]] && LMS_COLOCATION=1 || LMS_COLOCATION=0
    print_success "Service tuning applied (CPUAffinity=${cpu_affinity}, Nice=${nice_val})"
}

_lms_apply_server_prefs() {
    if [[ ! -f "$LMS_SERVER_PREFS" ]]; then
        print_warning "server.prefs not found: ${LMS_SERVER_PREFS}"
        print_info    "Start LMS first, then run again"
        return 1
    fi

    local was_running=0
    [[ $LMS_RUNNING -eq 1 ]] && was_running=1

    print_info "Stopping LMS to safely edit server.prefs..."
    local svc; svc=$(_lms_active_service)
    _service_stop_safe "$svc" 20

    if grep -q "^dbhighmem:" "$LMS_SERVER_PREFS" 2>/dev/null; then
        sed -i 's/^dbhighmem:.*/dbhighmem: 1/' "$LMS_SERVER_PREFS"
    else
        echo "dbhighmem: 1" >> "$LMS_SERVER_PREFS"
    fi
    print_success "dbhighmem: 1 — SQLite cache 2 MB → 20 MB"

    if [[ $was_running -eq 1 ]]; then
        _service_start_safe "$svc" 30
        _detect_lyrion
        [[ $LMS_RUNNING -eq 1 ]] \
            && print_success "LMS restarted with improved database performance" \
            || print_warning "LMS not running after restart — check: journalctl -u ${svc} -n 30"
    fi
}

# =============================================================================
# DOWNLOAD URL RESOLUTION
# =============================================================================

_lms_resolve_download_url() {
    LMS_DL_URL=""
    LMS_DL_VERSION=""

    print_info "Querying stable channel..."
    local xml
    xml=$(curl -sf --max-time 15 "${LMS_CHANNEL_STABLE}" 2>/dev/null \
        || wget -qO- --timeout=15 "${LMS_CHANNEL_STABLE}" 2>/dev/null || echo "")

    if [[ -n "$xml" ]]; then
        # Try rpmarm64 tag first, fall back to debarm (version extraction only)
        LMS_DL_URL=$(echo "$xml" | grep -o '<rpmarm64[^>]*>' | grep -o 'url="[^"]*"' | cut -d'"' -f2 | head -1)
        LMS_DL_VERSION=$(echo "$xml" | grep -o '<rpmarm64[^>]*>' | grep -o 'version="[^"]*"' | cut -d'"' -f2 | head -1)

        # Fallback: derive from deb URL if no rpmarm64 tag
        if [[ -z "$LMS_DL_URL" ]]; then
            local deb_url deb_ver
            deb_url=$(echo "$xml" | grep -o '<debarm[^>]*>' | grep -o 'url="[^"]*"' | cut -d'"' -f2 | head -1)
            deb_ver=$(echo "$xml" | grep -o '<debarm[^>]*>' | grep -o 'version="[^"]*"' | cut -d'"' -f2 | head -1)
            if [[ -n "$deb_url" && -n "$deb_ver" ]]; then
                LMS_DL_VERSION="$deb_ver"
            fi
        fi
    fi
    [[ -n "$LMS_DL_URL" ]] && { print_success "URL resolved via stable.xml (rpmarm64)"; return 0; }

    print_info "Trying servers.json..."
    local json
    json=$(curl -sf --max-time 15 \
        "https://lyrion.org/lms-server-repository/servers.json" 2>/dev/null || echo "")
    if [[ -n "$json" ]] && command -v python3 &>/dev/null; then
        LMS_DL_URL=$(echo "$json" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for s in ['stable','latest']:
        u=d.get(s,{}).get('rpmarm64',{}).get('url','')
        if u and u.endswith('.rpm'): print(u); break
except: pass
" 2>/dev/null || echo "")
        LMS_DL_VERSION=$(echo "$json" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for s in ['stable','latest']:
        v=d.get(s,{}).get('rpmarm64',{}).get('version','') \
         or d.get(s,{}).get('debarm',{}).get('version','')
        if v: print(v); break
except: pass
" 2>/dev/null || echo "")
    fi
    [[ -n "$LMS_DL_URL" ]] && { print_success "URL resolved via servers.json (rpmarm64)"; return 0; }

    print_warning "URL could not be resolved automatically."
    echo ""
    echo "  Find the latest RPM at: https://lyrion.org/getting-started/"
    echo "  Select: Fedora / RedHat — ARM64 → right-click → copy link address"
    echo ""
    echo -n "  Paste .rpm URL here (Enter = hardcoded fallback v9.1.0): "
    read -r LMS_DL_URL

    if [[ -z "$LMS_DL_URL" ]]; then
        LMS_DL_URL="https://downloads.lms-community.org/LyrionMusicServer_v9.1.0/lyrionmusicserver_9.1.0_arm64.rpm"
        LMS_DL_VERSION="9.1.0"
        print_warning "Using hardcoded fallback URL (v${LMS_DL_VERSION}) — may not be the latest version"
        return 0
    fi

    [[ ! "$LMS_DL_URL" =~ \.rpm ]] && { print_error "URL does not end in .rpm"; LMS_DL_URL=""; return 1; }
    print_success "Manual URL accepted"
    return 0
}

# =============================================================================
# PRE-INSTALL CHECKS
# =============================================================================

_lms_preinstall_checks() {
    print_header "Pre-install checks"
    local warnings=0 errors=0

    echo "[ Disk Space ]"
    local avail_mb; avail_mb=$(df --output=avail -m / 2>/dev/null | tail -1 | tr -d ' ')
    if [[ "${avail_mb:-0}" -lt 200 ]]; then
        print_error "${avail_mb} MB free — minimum 200 MB required"; errors=$((errors + 1))
    elif [[ "${avail_mb:-0}" -lt 500 ]]; then
        print_warning "${avail_mb} MB free — tight for large library"; warnings=$((warnings + 1))
    else
        print_success "Disk space: ${avail_mb} MB free"
    fi

    echo ""
    echo "[ Memory ]"
    local total_mb; total_mb=$(awk '/^MemTotal:/ {printf "%.0f",$2/1024}' /proc/meminfo 2>/dev/null || echo "0")
    if [[ "${total_mb:-0}" -lt 512 ]]; then
        print_error "${total_mb} MB RAM — LMS requires at least 512 MB"; errors=$((errors + 1))
    elif [[ "${total_mb:-0}" -lt 1024 ]]; then
        print_warning "${total_mb} MB RAM — works, but large libraries are risky"; warnings=$((warnings + 1))
    else
        print_success "RAM: ${total_mb} MB"
    fi

    echo ""
    echo "[ Network ]"
    curl -sf --max-time 8 "https://lyrion.org" > /dev/null 2>/dev/null \
        && print_success "lyrion.org reachable" \
        || { print_error "lyrion.org not reachable"; errors=$((errors + 1)); }

    echo ""
    echo "[ Package Manager ]"
    if dnf --version &>/dev/null; then
        print_success "dnf available"
    else
        print_error "dnf not found"; errors=$((errors + 1))
    fi

    echo ""
    echo "[ Architecture ]"
    local arch; arch=$(uname -m)
    if [[ "$arch" == "aarch64" ]]; then
        print_success "Architecture: aarch64 (RPi compatible)"
    else
        print_warning "Architecture: ${arch} — RPM may not be available for this arch"
        warnings=$((warnings + 1))
    fi

    echo ""
    echo "[ sox (audio resampling) ]"
    _lms_sox_detect
    if [[ $LMS_SOX_AVAILABLE -eq 1 ]]; then
        print_success "sox found: ${LMS_SOX_FOUND}"
    else
        print_info "sox not found — will be installed automatically"
        print_info "  (only needed for audio resampling, not for basic LMS)"
    fi

    echo ""
    echo "──────────────────────────────────────────────────────────────"
    if [[ $errors -gt 0 ]]; then
        print_error "${errors} blocking problem(s)"
        echo -n "  Continue anyway? (y/n) "; read -r r; [[ ! "$r" =~ ^[Yy]$ ]] && return 1
    elif [[ $warnings -gt 0 ]]; then
        print_warning "${warnings} warning(s)"
        echo -n "  Continue? (y/n) "; read -r r; [[ ! "$r" =~ ^[Yy]$ ]] && return 1
    else
        print_success "All checks passed"
        echo -n "  Install? (y/n) "; read -r r; [[ ! "$r" =~ ^[Yy]$ ]] && return 1
    fi
    return 0
}

# =============================================================================
# SERVICE CONTROL
# =============================================================================

_lms_service_control() {
    print_header "LMS — Service Management"
    if [[ $LMS_INSTALLED -eq 0 ]]; then print_error "LMS not installed"; return; fi

    local autostart="disabled"
    systemctl is-enabled "$LMS_SERVICE" &>/dev/null && autostart="enabled"
    echo -e "  Status:    $([ $LMS_RUNNING -eq 1 ] && echo "${GREEN}running ✓${NC}" || echo "${YELLOW}stopped${NC}")"
    echo -e "  Autostart: $([ "$autostart" = "enabled" ] && echo "${GREEN}enabled ✓${NC}" || echo "${YELLOW}disabled${NC}")"
    echo ""
    local scan_active=0 restart_active=0
    [[ -f "$LMS_SCAN_CRON"             ]] && scan_active=1
    [[ -f "${LMS_SCAN_CRON}.paused"    ]] && scan_active=2
    [[ -f "$LMS_RESTART_CRON"          ]] && restart_active=1
    [[ -f "${LMS_RESTART_CRON}.paused" ]] && restart_active=2
    [[ $scan_active    -eq 1 ]] && print_info "Scan cron:    active"
    [[ $scan_active    -eq 2 ]] && print_info "Scan cron:    paused"
    [[ $restart_active -eq 1 ]] && print_info "Restart cron: active"
    [[ $restart_active -eq 2 ]] && print_info "Restart cron: paused"
    echo ""
    echo "  [1] Start now"
    echo "  [2] Stop now"
    echo "  [3] Restart now"
    echo "  [4] Stop + Disable         (permanently off at boot)"
    echo "  [5] Enable + Start         (restore autostart)"
    echo "  [0] Back"
    echo ""
    echo -n "  Choice: "; read -r c

    case "$c" in
        1) _service_start_safe "$LMS_SERVICE" 30; sleep 2; _detect_lyrion ;;
        2) _service_stop_safe  "$LMS_SERVICE" 20; _detect_lyrion ;;
        3) _service_stop_safe "$LMS_SERVICE" 20; sleep 1
           _service_start_safe "$LMS_SERVICE" 30; sleep 2; _detect_lyrion ;;
        4)
            _service_stop_safe "$LMS_SERVICE" 20
            systemctl disable "$LMS_SERVICE" 2>/dev/null || true
            _detect_lyrion; print_success "Stopped and disabled"
            [[ -f "$LMS_RESTART_CRON" ]] && mv "$LMS_RESTART_CRON" "${LMS_RESTART_CRON}.paused" && print_success "Restart cron paused"
            [[ -f "$LMS_SCAN_CRON"    ]] && mv "$LMS_SCAN_CRON"    "${LMS_SCAN_CRON}.paused"    && print_success "Scan cron paused"
            ;;
        5)
            systemctl enable "$LMS_SERVICE" 2>/dev/null || true
            _service_start_safe "$LMS_SERVICE" 30; sleep 3; _detect_lyrion
            [[ -f "${LMS_RESTART_CRON}.paused" ]] && mv "${LMS_RESTART_CRON}.paused" "$LMS_RESTART_CRON" && print_success "Restart cron restored"
            [[ -f "${LMS_SCAN_CRON}.paused"    ]] && mv "${LMS_SCAN_CRON}.paused"    "$LMS_SCAN_CRON"    && print_success "Scan cron restored"
            ;;
        0) return ;;
        *) print_error "Invalid choice" ;;
    esac
}

# =============================================================================
# INSTALL
# =============================================================================

_lms_install() {
    print_header "Install Lyrion Music Server"
    _lms_preinstall_checks || return
    read -r -t 0.1 _ 2>/dev/null || true

    if [[ $LMS_INSTALLED -eq 1 ]]; then
        print_info "Already installed: v${LMS_VERSION}"
        echo -n "  Reinstall / upgrade? (y/n) "; read -r r
        [[ ! "$r" =~ ^[Yy]$ ]] && return
    fi

    echo ""
    _lms_resolve_download_url || return 1
    echo ""
    [[ -n "$LMS_DL_VERSION" ]] && print_success "Version: ${LMS_DL_VERSION}"
    print_info "URL     : ${LMS_DL_URL}"
    echo ""
    echo -n "  Download and install? (y/n) "; read -r r; [[ ! "$r" =~ ^[Yy]$ ]] && return

    print_step "Installing dependencies..."
    dnf install -y curl wget sox perl-Getopt-Long 2>/dev/null | grep -E "^(Error|Installed|Nothing)" || true
    _lms_sox_detect
    [[ $LMS_SOX_AVAILABLE -eq 1 ]] \
        && print_success "sox ready: ${LMS_SOX_FOUND}" \
        || print_warning "sox not available — audio resampling will not work"

    print_step "Downloading RPM..."
    local tmp_rpm="/tmp/lyrionmusicserver_latest.rpm"
    rm -f "$tmp_rpm"
    if ! curl -L --progress-bar "$LMS_DL_URL" -o "$tmp_rpm" 2>/dev/null && \
       ! wget --show-progress -O "$tmp_rpm" "$LMS_DL_URL" 2>/dev/null; then
        print_error "Download failed"; return 1
    fi

    print_step "Installing RPM..."
    dnf install -y "$tmp_rpm" 2>&1 | grep -E "^(Error|Installed|Running)" || true
    rm -f "$tmp_rpm"

    systemctl daemon-reload
    systemctl enable "${LMS_SERVICE}" 2>/dev/null || true
    systemctl start  "${LMS_SERVICE}" 2>/dev/null || true
    sleep 5; _detect_lyrion

    echo ""
    if [[ $LMS_RUNNING -eq 1 ]]; then
        print_success "Lyrion Music Server is running!"
        print_info    "Web UI: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${LMS_PORT_WEB}"
    else
        print_warning "LMS installed but not yet running"
        print_info    "Check: journalctl -u ${LMS_SERVICE} -n 50"
    fi

    _lms_open_ports
    print_step "Applying service tuning (CPUAffinity=${LMS_CPU_AFFINITY}, Nice=-5)..."
    _lms_apply_service_tuning "-5"

    echo ""
    echo -n "  Apply database performance boost (dbhighmem)? (y/n) [recommended] "
    read -r r; [[ "$r" =~ ^[Yy]$ ]] && _lms_apply_server_prefs

    getent group "${MEDIA_GROUP}" &>/dev/null \
        && usermod -aG "${MEDIA_GROUP}" "$LMS_USER" 2>/dev/null || true
}

# =============================================================================
# UPDATE
# =============================================================================

_lms_update() {
    print_header "Update Lyrion Music Server"

    [[ $LMS_INSTALLED -eq 0 ]] && { print_error "LMS not installed — use [2]"; return; }

    print_info "Installed: v${LMS_VERSION}"
    echo ""
    _lms_resolve_download_url || return 1

    if [[ -n "$LMS_DL_VERSION" ]]; then
        if [[ "$LMS_DL_VERSION" != "$LMS_VERSION" ]]; then
            print_warning "Update available: v${LMS_VERSION} → v${LMS_DL_VERSION}"
        else
            print_success "Already up-to-date: v${LMS_VERSION}"
            echo -n "  Force reinstall? (y/n) "; read -r r; [[ ! "$r" =~ ^[Yy]$ ]] && return
        fi
    fi

    echo -n "  Continue with update? (y/n) "; read -r r; [[ ! "$r" =~ ^[Yy]$ ]] && return

    local svc; svc=$(_lms_active_service)
    _service_stop_safe "$svc" 20; sleep 2

    local tmp_rpm="/tmp/lyrionmusicserver_update.rpm"
    rm -f "$tmp_rpm"
    if ! curl -L --progress-bar "$LMS_DL_URL" -o "$tmp_rpm" 2>/dev/null && \
       ! wget --show-progress -O "$tmp_rpm" "$LMS_DL_URL" 2>/dev/null; then
        print_error "Download failed — restarting previous version"
        _service_start_safe "$svc" 30; return 1
    fi

    dnf upgrade -y "$tmp_rpm" > /dev/null 2>&1 && print_success "Update installed!" \
        || { print_error "Update failed"; _service_start_safe "$svc" 30; rm -f "$tmp_rpm"; return 1; }
    rm -f "$tmp_rpm"

    systemctl daemon-reload
    _service_start_safe "$svc" 30; sleep 3; _detect_lyrion
    [[ $LMS_RUNNING -eq 1 ]] \
        && print_success "LMS updated and running! v${LMS_VERSION}" \
        || print_warning "LMS not running after update — check: journalctl -u ${svc} -n 50"
}

# =============================================================================
# PERFORMANCE TUNING
# =============================================================================

_lms_performance_menu() {
    print_header "LMS Performance Tuning"
    [[ $LMS_INSTALLED -eq 0 ]] && { print_error "LMS not installed"; return; }

    echo "Current status:"
    if [[ -f "$LMS_TUNING_CONF" ]]; then
        print_success "Service tuning applied:"
        grep -E "^(CPUAffinity|Nice|IOScheduling)" "$LMS_TUNING_CONF" 2>/dev/null | sed 's/^/    /'
    else
        print_warning "Service tuning not applied"
    fi
    [[ $LMS_DBHIGHMEM -eq 1 ]] \
        && print_success "Database boost: enabled (dbhighmem=1, 20 MB cache)" \
        || print_warning "Database boost: default (2 MB cache — slow with large libraries)"
    echo ""
    local aff_label; aff_label=$(_lms_cpu_affinity_label)
    echo "  Current CPU affinity : ${LMS_CPU_AFFINITY}  (${aff_label})"
    echo ""
    echo "  [1] Apply service tuning   (CPUAffinity=${LMS_CPU_AFFINITY}, Nice=-5)"
    echo "  [2] Database boost (dbhighmem) — biggest performance gain"
    echo "  [3] Apply both             (recommended)"
    echo "  [4] Set CPU affinity       (cpu0 only / all cores / custom)"
    echo "  [5] Show current settings"
    echo "  [0] Back"
    echo ""
    echo -n "  Choice [1-5]: "; read -r choice

    case "$choice" in
        1) _lms_apply_service_tuning "-5"
           systemctl restart "${LMS_SERVICE}" 2>/dev/null || true
           sleep 2; _detect_lyrion; print_success "Service tuning applied" ;;
        2) _lms_apply_server_prefs ;;
        3) _lms_apply_service_tuning "-5"
           _lms_apply_server_prefs
           systemctl restart "${LMS_SERVICE}" 2>/dev/null || true
           sleep 3; _detect_lyrion; print_success "Full performance tuning applied" ;;
        4) _lms_set_cpu_affinity ;;
        5) echo ""
           [[ -f "$LMS_TUNING_CONF" ]] && { print_info "Service override:"; grep -v "^[#$]" "$LMS_TUNING_CONF" | sed 's/^/    /'; }
           [[ -f "$LMS_SERVER_PREFS" ]] && { echo ""; print_info "server.prefs:"; grep -E "^(dbhighmem|serverPriority):" "$LMS_SERVER_PREFS" 2>/dev/null | sed 's/^/    /' || print_info "    (none set)"; } ;;
        0) return ;;
        *) print_error "Invalid choice" ;;
    esac
}

# =============================================================================
# SCHEDULED TASKS
# =============================================================================

_lms_schedule_menu() {
    while true; do
        print_header "LMS Scheduled tasks"

        echo "  Current state:"
        if [[ -f "$LMS_RESTART_CRON" ]]; then
            echo -e "  Nightly restart: ${GREEN}enabled — daily 02:00${NC}"
        elif [[ -f "${LMS_RESTART_CRON}.paused" ]]; then
            echo -e "  Nightly restart: ${YELLOW}paused${NC}"
        else
            echo -e "  Nightly restart: ${BLUE}not scheduled${NC}"
        fi

        if [[ -f "$LMS_SCAN_CRON" ]]; then
            grep -q "0 3 \* \* \*" "$LMS_SCAN_CRON" 2>/dev/null \
                && echo -e "  Library scan:    ${CYAN}daily — 03:00${NC}" \
                || echo -e "  Library scan:    ${CYAN}scheduled (custom)${NC}"
        elif [[ -f "${LMS_SCAN_CRON}.paused" ]]; then
            echo -e "  Library scan:    ${YELLOW}paused${NC}"
        else
            echo -e "  Library scan:    ${BLUE}not scheduled${NC}"
        fi

        echo ""
        echo "  [1] Enable nightly restart      (daily 02:00)"
        echo "  [2] Disable nightly restart"
        echo "  [3] Scan now"
        echo "  [4] Schedule: daily scan        (03:00)"
        echo "  [5] Schedule: weekly scan       (Sunday 03:00)"
        echo "  [6] Disable automatic scanning"
        echo "  [7] Show cron files"
        echo "  [8] Remove all scheduled tasks"
        echo "  [0] Back"
        echo ""
        echo -n "  Choice: "; read -r choice

        case "$choice" in
            1)
                cat > "$LMS_RESTART_CRON" << EOF
# LMS nightly restart — lyrion-fedora.sh
0 2 * * * root systemctl restart ${LMS_SERVICE} > /dev/null 2>&1 || true
EOF
                print_success "Nightly restart: daily 02:00"
                ;;
            2)
                [[ -f "$LMS_RESTART_CRON" ]] && rm "$LMS_RESTART_CRON" && print_success "Disabled" || print_info "Was not scheduled"
                ;;
            3)
                _detect_lyrion
                if [[ $LMS_RUNNING -ne 1 ]]; then
                    print_error "LMS is not running — cannot start scan"
                else
                    curl -sf --max-time 5 \
                        "http://127.0.0.1:${LMS_PORT_WEB}/jsonrpc.js" \
                        -d '{"method":"slim.request","params":["",["rescan"]]}' > /dev/null 2>&1 \
                        && print_success "Scan started" \
                        || print_warning "LMS JSON RPC not reachable — try after 30 seconds"
                fi
                ;;
            4)
                cat > "$LMS_SCAN_CRON" << EOF
# LMS daily library scan — lyrion-fedora.sh
0 3 * * * root curl -sf "http://127.0.0.1:${LMS_PORT_WEB}/jsonrpc.js" -d '{"method":"slim.request","params":["",["rescan"]]}' > /dev/null 2>&1 || true
EOF
                print_success "Scheduled: daily 03:00"
                ;;
            5)
                cat > "$LMS_SCAN_CRON" << EOF
# LMS weekly library scan — lyrion-fedora.sh
0 3 * * 0 root curl -sf "http://127.0.0.1:${LMS_PORT_WEB}/jsonrpc.js" -d '{"method":"slim.request","params":["",["rescan"]]}' > /dev/null 2>&1 || true
EOF
                print_success "Scheduled: weekly Sunday 03:00"
                ;;
            6)
                [[ -f "$LMS_SCAN_CRON" ]] && rm "$LMS_SCAN_CRON" && print_success "Automatic scan disabled" || print_info "Was not scheduled"
                ;;
            7)
                echo ""
                [[ -f "$LMS_SCAN_CRON"    ]] && { print_info "${LMS_SCAN_CRON}:"; cat "$LMS_SCAN_CRON" | sed 's/^/    /'; echo ""; }
                [[ -f "$LMS_RESTART_CRON" ]] && { print_info "${LMS_RESTART_CRON}:"; cat "$LMS_RESTART_CRON" | sed 's/^/    /'; }
                ;;
            8)
                local removed=0
                [[ -f "$LMS_SCAN_CRON"    ]] && rm "$LMS_SCAN_CRON"    && print_success "Scan schedule removed"    && removed=1
                [[ -f "$LMS_RESTART_CRON" ]] && rm "$LMS_RESTART_CRON" && print_success "Restart schedule removed" && removed=1
                [[ $removed -eq 0 ]] && print_info "No scheduled tasks active"
                ;;
            0) return ;;
            *) print_error "Invalid choice" ;;
        esac

        echo ""
        echo -n "  Press Enter to continue..."; read
    done
}

# =============================================================================
# AUDIO RESAMPLING
# =============================================================================

_lms_sox_detect() {
    LMS_SOX_AVAILABLE=0
    LMS_SOX_FOUND=""

    if [[ -x "$LMS_SOX_BIN" ]]; then
        LMS_SOX_AVAILABLE=1
        LMS_SOX_FOUND="$LMS_SOX_BIN"
    elif command -v sox &>/dev/null; then
        LMS_SOX_AVAILABLE=1
        LMS_SOX_FOUND=$(command -v sox)
    fi
}

_lms_sox_install() {
    print_step "Installing sox via dnf..."
    if dnf install -y sox > /dev/null 2>&1; then
        print_success "sox installed: $(command -v sox 2>/dev/null)"
    else
        print_error "sox installation failed — run manually: sudo dnf install sox"
        return 1
    fi
}

_lms_resample_detect() {
    LMS_RESAMPLE_ENABLED=0
    LMS_RESAMPLE_RATE=""
    LMS_RESAMPLE_QUALITY=""
    LMS_RESAMPLE_DITHER=0
    LMS_RESAMPLE_NORMALIZE=0
    LMS_RESAMPLE_MODE="downsample"

    [[ ! -f "$LMS_CONVERT_CONF" ]] && return

    if [[ -f "$LMS_RESAMPLE_SCRIPT" ]]; then
        LMS_RESAMPLE_ENABLED=1

        LMS_RESAMPLE_RATE=$(grep -oE 'rate (-[a-zA-Z]+ )?[0-9]+' "$LMS_RESAMPLE_SCRIPT" 2>/dev/null \
            | grep -oE '[0-9]+$' | tail -1 || echo "")

        grep -q "dither"       "$LMS_RESAMPLE_SCRIPT" 2>/dev/null && LMS_RESAMPLE_DITHER=1
        grep -q "gain -1\|norm" "$LMS_RESAMPLE_SCRIPT" 2>/dev/null && LMS_RESAMPLE_NORMALIZE=1

        if grep -q 'RATE.*-gt\|RATE.*-ne' "$LMS_RESAMPLE_SCRIPT" 2>/dev/null; then
            LMS_RESAMPLE_MODE="downsample"
        else
            LMS_RESAMPLE_MODE="force"
        fi

        if grep -qE "rate -v\b" "$LMS_RESAMPLE_SCRIPT" 2>/dev/null; then
            LMS_RESAMPLE_QUALITY="Very high (VHQ)"
        elif grep -qE "rate -h\b" "$LMS_RESAMPLE_SCRIPT" 2>/dev/null; then
            LMS_RESAMPLE_QUALITY="High (HQ)"
        else
            LMS_RESAMPLE_QUALITY="Standard"
        fi
    fi
}

_lms_resample_write_script() {
    local target_rate="$1"
    local quality="$2"
    local dither="$3"
    local normalize="$4"
    local mode="${5:-downsample}"

    local sox_bin="$LMS_SOX_BIN"
    [[ ! -x "$sox_bin" ]] && sox_bin=$(command -v sox 2>/dev/null || echo "sox")

    local dither_arg="" normalize_arg=""
    [[ "$dither"    == "1" ]] && dither_arg=" dither -S"
    [[ "$normalize" == "1" ]] && normalize_arg="gain -1 "

    local sox_quality_flag=""
    case "$quality" in
        vH) sox_quality_flag="-v" ;;
        h)  sox_quality_flag="-h" ;;
        *)  sox_quality_flag=""   ;;
    esac

    mkdir -p "$(dirname "$LMS_RESAMPLE_SCRIPT")"
    if [[ "$mode" == "force" ]]; then
        cat > "$LMS_RESAMPLE_SCRIPT" << SCRIPT
#!/bin/bash
# lms-resample.sh — generated by lyrion-fedora.sh
# Mode: FORCE — resample ALL files to ${target_rate} Hz regardless of source rate.
FILE="\$1"
${sox_bin} -q -t flac "\$FILE" -t flac -C 0 -b 24 - ${normalize_arg}rate ${sox_quality_flag} ${target_rate}${dither_arg}
SCRIPT
    else
        cat > "$LMS_RESAMPLE_SCRIPT" << SCRIPT
#!/bin/bash
# lms-resample.sh — generated by lyrion-fedora.sh
# Mode: DOWNSAMPLE — only resample files above ${target_rate} Hz.
FILE="\$1"
RATE=\$(soxi -r "\$FILE" 2>/dev/null || echo 0)
if [ "\$RATE" -gt ${target_rate} ]; then
    ${sox_bin} -q -t flac "\$FILE" -t flac -C 0 -b 24 - ${normalize_arg}rate ${sox_quality_flag} ${target_rate}${dither_arg}
else
    cat "\$FILE"
fi
SCRIPT
    fi

    chmod +x "$LMS_RESAMPLE_SCRIPT"
}

_lms_resample_write_conf() {
    mkdir -p "$(dirname "$LMS_CONVERT_CONF")"
    printf 'flc flc * *\n\t# F\n\t%s $FILE$\n' "$LMS_RESAMPLE_SCRIPT" \
        > "$LMS_CONVERT_CONF"
    local lms_gid; lms_gid=$(id -gn "${LMS_USER}" 2>/dev/null || echo "${LMS_USER}")
    chown "${LMS_USER}:${lms_gid}" "$LMS_CONVERT_CONF" 2>/dev/null || true
    chmod 644 "$LMS_CONVERT_CONF"
}

_lms_resample_disable() {
    local removed=0
    if [[ -f "$LMS_CONVERT_CONF" ]]; then
        rm -f "$LMS_CONVERT_CONF"
        print_success "custom-convert.conf removed"
        removed=1
    fi
    if [[ -f "$LMS_RESAMPLE_SCRIPT" ]]; then
        rm -f "$LMS_RESAMPLE_SCRIPT"
        print_success "Resampling script removed"
        removed=1
    fi
    [[ $removed -eq 0 ]] && print_info "Resampling was already disabled"
}

_lms_resample_status_line() {
    _lms_resample_detect
    if [[ $LMS_RESAMPLE_ENABLED -eq 1 ]]; then
        local rate_khz=$(( ${LMS_RESAMPLE_RATE:-0} / 1000 ))
        local mode_label="downsample"
        [[ "${LMS_RESAMPLE_MODE}" == "force" ]] && mode_label="force all"
        echo -e "  Resampling: ${GREEN}on — ${mode_label} → ${rate_khz} kHz, quality: ${LMS_RESAMPLE_QUALITY}${NC}"
        [[ $LMS_RESAMPLE_DITHER    -eq 1 ]] && echo -e "              ${GREEN}dither: on${NC}"    || echo -e "              dither: off"
        [[ $LMS_RESAMPLE_NORMALIZE -eq 1 ]] && echo -e "              ${GREEN}normalize: on${NC}" || echo -e "              normalize: off"
    else
        echo -e "  Resampling: ${BLUE}off (native / bitperfect)${NC}"
    fi
}

_lms_resample_menu() {
    while true; do
        print_header "LMS Audio Resampling"
        [[ $LMS_INSTALLED -eq 0 ]] && { print_error "LMS not installed"; return; }

        _lms_resample_detect
        _lms_sox_detect

        echo "  Current settings:"
        if [[ $LMS_RESAMPLE_ENABLED -eq 1 ]]; then
            local rate_khz=$(( ${LMS_RESAMPLE_RATE:-0} / 1000 ))
            print_success "Resampling: ON"
            if [[ "${LMS_RESAMPLE_MODE}" == "force" ]]; then
                print_info "  Mode        : Force (ALL files → ${LMS_RESAMPLE_RATE} Hz)"
            else
                print_info "  Mode        : Downsample (only files above ${LMS_RESAMPLE_RATE} Hz)"
            fi
            print_info "  Target rate : ${LMS_RESAMPLE_RATE} Hz  (${rate_khz} kHz)"
            print_info "  Quality     : ${LMS_RESAMPLE_QUALITY}"
            [[ $LMS_RESAMPLE_DITHER    -eq 1 ]] && print_success "  Dither      : on" || print_info "  Dither      : off"
            [[ $LMS_RESAMPLE_NORMALIZE -eq 1 ]] && print_success "  Normalize   : on" || print_info "  Normalize   : off"
            echo ""
            print_info "Script : ${LMS_RESAMPLE_SCRIPT}"
            print_info "Config : ${LMS_CONVERT_CONF}"
        else
            print_info "Resampling: OFF — bitperfect / native"
        fi

        echo ""
        if [[ $LMS_SOX_AVAILABLE -eq 1 ]]; then
            print_success "sox: ${LMS_SOX_FOUND}"
        else
            print_warning "sox: NOT installed — required for resampling"
        fi

        echo ""
        echo "  ── Sample rate ─────────────────────────────────────────"
        echo "  [1] Downsample only   (above target rate → resample)"
        echo "  [2] Force resample    (all files → target rate)"
        echo "  [D] Disable           (bitperfect)"
        echo ""
        echo "  ── Mode (current: ${LMS_RESAMPLE_MODE:-off}) ───────────────────────────────────"
        echo "  [M] Toggle mode       (downsample ↔ force)"
        echo ""
        echo "  ── Quality / Options ───────────────────────────────────"
        echo "  [3] Change quality"
        echo "  [4] Dither on/off"
        echo "  [5] Normalize on/off   (-1 dB headroom)"
        echo ""
        echo "  ── Info / Tools ────────────────────────────────────────"
        echo "  [6] Show current script"
        echo "  [7] Show current convert.conf"
        echo "  [8] Live log test (tail log)"
        [[ $LMS_SOX_AVAILABLE -eq 0 ]] && \
        echo "  [9] Install sox        (required for resampling)"
        echo "  [0] Back"
        echo ""
        echo -n "  Choice: "; read -r c

        case "$c" in
            1) if [[ $LMS_SOX_AVAILABLE -eq 0 ]]; then
                   print_error "sox is not installed — choose [9] to install it first"
               else
                   _lms_resample_configure_rate "downsample"
               fi ;;
            2) if [[ $LMS_SOX_AVAILABLE -eq 0 ]]; then
                   print_error "sox is not installed — choose [9] to install it first"
               else
                   _lms_resample_configure_rate "force"
               fi ;;
            [Dd]) echo ""
               echo -n "  Disable resampling? (y/n) "; read -r r
               if [[ "$r" =~ ^[Yy]$ ]]; then
                   _lms_resample_disable
                   _lms_restart_after_change
               fi
               ;;
            [Mm]) _lms_resample_toggle_mode ;;
            3) _lms_resample_configure_quality ;;
            4) _lms_resample_toggle_dither ;;
            5) _lms_resample_toggle_normalize ;;
            6) echo ""
               if [[ -f "$LMS_RESAMPLE_SCRIPT" ]]; then
                   print_info "Contents of ${LMS_RESAMPLE_SCRIPT}:"
                   cat "$LMS_RESAMPLE_SCRIPT" | sed 's/^/    /'
               else
                   print_info "Script does not exist yet"
               fi
               ;;
            7) echo ""
               if [[ -f "$LMS_CONVERT_CONF" ]]; then
                   print_info "Contents of ${LMS_CONVERT_CONF}:"
                   cat -A "$LMS_CONVERT_CONF" | sed 's/^/    /'
               else
                   print_info "custom-convert.conf does not exist yet"
               fi
               ;;
            8) echo ""
               print_info "Play a file and watch the log (Ctrl+C to stop):"
               echo ""
               tail -f "${LMS_LOG_DIR}/server.log" 2>/dev/null \
                   | grep --line-buffered -iE "resamp|sox|192|384|768|convert|flac|transcode" \
                   || print_error "Log not found: ${LMS_LOG_DIR}/server.log"
               ;;
            9) echo ""; _lms_sox_install; _lms_sox_detect ;;
            0) return ;;
            *) print_error "Invalid choice" ;;
        esac

        echo ""
        echo -n "  Press Enter to continue..."; read
    done
}

_lms_resample_configure_rate() {
    local mode="${1:-downsample}"

    if [[ "$mode" == "force" ]]; then
        print_header "Set sample rate — Force mode"
        echo ""
        echo "  ALL files will be resampled to the chosen rate,"
        echo "  including files that are already at a lower rate."
    else
        print_header "Set sample rate — Downsample mode"
        echo ""
        echo "  Only files above the chosen rate will be resampled."
        echo "  Files at or below the chosen rate pass through unchanged."
    fi
    echo ""
    echo "  [1]  44100 Hz  (44.1 kHz — CD quality)"
    echo "  [2]  48000 Hz  (48 kHz   — standard DAC)"
    echo "  [3]  88200 Hz  (88.2 kHz — 2x CD)"
    echo "  [4]  96000 Hz  (96 kHz   — most common hi-res)"
    echo "  [5] 176400 Hz  (176.4 kHz)"
    echo "  [6] 192000 Hz  (192 kHz  — recommended maximum)"
    echo "  [7] 352800 Hz  (352.8 kHz)"
    echo "  [8] 384000 Hz  (384 kHz)"
    echo "  [9] Enter manually"
    echo "  [0] Back"
    echo ""
    echo -n "  Choice: "; read -r c

    local rate=""
    case "$c" in
        1) rate=44100  ;; 2) rate=48000  ;; 3) rate=88200  ;; 4) rate=96000  ;;
        5) rate=176400 ;; 6) rate=192000 ;; 7) rate=352800 ;; 8) rate=384000 ;;
        9) echo -n "  Enter sample rate (Hz, e.g. 192000): "; read -r rate
           [[ ! "$rate" =~ ^[0-9]+$ ]] && { print_error "Invalid value"; return; }
           ;;
        0) return ;; *) print_error "Invalid choice"; return ;;
    esac

    _lms_resample_detect
    local quality="v"
    local dither="${LMS_RESAMPLE_DITHER:-0}"
    local normalize="${LMS_RESAMPLE_NORMALIZE:-0}"
    case "${LMS_RESAMPLE_QUALITY}" in
        *VHQ*|*Very*) quality="vH" ;;
        *HQ*|*High*)  quality="h"  ;;
        *)             quality="v"  ;;
    esac

    print_info "Writing resampling script (mode: ${mode}, rate: ${rate} Hz)..."
    _lms_resample_write_script "$rate" "$quality" "$dither" "$normalize" "$mode"
    _lms_resample_write_conf
    print_success "Resampling set: ${mode} → ${rate} Hz"
    _lms_restart_after_change
}

_lms_resample_configure_quality() {
    _lms_resample_detect
    [[ $LMS_RESAMPLE_ENABLED -eq 0 ]] && { print_error "Resampling is disabled — enable it first via [1]"; return; }

    print_header "Set resampling quality"
    echo ""
    echo "  Higher quality = more CPU usage."
    echo "  On a Pi 4/5, 'High' or 'Very high' is fine."
    echo ""
    echo "  [1] Standard       (fastest)"
    echo "  [2] High (HQ)      (good balance — recommended)"
    echo "  [3] Very high (VHQ)(best quality)"
    echo "  [0] Back"
    echo ""
    echo -n "  Choice: "; read -r c

    local quality=""
    case "$c" in
        1) quality="v"  ;; 2) quality="h"  ;; 3) quality="vH" ;;
        0) return ;;       *) print_error "Invalid choice"; return ;;
    esac

    _lms_resample_write_script \
        "${LMS_RESAMPLE_RATE:-192000}" "$quality" \
        "${LMS_RESAMPLE_DITHER:-0}" "${LMS_RESAMPLE_NORMALIZE:-0}" \
        "${LMS_RESAMPLE_MODE:-downsample}"
    _lms_resample_write_conf
    print_success "Quality updated"
    _lms_restart_after_change
}

_lms_resample_toggle_mode() {
    _lms_resample_detect
    [[ $LMS_RESAMPLE_ENABLED -eq 0 ]] && { print_error "Resampling is disabled — enable it first via [1] or [2]"; return; }

    local new_mode="downsample"
    [[ "${LMS_RESAMPLE_MODE}" == "downsample" ]] && new_mode="force"

    local quality="v"
    case "${LMS_RESAMPLE_QUALITY}" in *VHQ*|*Very*) quality="vH" ;; *HQ*|*High*) quality="h" ;; esac

    print_info "Switching mode: ${LMS_RESAMPLE_MODE} → ${new_mode}"
    _lms_resample_write_script \
        "${LMS_RESAMPLE_RATE:-192000}" "$quality" \
        "${LMS_RESAMPLE_DITHER:-0}" "${LMS_RESAMPLE_NORMALIZE:-0}" "$new_mode"
    _lms_resample_write_conf
    print_success "Mode set to: ${new_mode}"
    _lms_restart_after_change
}

_lms_resample_toggle_dither() {
    _lms_resample_detect
    [[ $LMS_RESAMPLE_ENABLED -eq 0 ]] && { print_error "Resampling is disabled — enable it first via [1] or [2]"; return; }

    local new_dither=$(( 1 - ${LMS_RESAMPLE_DITHER:-0} ))
    local state_msg="disabled"; [[ $new_dither -eq 1 ]] && state_msg="enabled"

    local quality="v"
    case "${LMS_RESAMPLE_QUALITY}" in *VHQ*|*Very*) quality="vH" ;; *HQ*|*High*) quality="h" ;; esac

    _lms_resample_write_script \
        "${LMS_RESAMPLE_RATE:-192000}" "$quality" "$new_dither" \
        "${LMS_RESAMPLE_NORMALIZE:-0}" "${LMS_RESAMPLE_MODE:-downsample}"
    _lms_resample_write_conf
    print_success "Dither ${state_msg}"
    _lms_restart_after_change
}

_lms_resample_toggle_normalize() {
    _lms_resample_detect
    [[ $LMS_RESAMPLE_ENABLED -eq 0 ]] && { print_error "Resampling is disabled — enable it first via [1] or [2]"; return; }

    local new_norm=$(( 1 - ${LMS_RESAMPLE_NORMALIZE:-0} ))
    local state_msg="disabled"; [[ $new_norm -eq 1 ]] && state_msg="enabled"

    local quality="v"
    case "${LMS_RESAMPLE_QUALITY}" in *VHQ*|*Very*) quality="vH" ;; *HQ*|*High*) quality="h" ;; esac

    _lms_resample_write_script \
        "${LMS_RESAMPLE_RATE:-192000}" "$quality" "${LMS_RESAMPLE_DITHER:-0}" \
        "$new_norm" "${LMS_RESAMPLE_MODE:-downsample}"
    _lms_resample_write_conf
    print_success "Normalize ${state_msg}"
    _lms_restart_after_change
}

_lms_restart_after_change() {
    echo ""
    echo -n "  Restart LMS to apply changes? (y/n) "; read -r r
    if [[ "$r" =~ ^[Yy]$ ]]; then
        local svc; svc=$(_lms_active_service)
        _service_stop_safe "$svc" 20
        sleep 1
        _service_start_safe "$svc" 30
        sleep 3; _detect_lyrion
        [[ $LMS_RUNNING -eq 1 ]] \
            && print_success "LMS restarted — changes are active" \
            || print_warning "LMS not running after restart — check: journalctl -u ${svc} -n 30"
    fi
}

# =============================================================================
# STATUS
# =============================================================================

_lms_status() {
    print_header "Lyrion Music Server — Status"
    _detect_lyrion

    echo "Installation:"
    [[ $LMS_INSTALLED -eq 1 ]] && print_success "Installed: v${LMS_VERSION}" \
        || { print_info "Not installed — use [2]"; return; }

    echo ""
    echo "Service:"
    if [[ $LMS_RUNNING -eq 1 ]]; then
        local svc; svc=$(_lms_active_service)
        print_success "Running ✓ (${svc})"
        local pid; pid=$(systemctl show "${LMS_SERVICE}" -p MainPID --value 2>/dev/null || echo "0")
        if [[ "$pid" != "0" && -n "$pid" ]]; then
            local mem; mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f",$1/1024}')
            [[ -n "$mem" ]] && print_info "Memory: ~${mem} MB"
        fi
    else
        print_warning "Not running"
        print_info    "Start: sudo systemctl start ${LMS_SERVICE}"
    fi

    echo ""
    echo "Web UI:"
    local my_ip; my_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    curl -sf --max-time 3 "http://127.0.0.1:${LMS_PORT_WEB}" > /dev/null 2>&1 \
        && print_success "Reachable: http://${my_ip}:${LMS_PORT_WEB}" \
        || print_info    "Not yet reachable"

    echo ""
    echo "Performance:"
    if [[ -f "$LMS_TUNING_CONF" ]]; then
        print_success "Service tuning: applied"
        grep -E "^(CPUAffinity|Nice)" "$LMS_TUNING_CONF" 2>/dev/null | sed 's/^/    /'
    else
        print_warning "Service tuning: not applied (use [4])"
    fi
    [[ $LMS_DBHIGHMEM -eq 1 ]] \
        && print_success "Database boost: enabled (dbhighmem=1)" \
        || print_warning "Database boost: not set (use [4])"

    echo ""
    echo "CPU Affinity:"
    local aff_label; aff_label=$(_lms_cpu_affinity_label)
    print_info "Setting: ${LMS_CPU_AFFINITY}  (${aff_label})"
    [[ $LMS_COLOCATION -eq 1 ]] && print_info "CPU0-only mode active — cpu1-3 free for audio"

    echo ""
    echo "Update check:"
    _detect_lms_update_available
    [[ -n "$LMS_UPDATE_AVAILABLE" ]] \
        && print_warning "Update available: v${LMS_VERSION} → v${LMS_UPDATE_AVAILABLE}" \
        || print_success "Up-to-date: v${LMS_VERSION}"

    echo ""
    echo "Audio resampling:"
    _lms_resample_status_line
    _lms_sox_detect
    [[ $LMS_SOX_AVAILABLE -eq 1 ]] \
        && print_success "sox: ${LMS_SOX_FOUND}" \
        || print_warning "sox: not installed (use [9] to install)"

    echo ""
    echo "Scheduled tasks:"
    [[ -f "$LMS_SCAN_CRON"    ]] && print_success "Library scan: scheduled"    || print_info "Library scan: not scheduled"
    [[ -f "$LMS_RESTART_CRON" ]] && print_success "Nightly restart: scheduled" || print_info "Nightly restart: not scheduled"

    echo ""
    echo "Data directories:"
    for d in "$LMS_DATA_DIR" "$LMS_LOG_DIR"; do
        [[ -d "$d" ]] \
            && print_success "${d} ($(du -sh "$d" 2>/dev/null | cut -f1))" \
            || print_info    "${d} (not present)"
    done

    echo ""
    echo "System:"
    print_info "Fedora $(rpm -E '%{fedora}' 2>/dev/null || cat /etc/fedora-release 2>/dev/null | grep -oP '\d+' | head -1 || echo '?')"
    print_info "Kernel : $(uname -r)"
    print_info "Arch   : $(uname -m)"
}

# =============================================================================
# REMOVE
# =============================================================================

_lms_uninstall() {
    print_header "Remove Lyrion Music Server"

    if [[ $LMS_INSTALLED -eq 0 ]]; then
        print_info "LMS not installed"
        echo -n "  Clean up leftover files anyway? (y/n) "; read -r r; [[ ! "$r" =~ ^[Yy]$ ]] && return
    fi

    print_warning "This removes Lyrion Music Server v${LMS_VERSION}"
    print_warning "Your music files will NOT be removed."
    echo ""
    echo "  [1] Keep data     (database, artwork, preferences)"
    echo "  [2] Full removal  (all LMS data — irreversible)"
    echo -n "  Choice [1-2]: "; read -r dc
    [[ "$dc" != "1" && "$dc" != "2" ]] && { print_error "Invalid choice"; return; }
    echo ""
    echo -n "  Type 'yes' to confirm: "; read -r r
    [[ "$r" != "yes" ]] && { print_info "Cancelled"; return; }

    echo ""
    echo "── Step 1: Stop service ──────────────────────────────────"
    local svc; svc=$(_lms_active_service)
    _service_stop_safe "$svc" 20
    systemctl disable "$svc" 2>/dev/null || true
    print_success "Service stopped and disabled"

    echo ""
    echo "── Step 2: Remove scheduled tasks ───────────────────────"
    for f in "$LMS_SCAN_CRON" "${LMS_SCAN_CRON}.paused" \
              "$LMS_RESTART_CRON" "${LMS_RESTART_CRON}.paused"; do
        [[ -f "$f" ]] && rm "$f" && print_success "Removed: $(basename "$f")"
    done

    echo ""
    echo "── Step 3: Remove service override ──────────────────────"
    [[ -f "$LMS_TUNING_CONF" ]] && rm -f "$LMS_TUNING_CONF" && print_success "Tuning override removed"
    rmdir "$LMS_OVERRIDE_DIR" 2>/dev/null || true
    systemctl daemon-reload

    echo ""
    echo "── Step 4: Remove RPM package ───────────────────────────"
    if [[ "$dc" == "2" ]]; then
        dnf remove -y "${LMS_SERVICE}" "${LMS_SERVICE_LEGACY}" 2>/dev/null || true
        rm -rf "$LMS_DATA_DIR" "$LMS_LOG_DIR" 2>/dev/null || true
        print_success "LMS fully removed (including data)"
    else
        dnf remove -y "${LMS_SERVICE}" "${LMS_SERVICE_LEGACY}" 2>/dev/null || true
        print_success "LMS removed (data preserved in ${LMS_DATA_DIR})"
    fi

    _detect_lyrion
    print_success "Removal complete"
}

# =============================================================================
# MAIN MENU
# =============================================================================

_lms_main_menu() {
    while true; do
        print_header "Lyrion Music Server — Fedora / Raspberry Pi"
        _detect_lyrion
        _detect_lms_update_available 2>/dev/null || true

        if [[ $LMS_INSTALLED -eq 1 ]]; then
            [[ $LMS_RUNNING -eq 1 ]] \
                && echo -e "  Status : ${GREEN}v${LMS_VERSION} — Running ✓${NC}" \
                || echo -e "  Status : ${YELLOW}v${LMS_VERSION} — Stopped${NC}"
            local lms_auto="disabled"
            systemctl is-enabled "$LMS_SERVICE" &>/dev/null && lms_auto="enabled"
            [[ "$lms_auto" == "enabled" ]] \
                && echo -e "  Boot   : ${GREEN}autostart enabled${NC}" \
                || echo -e "  Boot   : ${YELLOW}autostart DISABLED${NC}"
            local aff_label; aff_label=$(_lms_cpu_affinity_label)
            echo -e "  CPU    : ${CYAN}${LMS_CPU_AFFINITY}  (${aff_label})${NC}"
            [[ -n "$LMS_UPDATE_AVAILABLE" ]] && echo -e "  ${YELLOW}⚠  Update available: v${LMS_UPDATE_AVAILABLE}${NC}"
        else
            echo -e "  Status : ${BLUE}Not installed${NC}"
        fi
        echo ""

        echo "  [1] Status & details"
        echo "  [2] Install LMS"
        echo "  [3] Update LMS"
        echo "  [4] Performance tuning  (dbhighmem, service priority, CPU affinity)"
        echo "  [5] Scheduled tasks      (scan + nightly restart)"
        echo "  [6] Start / Stop / Enable / Disable"
        echo "  [7] Open firewall ports  (firewalld)"
        echo "  [8] Remove LMS"
        echo "  [9] Audio resampling"
        echo "  [0] Quit"
        echo ""
        echo -n "  Choice: "; read -r c

        case "$c" in
            1) echo ""; _lms_status ;;
            2) echo ""; create_backup; _lms_install ;;
            3) echo ""; create_backup; _lms_update ;;
            4) echo ""; create_backup; _lms_performance_menu ;;
            5) _lms_schedule_menu ;;
            6) echo ""; _lms_service_control ;;
            7) echo ""; _lms_open_ports ;;
            8) echo ""; create_backup; _lms_uninstall ;;
            9) echo ""; _lms_resample_menu ;;
            0) echo ""; exit 0 ;;
            *) print_error "Invalid choice" ;;
        esac

        echo ""
        echo -n "  Press Enter to continue..."; read
    done
}

# =============================================================================
# ENTRY POINT
# =============================================================================

_require_root
_lms_main_menu
