#!/bin/bash

# Stop on failure; catch unset vars and pipeline errors
set -euo pipefail

DATE="$(date +%Y-%m-%d)"
PG_DATA="/var/lib/postgres/data"
TMP_DIR="/var/lib/postgres/tmp-$DATE"
OLD_DATA_DIR_PREFIX="/var/lib/postgres/old_data"

# Minimum free space on the PG_DATA filesystem (MB). Upgrade may need ~2x data dir; bump if needed.
MIN_FREE_MB="${MIN_FREE_MB:-1024}"

TOTAL_STEPS=8

# ANSI colors: off when NO_COLOR is set or stderr is not a TTY (https://no-color.org)
if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then
    _R=$'\033[0m'
    _B=$'\033[1m'
    _D=$'\033[2m'
    _RED=$'\033[31m'
    _GRN=$'\033[32m'
    _YLW=$'\033[33m'
    _BLU=$'\033[34m'
    _CYN=$'\033[36m'
else
    _R= _B= _D= _RED= _GRN= _YLW= _BLU= _CYN=
fi

# Step banner underline:60 ASCII hyphens (no seq/coreutils loop dependency)
readonly _STEP_RULE='------------------------------------------------------------'

NEEDS_ROLLBACK=0

say() {
    printf '%b\n' "$*" >&2
}

step_banner() {
    local num=$1 title=$2
    say ""
    say "${_CYN}${_B}==>${_R} ${_B}Step ${num}/${TOTAL_STEPS}:${_R} ${_CYN}${title}${_R}"
    say "${_D}${_STEP_RULE}${_R}"
}

msg_ok() {
    say "${_GRN}${_B}OK${_R} ${_GRN}$*${_R}"
}

msg_info() {
    say "${_BLU}·${_R} $*"
}

msg_warn() {
    say "${_YLW}${_B}Warning:${_R} ${_YLW}$*${_R}"
}

print_overview() {
    say "${_B}PostgreSQL major upgrade${_R} ${_D}(${DATE})${_R}"
    say ""
    say "${_B}Planned steps:${_R}"
    say "  ${_D}1.${_R} Pre-flight checks (paths, binaries, disk, conflicts)"
    say "  ${_D}2.${_R} Stop PostgreSQL and confirm cluster is shut down"
    say "  ${_D}3.${_R} Move old data directory aside and create new directories"
    say "  ${_D}4.${_R} initdb — initialize empty new cluster"
    say "  ${_D}5.${_R} pg_upgrade --check — validate upgrade without applying"
    say "  ${_D}6.${_R} pg_upgrade — migrate data to new cluster"
    say "  ${_D}7.${_R} Copy postgresql.conf and pg_hba.conf"
    say "  ${_D}8.${_R} Start postgresql.service and verify it is active"
    say ""
}

die() {
    say "${_RED}${_B}Error:${_R} ${_RED}$*${_R}"
    exit 1
}

rollback() {
    trap - ERR
    set +e
    if [ "$NEEDS_ROLLBACK" -ne 1 ]; then
        set -e
        trap 'on_err' ERR
        return 0
    fi
    msg_warn "Rolling back: restoring original data directory at ${PG_DATA}..."
    systemctl stop postgresql 2>/dev/null || true
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    if [ -n "${PG_DATA:-}" ] && [ -e "$PG_DATA" ]; then
        rm -rf "$PG_DATA"
    fi
    if [ -n "${OLD_DATA_DIR:-}" ] && [ -d "$OLD_DATA_DIR" ]; then
        mv "$OLD_DATA_DIR" "$PG_DATA"
    else
        say "${_RED}${_B}Error:${_R} ${_RED}Cannot rollback: $OLD_DATA_DIR is missing.${_R}"
        set -e
        trap 'on_err' ERR
        return 1
    fi
    NEEDS_ROLLBACK=0
    msg_ok "Rollback finished. Original cluster is back at $PG_DATA"
    msg_info "When ready: ${_B}systemctl start postgresql${_R}"
    set -e
    trap 'on_err' ERR
}

