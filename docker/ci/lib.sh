# Shared by the docker/ci scripts. Sourced, not run.

log() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '%s: %s\n' "$(basename "$0")" "$*" >&2; exit 1; }

# ci_boot <container> <image> [docker run args...]
#
# Start a container of the CI image and wait for systemd to finish booting.
# Host name and domain are the ones the image was installed with: i-MSCP keys
# its configuration on the FQDN.
ci_boot() {
    local container="$1" image="$2"
    shift 2

    log "booting $image"
    docker run -d --name "$container" \
        --privileged \
        --hostname imscp --domainname docker.local \
        --tmpfs /run:exec,mode=755 --tmpfs /run/lock:mode=1777 \
        "$@" \
        "$image" >/dev/null

    local waited=0
    until docker exec "$container" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; do
        waited=$((waited + 2))
        [ "$waited" -lt 180 ] || die "systemd did not finish booting within 180s"
        sleep 2
    done
    log "booted in ${waited}s"
}

# ci_failed_units <container>: what systemd could not start, for a failed job.
ci_failed_units() {
    printf '\n--- failed units\n' >&2
    docker exec "$1" systemctl --failed --no-pager >&2 2>/dev/null || true
}
