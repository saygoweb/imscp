# shellcheck shell=bash
# Shared helpers for the aws1 migration scripts. Source, do not execute.

set -euo pipefail

# --- identity of the migration, in one place -------------------------------
OLD_ETC="${OLD_ETC:-/home/cambell/etc}"          # aws1's /etc, copied here
DATA_UUID="${DATA_UUID:-958199d3-ad2d-4fa8-afae-b399286315de}"
DATA_MNT="${DATA_MNT:-/var/www/virtual}"
MAIL_LINK="${MAIL_LINK:-/var/mail/virtual}"
MAIL_TARGET="${MAIL_TARGET:-/var/www/virtual/_mail/virtual}"
WORK="${WORK:-/root/mig}"
DUMP_DIR="${DUMP_DIR:-$WORK/db}"

# uid/gid ranges to reproduce from aws1
UID_VMAIL=999
ID_MIN=1001      # group imscp
ID_MAX=1196      # last vu group/user

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'

log()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$RST"; }

ok()   { printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
bad()  { printf '  %s[XX]%s %s\n' "$RED" "$RST" "$*"; FAILED=$((${FAILED:-0}+1)); }

need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

need_old_etc() {
    [ -d "$OLD_ETC/imscp" ] || die "OLD_ETC=$OLD_ETC does not look like aws1's /etc"
}

# confirm "question"  -> honours MIGRATE_YES=1 for unattended runs
confirm() {
    [ "${MIGRATE_YES:-0}" = "1" ] && { note "auto-confirmed: $1"; return 0; }
    local reply
    printf '%s[?]%s %s [y/N] ' "$YLW" "$RST" "$1"
    read -r reply || true
    [ "$reply" = "y" ] || [ "$reply" = "Y" ] || die "aborted"
}

# Print what would run, or run it. DRY_RUN=1 to preview.
run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '    %sDRY%s %s\n' "$DIM" "$RST" "$*"
    else
        "$@"
    fi
}
