#!/usr/bin/env bash
#
# Build the CI image: an i-MSCP server installed from this checkout, committed
# as an image, so that a plugin's CI boots an installed server in seconds
# instead of installing one for half an hour.
#
#   docker/ci/build-image.sh <image:tag> [<image:tag>...]
#
# The development image (docker/Dockerfile) cannot be that on its own: the
# installer has to run inside a booted container, with systemd and the
# services up, so nothing can be installed at build time. What this does
# instead is what `docker/imscp up` does — boot the image, run the installer in
# it — and then `docker commit`s the result.
#
# Two differences from the development stack make the result committable:
#
#   * IMSCP_LINK=no. The development stack replaces /var/www/imscp/{gui,engine}
#     with links into the bind-mounted checkout; a commit does not capture bind
#     mounts, so those links would point at nothing. Left unlinked, the
#     installation is self-contained in the container's own layer.
#   * The container is stopped before the commit, so that MariaDB has shut down
#     cleanly and the image does not start with a recovery.
#
# Plugins are attached to a container of the result by
# docker/scripts/ci-attach-plugin.sh; see docker/ci/plugin-test.sh.

set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$CI_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$DOCKER_DIR/.." && pwd)"

DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
BASE_IMAGE="imscp-ci-base:$DEBIAN_SUITE"
CONTAINER="imscp-ci-build-$$"

log() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
die() { printf 'build-image: %s\n' "$*" >&2; exit 1; }

[ "$#" -ge 1 ] || die "usage: build-image.sh <image:tag> [<image:tag>...]"

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "building $BASE_IMAGE"
docker build --build-arg "DEBIAN_SUITE=$DEBIAN_SUITE" -t "$BASE_IMAGE" "$DOCKER_DIR"

# The same container docker-compose.yml describes, minus the published ports
# and the plugins mount, neither of which an image can carry.
log "booting $CONTAINER"
docker run -d --name "$CONTAINER" \
    --privileged \
    --hostname imscp --domainname docker.local \
    --tmpfs /run:exec,mode=755 --tmpfs /run/lock:mode=1777 \
    -v "$PROJECT_ROOT:/var/www/imscp-git" \
    "$BASE_IMAGE" >/dev/null

# The preseed values docker/imscp would pass, at their defaults. The public IP
# is left blank for the installer to look up: 0.0.0.0 is fine as
# BASE_SERVER_IP, but as the public IP it is refused under --noprompt ("Invalid
# configuration"); see docker/preseed.pl. No phpMyAdmin: nothing in CI uses it,
# and its package (github.com/i-MSCP/phpmyadmin) no longer exists upstream, so
# Composer fails the whole install trying to fetch it.
log "installing i-MSCP (20-40 minutes)"
docker exec \
    -e IMSCP_LINK=no \
    -e IMSCP_HOSTNAME=imscp.docker.local \
    -e IMSCP_ADMIN_LOGIN=admin \
    -e IMSCP_ADMIN_PASSWORD=imscp1234 \
    -e IMSCP_ADMIN_EMAIL=admin@example.com \
    -e IMSCP_DATABASE_PASSWORD=imscp1234 \
    -e IMSCP_PANEL_HTTP_PORT=8880 \
    -e IMSCP_PANEL_HTTPS_PORT=8443 \
    -e IMSCP_FTPD_PASSIVE_PORTS=32768-32777 \
    -e IMSCP_SQL_ADMIN_TOOL_PACKAGES=No \
    "$CONTAINER" sh /usr/local/lib/imscp-docker/install-imscp.sh

# Nothing may be left pointing into the checkout, which will not be there.
if docker exec "$CONTAINER" sh -c \
    'find /var/www/imscp -maxdepth 3 -type l -lname "/var/www/imscp-git*" | grep -q .'
then
    die "the installation still links into /var/www/imscp-git"
fi

log "tidying"
docker exec "$CONTAINER" sh -c 'apt-get clean && rm -rf /tmp/* /var/tmp/*'

log "stopping $CONTAINER"
docker stop -t 120 "$CONTAINER" >/dev/null

log "committing $1"
docker commit \
    --change 'LABEL org.opencontainers.image.source="https://github.com/saygoweb/imscp"' \
    --change "LABEL org.opencontainers.image.description=\"i-MSCP installed on Debian $DEBIAN_SUITE, for plugin CI\"" \
    --change "LABEL org.opencontainers.image.revision=\"$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)\"" \
    "$CONTAINER" "$1" >/dev/null

for tag in "${@:2}"; do
    docker tag "$1" "$tag"
done

log "built: $*"
