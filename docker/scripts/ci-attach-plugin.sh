#!/bin/sh
# Attach one plugin checkout to a self-contained installation, and install it.
#
# The CI half of link-dev-tree.sh. The CI image (docker/ci/build-image.sh) is an
# installation with no checkout behind it, so gui/ and engine/ are left alone
# and only the plugin is linked in:
#
#   /var/www/imscp/gui/plugins/<Name> -> /var/www/imscp-plugins/<checkout>
#
# Then, unless --no-install, it installs the plugin through the panel's own
# plugin manager (plugin-ctl.php), runs the backend request that leaves behind,
# and fails unless the plugin ends up enabled. That is also the plugin's
# install test: an install() or a backend step that breaks fails the job here,
# with the plugin's error and the backend log.
#
#   ci-attach-plugin.sh <checkout> [--no-install]
#
# <checkout> is the directory name under /var/www/imscp-plugins. The plugin's
# name comes from its makefile.json, as docker/imscp works it out.

set -eu

PLUGIN_MOUNT_ROOT="${IMSCP_PLUGIN_MOUNT_ROOT:-/var/www/imscp-plugins}"
IMSCP_CONF="${IMSCP_CONF:-/etc/imscp/imscp.conf}"
HERE="$(dirname "$0")"
# How long the backend gets to settle a plugin's to* status.
TIMEOUT="${IMSCP_PLUGIN_TIMEOUT:-300}"

log() { printf '\033[36m==>\033[0m ci-attach-plugin: %s\n' "$*"; }
die() { printf 'ci-attach-plugin: %s\n' "$*" >&2; exit 1; }

conf_get() {
    sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$IMSCP_CONF" | head -n 1
}

checkout="${1:-}"
install=yes
[ "${2:-}" = --no-install ] && install=no
[ -n "$checkout" ] || die "usage: ci-attach-plugin.sh <checkout> [--no-install]"

[ -f "$IMSCP_CONF" ] || die "$IMSCP_CONF not found — i-MSCP is not installed"
path="$PLUGIN_MOUNT_ROOT/$checkout"
[ -d "$path" ] || die "plugin checkout $path is not mounted"

name=''
if [ -f "$path/makefile.json" ]; then
    name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$path/makefile.json" | head -n 1)"
fi
[ -n "$name" ] || die "no plugin name in $path/makefile.json"

PLUGINS_DIR="$(conf_get PLUGINS_DIR)"
PANEL_USER="$(conf_get SYSTEM_USER_PREFIX)$(conf_get SYSTEM_USER_MIN_UID)"
[ -n "$PLUGINS_DIR" ] || die "could not read PLUGINS_DIR out of $IMSCP_CONF"

rm -rf -- "${PLUGINS_DIR:?}/$name"
ln -s "$path" "$PLUGINS_DIR/$name"
log "$name -> $path"

# The checkout arrives owned by whoever cloned it on the runner; the panel only
# has to read it.
chmod -R a+rX "$path"

# open_basedir is tested against the resolved path, so the mount has to be
# named in the panel's pool, as link-dev-tree.sh does for the dev stack.
pool='/usr/local/etc/imscp_panel/php-fpm.conf'
if [ -f "$pool" ] && ! grep -q "$PLUGIN_MOUNT_ROOT/" "$pool"; then
    sed -i "s#^\(php_admin_value\[open_basedir\][[:space:]]*=[[:space:]]*\)#\1$PLUGIN_MOUNT_ROOT/:#" "$pool"
    systemctl restart imscp_panel
    log "open_basedir += $PLUGIN_MOUNT_ROOT/"
fi

[ "$install" = yes ] || { log "linked; not installing (--no-install)"; exit 0; }

ctl() { sudo -u "$PANEL_USER" php7.4 "$HERE/plugin-ctl.php" "$@"; }

ctl sync
ctl install "$name"

# A plugin with a backend part is left at a to* status for the backend. The
# daemon has been sent the request already; running the request manager here
# as well makes it happen now rather than whenever the daemon gets to it, and
# it takes its own lock, so the two cannot run the request twice at once.
perl /var/www/imscp/engine/imscp-rqst-mngr || true

waited=0
while :; do
    line="$(ctl status "$name")"
    status="$(printf '%s' "$line" | cut -f1)"
    error="$(printf '%s' "$line" | cut -f2-)"

    case "$status" in
        enabled)
            log "$name is enabled"
            exit 0
            ;;
        to*) ;;
        *)
            printf 'ci-attach-plugin: %s ended up %s: %s\n' "$name" "$status" "$error" >&2
            for f in "/var/log/imscp/Modules::Plugin_$name.log" /var/log/imscp/imscp-rqst-mngr.log; do
                [ -f "$f" ] || continue
                printf '\n--- %s\n' "$f" >&2
                tail -n 50 "$f" >&2
            done
            exit 1
            ;;
    esac

    [ -z "$error" ] || die "$name: $error"
    [ "$waited" -lt "$TIMEOUT" ] || die "$name still $status after ${TIMEOUT}s"
    sleep 5
    waited=$((waited + 5))
    perl /var/www/imscp/engine/imscp-rqst-mngr || true
done
