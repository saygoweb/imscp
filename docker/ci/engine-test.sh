#!/usr/bin/env bash
#
# Run the engine's integration tests on a throwaway CI image.
#
#   docker/ci/engine-test.sh [options] [-- <test/run.sh arguments>]
#
# Options:
#   --image <ref>   the CI image (default: $IMSCP_CI_IMAGE, else
#                   ghcr.io/saygoweb/imscp-ci:trixie)
#   --link          replace the image's installed engine/ with this checkout's,
#                   as docker/imscp link does: a quick loop for engine-only
#                   changes, without building an image. Configuration and
#                   templates stay as the image installed them.
#   --keep          leave the container running afterwards, for a look inside
#
# The test/run.sh arguments default to `integration`. The checkout is mounted at
# /var/www/imscp-git. CI runs this same script; see .github/workflows/test.yml
# and ci-image.yml.

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${IMSCP_CI_IMAGE:-ghcr.io/saygoweb/imscp-ci:trixie}"
LINK=no
KEEP=no

while [ "$#" -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --link) LINK=yes; shift ;;
        --keep) KEEP=yes; shift ;;
        --) shift; break ;;
        *) die "unknown option: $1" ;;
    esac
done
[ "$#" -gt 0 ] || set -- integration

CONTAINER="imscp-ci-engine-$$"

cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ci_failed_units "$CONTAINER"
        printf '\n--- newest engine logs\n' >&2
        docker exec "$CONTAINER" sh -c \
            'ls -t /var/log/imscp/*.log 2>/dev/null | head -3 | while read -r f; do echo "== $f"; tail -n 40 "$f"; done' >&2 || true
    fi
    if [ "$KEEP" = yes ]; then
        log "leaving $CONTAINER running: docker exec -it $CONTAINER bash"
    else
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap cleanup EXIT

ci_boot "$CONTAINER" "$IMAGE" -v "$PROJECT_ROOT:/var/www/imscp-git"

if [ "$LINK" = yes ]; then
    log "linking the checkout's engine"
    docker exec "$CONTAINER" sh -c \
        'rm -rf /var/www/imscp/engine && ln -s /var/www/imscp-git/engine /var/www/imscp/engine'
fi

log "test/run.sh $*"
docker exec -w /var/www/imscp-git "$CONTAINER" sh test/run.sh "$@"
