#!/bin/sh
# Take the plugins out of the installer's way, and remember enough to put them
# back. plugins-reattach.sh is the other half; link-dev-tree.sh restores the
# symlinks.
#
# Two separate things have to go, for two separate reasons, and the installer
# fails differently depending on which one you forget.
#
# The symlinks have to go because the installer builds the new tree under
# /tmp/imscp in two steps that both reach gui/plugins. _buildFrontendFiles()
# copies $FindBin::Bin/gui — this checkout — and _savePersistentData() then
# copies the live PLUGINS_DIR over the top (autoinstaller/Functions.pm:333
# and :648). On a normal server the first copy carries no plugins, because
# plugins are not part of the repository. Here they are, because gui/ IS the
# repository, so the second copy meets symlinks the first one wrote, and
# iMSCP::File::copyFile cannot write a symlink over one that exists:
#
#   Couldn't copy the '.../gui/plugins/SGW_X' symlink to
#   '/tmp/imscp/.../gui/plugins/SGW_X': File exists
#
# The database rows have to go because Servers::sqld::mysql::installer's
# _setupDatabase() boots the panel application, and iMSCP\Application::
# loadPlugins() loads every plugin registered in the `plugin` table. A plugin
# registered in the database whose directory the installer has just moved
# aside fails the install outright:
#
#   Couldn't load the SGW_X plugin: Plugin entry point (plugin class) not found
#
# Removing only the symlinks trades the first failure for the second, which is
# why this script does both.
set -eu

GIT_ROOT="${IMSCP_GIT_ROOT:-/var/www/imscp-git}"
PLUGIN_MOUNT_ROOT="${IMSCP_PLUGIN_MOUNT_ROOT:-/var/www/imscp-plugins}"
IMSCP_CONF="${IMSCP_CONF:-/etc/imscp/imscp.conf}"
STATE_FILE="${IMSCP_PLUGIN_STATE:-/var/tmp/imscp-docker-plugins.sql}"

log() { printf '\033[36m==>\033[0m plugins-detach: %s\n' "$*"; }

conf_get() {
    sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$IMSCP_CONF" | head -n 1
}

if [ ! -f "$IMSCP_CONF" ]; then
    log "i-MSCP is not installed; nothing to detach"
    exit 0
fi

DATABASE_NAME="$(conf_get DATABASE_NAME)"
PLUGINS_DIR="$(conf_get PLUGINS_DIR)"

# The rows first, so that a failure here leaves the installation untouched
# rather than half stripped.
if [ -n "$DATABASE_NAME" ] \
    && mysql --batch --skip-column-names -e 'SELECT 1' "$DATABASE_NAME" >/dev/null 2>&1
then
    rows="$(mysql --batch --skip-column-names \
        -e 'SELECT COUNT(*) FROM plugin' "$DATABASE_NAME" 2>/dev/null || printf 0)"

    if [ "${rows:-0}" -gt 0 ]; then
        # --complete-insert keeps plugin_id, so a plugin's identity survives
        # the round trip and anything referring to it still refers to it.
        mysqldump --no-create-info --complete-insert --skip-extended-insert \
            "$DATABASE_NAME" plugin > "$STATE_FILE"
        mysql -e 'DELETE FROM plugin' "$DATABASE_NAME"
        log "saved $rows plugin row(s) to $STATE_FILE and cleared the table"
    else
        # No stale state file: reattach must not resurrect a previous run's
        # rows into a database that has since been emptied on purpose.
        rm -f "$STATE_FILE"
        log "no plugin rows to save"
    fi
else
    log "no reachable database; leaving the plugin table alone"
fi

# Then the symlinks, in both trees. A glob rather than find(1): PLUGINS_DIR
# usually sits under a symlinked gui/, and find does not descend through a
# symlinked directory, which is the trap unlink-dev-tree.sh already falls into.
removed=0
for dir in "$PLUGINS_DIR" "$GIT_ROOT/gui/plugins"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue

    for link in "$dir"/*; do
        [ -L "$link" ] || continue
        case "$(readlink "$link")" in
            "$PLUGIN_MOUNT_ROOT"/*) rm -f -- "$link"; removed=$(( removed + 1 )) ;;
        esac
    done
done

log "removed $removed plugin link(s)"
