#!/bin/bash
#
# cpu-states-tune.sh — re-tune CPU_MAX_PCT, CPU_FREQ_OVERRIDES and
# CPU_POLL_CORES in /etc/default/audiophile-cpu-states without re-running
# the wizard.
#
# Same three knobs that module 06 (06-cpu-states.sh) writes. Use this
# helper for fast experimentation cycles (typical audiophile workflow:
# tweak frequency on the audio cores → restart service → listen → tweak
# again). Each prompt shows the current value and accepts:
#
#   <Enter>     keep the current value
#   <new value> change to the new value (validated)
#   -           clear (unset the knob)
#
# After collecting all three, the script shows a summary, asks for
# confirmation, writes the conf file atomically (preserving comments
# and unrelated lines), and restarts audiophile-cpu-states.service.
#
# Usage:
#   sudo ./scripts/cpu-states-tune.sh           interactive tuning
#   sudo ./scripts/cpu-states-tune.sh --show    show current values, no prompts
#   sudo ./scripts/cpu-states-tune.sh --help    usage
#

set -euo pipefail

readonly CONF="/etc/default/audiophile-cpu-states"
readonly SERVICE="audiophile-cpu-states.service"

_info() { echo "[cpu-states-tune] $*"; }
_warn() { echo "[cpu-states-tune] WARNING: $*" >&2; }
_err()  { echo "[cpu-states-tune] ERROR: $*" >&2; }

_require_root() {
    [[ $EUID -eq 0 ]] || { _err "must run as root (use sudo)."; exit 1; }
}

_require_conf() {
    if [[ ! -f "$CONF" ]]; then
        _err "${CONF} not found."
        _err "Run 'sudo ./setup.sh --only cpu-states' first to install the wizard's CPU tuning service."
        exit 1
    fi
}

# Read a key's current value from CONF. `|| true` to absorb grep's no-match
# exit 1 under pipefail.
_read_current() {
    local key="$1"
    grep -E "^${key}=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' "' || true
}

# Write a key=value to CONF. If the key already exists, replace its line
# in place; otherwise append. Comments and unrelated lines are preserved.
# Empty value is written as KEY= (the service treats KEY= and KEY unset
# identically, so this is a clear).
_write_key() {
    local key="$1" val="$2"
    local tmp
    tmp=$(mktemp "${CONF}.XXXXXX")
    if grep -qE "^${key}=" "$CONF"; then
        # Use awk so the value can safely contain characters that confuse sed.
        awk -v k="$key" -v v="$val" '
            $0 ~ "^"k"=" { print k"="v; next }
            { print }
        ' "$CONF" > "$tmp"
    else
        cat "$CONF" > "$tmp"
        echo "${key}=${val}" >> "$tmp"
    fi
    # Preserve mode + owner of the original file.
    chmod --reference="$CONF" "$tmp"
    chown --reference="$CONF" "$tmp" 2>/dev/null || true
    mv "$tmp" "$CONF"
}

# Validate a single value against the per-key regex. Returns 0 if valid,
# 1 if not. Empty string is always valid (= clear).
_validate() {
    local key="$1" val="$2"
    [[ -z "$val" ]] && return 0
    case "$key" in
        CPU_MAX_PCT)
            [[ "$val" =~ ^([1-9][0-9]?|100)$ ]]
            ;;
        CPU_FREQ_OVERRIDES)
            [[ "$val" =~ ^[0-9]+:[0-9]+(,[0-9]+:[0-9]+)*$ ]]
            ;;
        CPU_POLL_CORES)
            [[ "$val" =~ ^([0-9]+(-[0-9]+)?)(,[0-9]+(-[0-9]+)?)*$ ]]
            ;;
        *) return 1 ;;
    esac
}

# Prompt for one key. <Enter> keeps the current value; "-" clears it; any
# other input is validated and used as the new value. Re-prompts on
# invalid input (up to 3 tries, then abort).
_prompt() {
    local key="$1" hint="$2" current="$3"
    local shown="${current:-<unset>}"
    local attempts=0
    while (( attempts++ < 3 )); do
        local input
        read -r -p "${key} (current=${shown}) ${hint}: " input
        case "$input" in
            "")  echo "$current"; return 0 ;;       # Enter → keep
            "-") echo "";         return 0 ;;       # "-"   → clear
            *)
                if _validate "$key" "$input"; then
                    echo "$input"; return 0
                fi
                _warn "invalid value for ${key}; format hint = ${hint}"
                ;;
        esac
    done
    _err "too many invalid attempts; aborting."
    exit 1
}

