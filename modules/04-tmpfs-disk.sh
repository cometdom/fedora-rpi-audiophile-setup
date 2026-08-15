#!/bin/bash
#
# 04-tmpfs-disk — minimise disk activity during playback.
#
# Step 1 (mandatory): make journald volatile by dropping a config snippet
# under /etc/systemd/journald.conf.d/. Logs then live in /run/log/journal,
# which is already a tmpfs, and are cleared on reboot.
#
# Step 2 (optional, interactive, default Y): mount /var/log and /var/tmp as
# tmpfs via /etc/fstab so the few non-journal log writers (dnf, audit, etc.)
# and short-lived temp files don't hit the disk during a session.
#
# The /var/tmp tmpfs is deliberately small (256M) — but dracut stages the
# initramfs it's about to build (kernel modules, firmware, systemd, and more
# for an RT kernel) in a working directory under /var/tmp by default before
# compressing the result into /boot. That build tree is comfortably bigger
# than 256M, so shrinking /var/tmp this way sets up every FUTURE kernel
# update to fail with a cryptic "Write error: cannot write block: No space
# left on device" from dracut — even though /boot itself has plenty of room.
# (13-ram-mode.sh already preflights /boot space for its own dracut calls;
# this is a different failure mode, hit on a stock `dnf update` kernel
# install, not through this repo's own dracut invocations.) Fixed by pointing
# dracut's tmpdir at /tmp instead, which this repo does not resize and which
# defaults to a much larger tmpfs — confirmed to fix the failure in practice.
#
# Idempotent: each write checks whether the desired state is already present.
#

set -euo pipefail

readonly _TMPFS_GEN_TAG="# audiophile-setup"
readonly _JOURNALD_DROPIN_DIR="/etc/systemd/journald.conf.d"
readonly _JOURNALD_DROPIN="${_JOURNALD_DROPIN_DIR}/99-audiophile-volatile.conf"
readonly _FSTAB="/etc/fstab"
readonly _TMPFS_VAR_LOG_SIZE="128M"
readonly _TMPFS_VAR_TMP_SIZE="256M"
readonly _DRACUT_TMPDIR_CONF="/etc/dracut.conf.d/50-audiophile-tmpdir.conf"

log_step "Minimise disk activity (journald volatile + optional tmpfs)"

# --- Step 1: journald volatile -------------------------------------------

_tmpfs_journald_already_volatile() {
    [[ -f "$_JOURNALD_DROPIN" ]] && grep -q '^Storage=volatile' "$_JOURNALD_DROPIN" 2>/dev/null
}

_tmpfs_set_journald_volatile() {
    if _tmpfs_journald_already_volatile; then
        log_info "journald already configured volatile via ${_JOURNALD_DROPIN} — skipping."
        return 0
    fi
    log_info "Setting journald Storage=volatile via ${_JOURNALD_DROPIN}"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would write ${_JOURNALD_DROPIN} and restart systemd-journald"
        return 0
    fi
    mkdir -p "$_JOURNALD_DROPIN_DIR"
    cat > "$_JOURNALD_DROPIN" <<EOF
${_TMPFS_GEN_TAG}
[Journal]
Storage=volatile
EOF
    run_cmd systemctl restart systemd-journald
}

# --- Step 2: tmpfs for /var/log and /var/tmp -----------------------------

_tmpfs_fstab_has_entry() {
    awk -v mp="$1" '$1=="tmpfs" && $2==mp {found=1} END {exit !found}' "$_FSTAB"
}

_tmpfs_add_fstab_entry() {
    local mountpoint="$1" size="$2" extra_opts="${3:-}"
    if _tmpfs_fstab_has_entry "$mountpoint"; then
        log_info "fstab already has a tmpfs entry for ${mountpoint} — skipping."
        return 0
    fi
    local opts="defaults,size=${size},nodev,nosuid"
    [[ -n "$extra_opts" ]] && opts="${opts},${extra_opts}"
    local line="tmpfs ${mountpoint} tmpfs ${opts} 0 0"

    log_info "Adding tmpfs entry for ${mountpoint} (size=${size})"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would append to ${_FSTAB}: ${line}"
        return 0
    fi
    {
        echo "${_TMPFS_GEN_TAG}"
        echo "${line}"
    } >> "$_FSTAB"
}

_tmpfs_dracut_tmpdir_already_set() {
    [[ -f "$_DRACUT_TMPDIR_CONF" ]] && grep -q '^tmpdir=' "$_DRACUT_TMPDIR_CONF" 2>/dev/null
}

_tmpfs_set_dracut_tmpdir() {
    if _tmpfs_dracut_tmpdir_already_set; then
        log_info "dracut tmpdir already redirected via ${_DRACUT_TMPDIR_CONF} — skipping."
        return 0
    fi
    log_info "Pointing dracut's build tmpdir at /tmp (see comment above /var/tmp's" \
             "tmpfs size) via ${_DRACUT_TMPDIR_CONF}"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would write ${_DRACUT_TMPDIR_CONF}"
        return 0
    fi
    cat > "$_DRACUT_TMPDIR_CONF" <<EOF
${_TMPFS_GEN_TAG}
tmpdir="/tmp"
EOF
}

# --- Dispatch ------------------------------------------------------------

_tmpfs_set_journald_volatile

if ask_yes_no "Mount /var/log and /var/tmp as tmpfs (eliminates disk writes during playback — takes effect on next reboot)?" Y TMPFS_VARLOG; then
    # /var/log: 0755 root:root is fine — services running as root write here.
    _tmpfs_add_fstab_entry /var/log "$_TMPFS_VAR_LOG_SIZE"
    # /var/tmp MUST keep mode 1777 (sticky world-writable) so non-root users
    # and services can write to it as they do on the original filesystem.
    _tmpfs_add_fstab_entry /var/tmp "$_TMPFS_VAR_TMP_SIZE" "mode=1777"
    # Keep dracut off the now-tiny /var/tmp — see the comment above
    # _TMPFS_VAR_TMP_SIZE for why this pairs with the entry just above.
    _tmpfs_set_dracut_tmpdir
    log_info "tmpfs entries written. They mount on next reboot (or run 'mount -a' to mount now)."
else
    log_info "Skipping tmpfs mounts. /var/log and /var/tmp remain on disk."
fi