on_err() {
    local exit_code=$?
    say "${_RED}${_B}Error:${_R} ${_RED}command failed at line ${BASH_LINENO[0]} (exit ${exit_code})${_R}"
    rollback || true
    exit "$exit_code"
}

trap 'on_err' ERR

preflight_before_stop() {
    [ "${EUID:-0}" -eq 0 ] || die "This script must be run as root."

    [ -d "$PG_DATA" ] || die "PG_DATA is not a directory: $PG_DATA"
    [ -f "$PG_DATA/PG_VERSION" ] || die "Missing $PG_DATA/PG_VERSION (not a PostgreSQL data directory?)"
    [ -d "$PG_DATA/base" ] || die "Missing $PG_DATA/base — data directory looks incomplete."
    [ -d "$PG_DATA/global" ] || die "Missing $PG_DATA/global — data directory looks incomplete."

    PG_VERSION="$(tr -d '[:space:]' <"$PG_DATA/PG_VERSION")"
    [[ "$PG_VERSION" =~ ^[0-9]+$ ]] || die "Invalid PG_VERSION value: $PG_VERSION"

    OLD_DATA_DIR="${OLD_DATA_DIR_PREFIX}-${PG_VERSION}"
    OLD_BIN="/opt/pgsql-${PG_VERSION}/bin"

    [ ! -d "$OLD_DATA_DIR" ] || die "Old data directory already exists: $OLD_DATA_DIR (remove or rename it first)."
    [ ! -d "$TMP_DIR" ] || die "Tmp data directory already exists: $TMP_DIR (remove or rename it first)."

    getent passwd postgres >/dev/null || die "User 'postgres' does not exist."
    getent group postgres >/dev/null || die "Group 'postgres' does not exist."

    systemctl cat postgresql.service >/dev/null 2>&1 || die "Unit postgresql.service not found (systemctl cat postgresql.service failed)."

    command -v pg_controldata >/dev/null || die "pg_controldata not in PATH (install PostgreSQL client utilities)."

    [ -d "$OLD_BIN" ] || die "Old cluster bin directory missing: $OLD_BIN"
    [ -x "$OLD_BIN/pg_upgrade" ] || die "Not executable: $OLD_BIN/pg_upgrade"
    [ -x "$OLD_BIN/postgres" ] || die "Not executable: $OLD_BIN/postgres"

    local old_major
    old_major="$("$OLD_BIN/postgres" --version 2>/dev/null | sed -n 's/^.*PostgreSQL \([0-9][0-9]*\)\..*$/\1/p')"
    [ -n "$old_major" ] || die "Could not parse major version from $OLD_BIN/postgres --version"
    [ "$old_major" = "$PG_VERSION" ] || die "Mismatch: $PG_DATA/PG_VERSION is $PG_VERSION but $OLD_BIN/postgres reports major $old_major"

    [ -x /usr/bin/pg_upgrade ] || die "Not executable: /usr/bin/pg_upgrade (install new PostgreSQL first)"
    [ -x /usr/bin/initdb ] || die "Not executable: /usr/bin/initdb"
    [ -x /usr/bin/postgres ] || die "Not executable: /usr/bin/postgres"

    local avail_kb required_kb data_kb min_kb
    data_kb="$(du -sk "$PG_DATA" | cut -f1)"
    required_kb=$((data_kb * 2))
    min_kb=$((MIN_FREE_MB * 1024))
    if [ "$required_kb" -lt "$min_kb" ]; then
        required_kb=$min_kb
    fi
    avail_kb="$(df -Pk "$PG_DATA" | awk 'NR==2 {print $4}')"
    [ -n "$avail_kb" ] && [ "$avail_kb" -ge "$required_kb" ] \
        || die "Insufficient disk space on filesystem containing $PG_DATA (avail ${avail_kb:-?} KiB, need ~${required_kb} KiB). Set MIN_FREE_MB or free space."
}

