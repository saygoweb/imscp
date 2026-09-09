#!/bin/sh
# Undo link-dev-tree.sh: replace every link back with a copy of what it pointed
# at, leaving a self-contained installation behind. gui/ comes back complete,
# generated content included, because by then the checkout holds both.
#
# Run before re-running the installer. In principle it is not needed —
# setupInstallFiles() removes $ROOT_DIR/{daemon,engine,gui} itself, and
# File::Path::remove_tree unlinks symlinks rather than descending through them —
# but "in principle" is thin cover when the thing on the other end of the link
# is the user's working tree. Removing the links ourselves first means the
# installer never sees one.

set -eu

GIT_ROOT="${IMSCP_GIT_ROOT:-/var/www/imscp-git}"
PLUGIN_MOUNT_ROOT="${IMSCP_PLUGIN_MOUNT_ROOT:-/var/www/imscp-plugins}"
IMSCP_CONF="${IMSCP_CONF:-/etc/imscp/imscp.conf}"

log() { printf '\033[36m==>\033[0m unlink-dev-tree: %s\n' "$*"; }

conf_get() {
    sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$IMSCP_CONF" | head -n 1
}

if [ ! -f "$IMSCP_CONF" ]; then
    log "i-MSCP is not installed; nothing to unlink"
    exit 0
fi

ROOT_DIR="$(conf_get ROOT_DIR)"
[ -n "$ROOT_DIR" ] || { log "could not read ROOT_DIR from $IMSCP_CONF"; exit 0; }

removed=0
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT

# Any symlink under the installation that points into either mount is ours.
# -depth so that a link is dealt with before anything above it disappears.
find "$ROOT_DIR" -depth -type l -print > "$tmpfile" 2>/dev/null || true

while IFS= read -r link; do
    target="$(readlink "$link")"
    case "$target" in
        "$GIT_ROOT"/*|"$PLUGIN_MOUNT_ROOT"/*) ;;
        *) continue ;;
    esac

    rm -f -- "$link"
    # Restore the code so the installation still works standalone. Plugin links
    # are not restored: a plugin is not part of this repository, and the panel
    # copes with one disappearing.
    case "$target" in
        "$GIT_ROOT"/*) cp -a -- "$target" "$link" ;;
    esac
    removed=$(( removed + 1 ))
done < "$tmpfile"

log "removed $removed link(s) under $ROOT_DIR"
