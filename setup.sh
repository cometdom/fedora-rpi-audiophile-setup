#!/bin/bash
#
# fedora-audiophile-setup — Interactive wizard that turns a clean Fedora 43
# minimal install into a tuned audiophile playback host.
#
# See README.md and docs/en/ for details. Run with --help for usage.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

# --- CLI parsing ------------------------------------------------------------

DRY_RUN=0
ONLY_MODULE=""
SHOW_HELP=0

UNATTENDED=0
ANSWERS_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=1 ;;
        --only)       ONLY_MODULE="${2:-}"; shift ;;
        --unattended) UNATTENDED=1 ;;
        --answers)    ANSWERS_FILE="${2:-}"; shift ;;
        -h|--help)    SHOW_HELP=1 ;;
        *)            log_error "Unknown argument: $1"; SHOW_HELP=1 ;;
    esac
    shift
done

export DRY_RUN
export UNATTENDED

# The answers file is a plain env file of UA_<KEY>=value overrides (see
# extras/answers-example.env). Sourced before any module runs so every
# prompt can resolve against it; only meaningful with --unattended, but
# harmless without.
if [[ -n "$ANSWERS_FILE" ]]; then
    if [[ ! -r "$ANSWERS_FILE" ]]; then
        log_error "Answers file not readable: $ANSWERS_FILE"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$ANSWERS_FILE"
fi

if [[ "$SHOW_HELP" -eq 1 ]]; then
    cat <<EOF
fedora-audiophile-setup — interactive audiophile tuning wizard for Fedora 43.

Usage:
  sudo ./setup.sh                       Show an interactive numbered menu
                                        (full install or any single module).
  sudo ./setup.sh --dry-run             Combine with the menu or --only to
                                        preview every action without applying.
  sudo ./setup.sh --only <module>       Run a single module directly, skipping
                                        the menu (power-user shortcut).
  sudo ./setup.sh --unattended          Run ALL modules without a TTY: every
                                        prompt takes its default, overridable
                                        via --answers (kickstart %post, CI).
  sudo ./setup.sh --answers <file>      Env file of UA_<KEY>=value overrides
                                        for --unattended prompts. See
                                        extras/answers-example.env.
  sudo ./setup.sh --help                Show this help.

Available modules (in execution order):
EOF
    list_modules | sed 's/^/  /'
    echo
    echo "Documentation: docs/en/README.md"
    exit 0
fi

# --- Preflight: must be root -----------------------------------------------

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)."
    exit 1
fi

# --- Main dispatch ----------------------------------------------------------

init_log

# Warn before anything runs: in RAM mode every change is discarded on reboot,
# so the user must know now rather than after a whole install evaporates.
warn_if_ram_mode

if [[ "$DRY_RUN" -eq 1 ]]; then
    log_warn "Running in --dry-run mode. No changes will be applied."
fi

if [[ -n "$ONLY_MODULE" ]]; then
    run_single_module "$ONLY_MODULE"
else
    show_menu_and_dispatch
fi

log_info "Done. See ${LOG_FILE} for the full log."