cmd_show() {
    _require_conf
    echo "Current config in ${CONF}:"
    for key in CPU_MAX_PCT CPU_FREQ_OVERRIDES CPU_POLL_CORES; do
        local v
        v=$(_read_current "$key")
        printf "  %-20s = %s\n" "$key" "${v:-<unset>}"
    done
}

cmd_tune() {
    _require_root
    _require_conf

    cmd_show
    echo

    local cur_pct cur_freq cur_poll
    cur_pct=$(_read_current CPU_MAX_PCT)
    cur_freq=$(_read_current CPU_FREQ_OVERRIDES)
    cur_poll=$(_read_current CPU_POLL_CORES)

    local new_pct new_freq new_poll
    new_pct=$(_prompt  CPU_MAX_PCT        "[1-100 / - to clear]"       "$cur_pct")
    new_freq=$(_prompt CPU_FREQ_OVERRIDES "[core:freq,… / - to clear]" "$cur_freq")
    new_poll=$(_prompt CPU_POLL_CORES     "[2,3,4,5 or 2-5 / - to clear]" "$cur_poll")

    echo
    echo "Planned config:"
    printf "  %-20s = %s\n" CPU_MAX_PCT         "${new_pct:-<unset>}"
    printf "  %-20s = %s\n" CPU_FREQ_OVERRIDES  "${new_freq:-<unset>}"
    printf "  %-20s = %s\n" CPU_POLL_CORES      "${new_poll:-<unset>}"
    echo

    if [[ "$new_pct" == "$cur_pct" && "$new_freq" == "$cur_freq" && "$new_poll" == "$cur_poll" ]]; then
        _info "no change — exiting without restarting the service."
        exit 0
    fi

    local confirm
    read -r -p "Apply and restart ${SERVICE}? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { _info "aborted."; exit 0; }

    _write_key CPU_MAX_PCT        "$new_pct"
    _write_key CPU_FREQ_OVERRIDES "$new_freq"
    _write_key CPU_POLL_CORES     "$new_poll"
    _info "${CONF} updated."

    if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null || systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        _info "restarting ${SERVICE}…"
        systemctl restart "$SERVICE"
        _info "done. Verify with: systemctl status ${SERVICE}"
    else
        _warn "${SERVICE} is not enabled — values written to ${CONF} but no restart performed."
        _warn "Enable + start manually with: sudo systemctl enable --now ${SERVICE}"
    fi
}

main() {
    case "${1:-}" in
        ""|tune) cmd_tune ;;
        --show|show) cmd_show ;;
        --help|-h|help)
            cat <<EOF
Usage: sudo $0 [--show]

  (no arg)   Interactive tuning. For each of CPU_MAX_PCT / CPU_FREQ_OVERRIDES /
             CPU_POLL_CORES, shows current value and prompts:
                 <Enter>      keep current
                 <new value>  change to new (validated)
                 -            clear (unset)
             Confirms before writing ${CONF} and restarting ${SERVICE}.

  --show     Print current values from ${CONF}. No prompts, no changes.

Knobs:
  CPU_MAX_PCT          Integer 1-100. Global cap on max CPU frequency
                       (% of hardware max).
  CPU_FREQ_OVERRIDES   Format 'core:freq_khz,core:freq_khz,…'. Pins both
                       scaling_min_freq and scaling_max_freq per listed core.
                       Runs after CPU_MAX_PCT so overrides win on listed cores.
  CPU_POLL_CORES       Format '2,3,4,5' or '2-5' or '2,4-6'. Disables all idle
                       states (incl. C1) on listed cores → per-core idle=poll.

See module 06 (modules/06-cpu-states.sh) for the full semantics.
EOF
            ;;
        *) _err "unknown command: $1"; exit 2 ;;
    esac
}

main "$@"