require_cluster_shutdown() {
    local state
    state="$(pg_controldata "$PG_DATA" 2>/dev/null | sed -n 's/^Database cluster state:[[:space:]]*//p' | head -1 | tr -d '\r')"
    [ -n "$state" ] || die "pg_controldata failed for $PG_DATA — is this a valid PostgreSQL data directory?"
    [ "$state" = "shut down" ] || die "Cluster is not shut down (pg_controldata: '$state'). Stop PostgreSQL and ensure no postgres processes remain."
}

print_overview

step_banner 1 "Pre-flight checks"
preflight_before_stop
msg_ok "Pre-flight checks passed."

step_banner 2 "Stop PostgreSQL and confirm cluster is shut down"
msg_info "Current cluster version (from data directory): ${_B}${PG_VERSION}${_R}"
# Stopping the database if it's running
if systemctl is-active --quiet postgresql; then
    msg_info "Stopping ${_B}postgresql.service${_R}..."
    systemctl stop postgresql
    # Wait to ensure PostgreSQL has fully stopped
    sleep 5
else
    msg_info "Service ${_B}postgresql${_R} is already inactive."
fi

# Double-check PostgreSQL is not running
if pgrep -x "postgres" > /dev/null; then
    die "PostgreSQL is still running. Please stop it manually."
fi

require_cluster_shutdown
msg_ok "Cluster reports shut down; no postgres processes found."

step_banner 3 "Move old data directory aside and create new directories"
msg_info "Moving ${_B}${PG_DATA}${_R} → ${_B}${OLD_DATA_DIR}${_R}"
# Move the old data directory
mv "$PG_DATA" "$OLD_DATA_DIR"
NEEDS_ROLLBACK=1

# Create the new data directory
mkdir "$PG_DATA" "$TMP_DIR"

# Set ownership
chown postgres:postgres "$PG_DATA" "$TMP_DIR"
msg_ok "Directories ready: ${_B}${PG_DATA}${_R}, ${_B}${TMP_DIR}${_R}"

step_banner 4 "initdb — new empty cluster"
su -s /bin/bash -c "cd $(printf '%q' "$TMP_DIR") && initdb -D $(printf '%q' "$PG_DATA") --locale=en_US.UTF-8 --encoding=UTF8" - postgres
msg_ok "initdb completed."

step_banner 5 "pg_upgrade --check"
su -s /bin/bash -c "pg_upgrade --check -b $(printf '%q' "$OLD_BIN") -B /usr/bin -d $(printf '%q' "$OLD_DATA_DIR") -D $(printf '%q' "$PG_DATA")" - postgres
msg_ok "pg_upgrade --check passed."

step_banner 6 "pg_upgrade — migrate data"
su -s /bin/bash -c "pg_upgrade -b $(printf '%q' "$OLD_BIN") -B /usr/bin -d $(printf '%q' "$OLD_DATA_DIR") -D $(printf '%q' "$PG_DATA")" - postgres
msg_ok "pg_upgrade completed."

step_banner 7 "Copy configuration"
cp "$OLD_DATA_DIR/postgresql.conf" "$PG_DATA"
cp "$OLD_DATA_DIR/pg_hba.conf" "$PG_DATA"
msg_ok "Copied postgresql.conf and pg_hba.conf."

step_banner 8 "Start postgresql.service and verify"
msg_info "Starting ${_B}postgresql.service${_R}..."
systemctl start postgresql

# Verify database started successfully
if ! systemctl is-active --quiet postgresql; then
    say "${_RED}${_B}Error:${_R} ${_RED}Failed to start PostgreSQL after upgrade.${_R}"
    msg_info "Check logs: ${_B}journalctl -u postgresql${_R}"
    rollback || true
    trap - ERR
    exit 1
fi

NEEDS_ROLLBACK=0
trap - ERR

say ""
msg_ok "${_B}Upgrade completed successfully.${_R}"
msg_info "Old data directory preserved at: ${_B}${OLD_DATA_DIR}${_R}"

#
# Post processing, some actions might be necessary on some of the databases:
#
# REINDEX DATABASE postgres;
#
# ALTER DATABASE postgres REFRESH COLLATION VERSION;
#
