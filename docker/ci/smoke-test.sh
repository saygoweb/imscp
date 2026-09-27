#!/usr/bin/env bash
#
# Check that a CI image stands on its own: boot it with no checkout mounted and
# make sure the services, the database and the panel's bootstrap all answer.
#
#   docker/ci/smoke-test.sh <image:tag>

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "$#" -eq 1 ] || die "usage: smoke-test.sh <image:tag>"
CONTAINER="imscp-ci-smoke-$$"

cleanup() {
    rc=$?
    [ "$rc" -eq 0 ] || ci_failed_units "$CONTAINER"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    exit "$rc"
}
trap cleanup EXIT

ci_boot "$CONTAINER" "$1"

for unit in mariadb imscp_panel imscp_daemon nginx apache2; do
    docker exec "$CONTAINER" systemctl is-active --quiet "$unit" \
        || die "$unit is not running"
done
log "services up"

docker exec "$CONTAINER" sh -c \
    'mysql --batch --skip-column-names -e "SELECT COUNT(*) FROM admin" "$(sed -n "s/^DATABASE_NAME[[:space:]]*=[[:space:]]*//p" /etc/imscp/imscp.conf)"' \
    >/dev/null || die "the i-MSCP database does not answer"
log "database answers"

docker exec "$CONTAINER" sudo -u vu2000 php7.4 -r \
    'require "/var/www/imscp/gui/include/imscp-lib.php"; echo "panel bootstrapped\n";' \
    || die "the panel does not bootstrap"
