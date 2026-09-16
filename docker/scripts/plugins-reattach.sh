#!/bin/sh
# Put back the plugin rows plugins-detach.sh took out. The symlinks are
# link-dev-tree.sh's job, and `imscp install` runs that first, so by the time
# this runs every plugin the rows name has its directory again.
#
# This runs whether or not the installer succeeded. A failed install is a bad
# reason to lose the record of which plugins were installed and what their
# configuration was: the rows describe the operator's panel, not the install.
set -eu

IMSCP_CONF="${IMSCP_CONF:-/etc/imscp/imscp.conf}"
STATE_FILE="${IMSCP_PLUGIN_STATE:-/var/tmp/imscp-docker-plugins.sql}"

log() { printf '\033[36m==>\033[0m plugins-reattach: %s\n' "$*"; }

conf_get() {
    sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$IMSCP_CONF" | head -n 1
}

if [ ! -f "$STATE_FILE" ]; then
    log "no saved plugin state; nothing to restore"
    exit 0
fi

if [ ! -f "$IMSCP_CONF" ]; then
    log "i-MSCP is not installed; leaving $STATE_FILE in place"
    exit 0
fi

DATABASE_NAME="$(conf_get DATABASE_NAME)"

if [ -z "$DATABASE_NAME" ] \
    || ! mysql --batch --skip-column-names -e 'SELECT 1' "$DATABASE_NAME" >/dev/null 2>&1
then
    log "no reachable database; leaving $STATE_FILE in place"
    exit 0
fi

# The installer recreates the schema, so the table can already hold rows it
# wrote itself. The saved rows are the authority on what was installed here.
mysql -e 'DELETE FROM plugin' "$DATABASE_NAME"
mysql "$DATABASE_NAME" < "$STATE_FILE"

restored="$(mysql --batch --skip-column-names \
    -e 'SELECT COUNT(*) FROM plugin' "$DATABASE_NAME")"

# Only now, once the rows are demonstrably back.
rm -f "$STATE_FILE"

log "restored $restored plugin row(s)"
log "synchronise them in the panel under System tools / Plugin management"
