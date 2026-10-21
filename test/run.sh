#!/bin/sh
# Run the test suite. The single entry point for people and for CI.
#
#   test/run.sh unit [--cover] [files...]   the engine's unit tests: anywhere, as anyone
#   test/run.sh integration [files...]      on the throwaway CI image only, as root
#   test/run.sh ci                          the tests of the CI scripts themselves
#   test/run.sh all                         unit, then integration
#
# Unit tests load the checkout's engine. Integration tests drive the installed
# one, which is the checkout's only when docker/ci/engine-test.sh --link put it
# there. See test/perl/README.md.
#
# Environment:
#   IMSCP_ENGINE_DIR  the installed engine, default /var/www/imscp/engine
#   COVER_DIR         where --cover writes, default ./cover_db
#   PROVE_ARGS        extra prove options, e.g. "--formatter TAP::Formatter::JUnit"
#
# Exits 0 when every test passes, 1 when any fails, 2 when it refuses to run.

set -u

# Paths from the caller mean the caller's directory, not the checkout's: note
# where we were started and where this script is before moving to the root.
CALLER=$PWD
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0") || exit 2
cd "$(dirname "$SELF")/.." || exit 2

case "${COVER_DIR:-}" in
    ''|/*) ;;
    *) COVER_DIR=$CALLER/$COVER_DIR ;;
esac

MARKER=/etc/imscp/ci-image

usage() {
    { echo 'usage:'; sed -n '4,7p' "$SELF" | sed 's/^# /  /'; } >&2
    exit 2
}

unit() {
    cover=no
    if [ "${1:-}" = --cover ]; then
        cover=yes
        shift
    fi
    [ $# -gt 0 ] || set -- test/perl/unit

    if [ "$cover" = no ]; then
        # shellcheck disable=SC2086
        prove -r -j4 --timer -Iengine/PerlLib -Iengine/PerlVendor -Itest/perl/lib ${PROVE_ARGS:-} "$@"
        return
    fi

    COVER_DIR="${COVER_DIR:-$PWD/cover_db}"
    rm -rf "$COVER_DIR"
    # Only the engine's own code: not the tests, the vendored CPAN modules or
    # anything loaded by absolute path from the system.
    HARNESS_PERL_SWITCHES="-MDevel::Cover=-db,$COVER_DIR,-silent,1,+ignore,^test/,+ignore,^engine/PerlVendor/,+ignore,^/"
    export HARNESS_PERL_SWITCHES
    # shellcheck disable=SC2086
    prove -r -j4 --timer -Iengine/PerlLib -Iengine/PerlVendor -Itest/perl/lib ${PROVE_ARGS:-} "$@"
    rc=$?
    cover -silent -report html -outputdir "$COVER_DIR/html" "$COVER_DIR" >/dev/null || rc=1
    echo "coverage report: $COVER_DIR/html/coverage.html"
    return $rc
}

integration() {
    if [ ! -f "$MARKER" ]; then
        echo "$SELF: $MARKER is missing. The integration tests add and delete real" >&2
        echo "customers, so they run only on a throwaway CI image: docker/ci/engine-test.sh" >&2
        return 2
    fi
    [ "$(id -u)" -eq 0 ] || { echo "$SELF: the integration tests must run as root" >&2; return 2; }

    engine="${IMSCP_ENGINE_DIR:-/var/www/imscp/engine}"
    [ $# -gt 0 ] || set -- test/perl/integration
    # One at a time: each engine run processes every pending row on the server.
    # shellcheck disable=SC2086
    prove -r --timer -I"$engine/PerlLib" -I"$engine/PerlVendor" -Itest/perl/lib ${PROVE_ARGS:-} "$@"
}

ci() {
    # shellcheck disable=SC2086
    prove --timer ${PROVE_ARGS:-} test/ci
}

normalise() {
    # prove exits 1 for failures and higher for its own errors; fold to 1.
    [ "$1" -eq 0 ] && return 0
    [ "$1" -eq 2 ] && return 2
    return 1
}

cmd=${1:-}
[ $# -eq 0 ] || shift

# Files and directories named on the command line are relative to the caller.
n=$#
while [ "$n" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
        -*|/*) ;;
        *) arg=$CALLER/$arg ;;
    esac
    set -- "$@" "$arg"
    n=$((n - 1))
done

case "$cmd" in
    unit|integration|ci)
        "$cmd" "$@"
        normalise $?
        exit $?
        ;;
    all)
        # The options and files go to the unit run. A failure there ends it;
        # otherwise the exit status is the integration run's own.
        unit "$@" || exit 1
        integration
        normalise $?
        exit $?
        ;;
    *)
        usage
        ;;
esac
