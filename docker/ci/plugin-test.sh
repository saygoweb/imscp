#!/usr/bin/env bash
#
# Run one plugin's tests on an installed i-MSCP server, from the CI image that
# docker/ci/build-image.sh makes.
#
#   docker/ci/plugin-test.sh [options] <plugins-root> <checkout> [--] <test command>
#
#   <plugins-root>   host directory holding the plugin checkout; it is mounted
#                    at /var/www/imscp-plugins, as the development stack does
#   <checkout>       the plugin's directory name inside it
#   <test command>   run with sh -c, as root, from the plugin's directory
#
# Options:
#   --image <ref>    the CI image (default: $IMSCP_CI_IMAGE, else
#                    ghcr.io/saygoweb/imscp-ci:bookworm)
#   --setup <cmd>    run before the plugin is installed, from its directory
#                    (e.g. installing Composer dependencies)
#   --no-install     only link the plugin in; do not install and enable it
#   --keep           leave the container running afterwards, for a look inside
#
# COMPOSER_CACHE_DIR, when set, is mounted into the container as Composer's
# cache, so CI can keep it between runs.
#
# The same thing .github/workflows/plugin-test.yml runs, so a failing job can be
# reproduced locally with it.

set -euo pipefail

IMAGE="${IMSCP_CI_IMAGE:-ghcr.io/saygoweb/imscp-ci:bookworm}"
SETUP=''
INSTALL=yes
KEEP=no

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --setup) SETUP="$2"; shift 2 ;;
        --no-install) INSTALL=no; shift ;;
        --keep) KEEP=yes; shift ;;
        --) shift; break ;;
        -*) die "unknown option: $1" ;;
        *) break ;;
    esac
done

[ "$#" -ge 3 ] || die "usage: plugin-test.sh [options] <plugins-root> <checkout> [--] <test command>"
PLUGINS_ROOT="$(cd "$1" && pwd)"
CHECKOUT="$2"
shift 2
[ "${1:-}" = -- ] && shift
TEST="$*"

[ -d "$PLUGINS_ROOT/$CHECKOUT" ] || die "$PLUGINS_ROOT/$CHECKOUT does not exist"

CONTAINER="imscp-ci-$CHECKOUT-$$"
IN_CONTAINER="/var/www/imscp-plugins/$CHECKOUT"
SCRIPTS=/usr/local/lib/imscp-docker

cache_mount=()
cache_env=()
if [ -n "${COMPOSER_CACHE_DIR:-}" ]; then
    mkdir -p "$COMPOSER_CACHE_DIR"
    cache_mount=(-v "$COMPOSER_CACHE_DIR:/root/.cache/composer")
    cache_env=(-e COMPOSER_CACHE_DIR=/root/.cache/composer)
fi

cleanup() {
    rc=$?
    [ "$rc" -eq 0 ] || ci_failed_units "$CONTAINER"
    if [ "$KEEP" = yes ]; then
        log "leaving $CONTAINER running: docker exec -it $CONTAINER bash"
    else
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap cleanup EXIT

ci_boot "$CONTAINER" "$IMAGE" -v "$PLUGINS_ROOT:/var/www/imscp-plugins" "${cache_mount[@]}"

run() { docker exec -w "$IN_CONTAINER" "${cache_env[@]}" "$CONTAINER" sh -c "$1"; }

if [ -n "$SETUP" ]; then
    log "setup: $SETUP"
    run "$SETUP"
fi

log "attaching $CHECKOUT"
if [ "$INSTALL" = yes ]; then
    docker exec "$CONTAINER" sh "$SCRIPTS/ci-attach-plugin.sh" "$CHECKOUT"
else
    docker exec "$CONTAINER" sh "$SCRIPTS/ci-attach-plugin.sh" "$CHECKOUT" --no-install
fi

log "test: $TEST"
run "$TEST"
