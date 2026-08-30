#!/usr/bin/env bash
#
# Runs the dump on aws1 and pulls it here, over the authprogs-restricted key.
#
#   ./15-pull-from-aws1.sh              # dump, then pull
#   ./15-pull-from-aws1.sh --pull-only  # pull whatever is already there
#   ./15-pull-from-aws1.sh --check      # just prove the channel works
#
# Requires the two wrappers installed on aws1 and allowlisted - see
# migrate/authprogs.conf.snippet. Everything here goes through exactly those
# two commands; no interactive shell is available on aws1 through this key.
#
cd "$(dirname "$0")" && . ./lib.sh
need_root

AWS1="${AWS1:-aws1.saygoweb.com}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$AWS1")

MODE=full
case "${1:-}" in
    --pull-only) MODE=pull ;;
    --check)     MODE=check ;;
    "")          ;;
    *)           die "unknown argument: $1" ;;
esac

FAILED=0

log "Checking the channel to $AWS1"
remote_host=$(timeout 30 "${SSH[@]}" hostname 2>&1 | tail -1) \
    || die "cannot reach $AWS1 over ssh: $remote_host"
[ "$remote_host" = "aws1" ] && ok "reached $remote_host" \
                            || warn "remote hostname is '$remote_host', expected aws1"
note "$(timeout 30 "${SSH[@]}" uptime 2>/dev/null | tail -1)"

if [ "$MODE" = "check" ]; then
    # Confirm the wrappers are allowlisted without actually running the dump.
    # authprogs denies with a recognisable message, so a denial is
    # distinguishable from the command being absent or failing.
    for c in /root/mig/dump-for-migration /root/mig/send-migration-tar; do
        out=$(timeout 30 "${SSH[@]}" "$c" </dev/null 2>&1 >/dev/null | head -1 || true)
        case "$out" in
            *"not allowed"*) bad "$c is NOT allowlisted in authprogs.conf" ;;
            *)               ok  "$c is allowlisted" ;;
        esac
    done
    [ "${FAILED:-0}" -eq 0 ] || die "add the rules from migrate/authprogs.conf.snippet"
    log "Channel ready."
    exit 0
fi

if [ "$MODE" = "full" ]; then
    log "Running the dump on aws1 (this takes a while)"
    if ! timeout 7200 "${SSH[@]}" /root/mig/dump-for-migration; then
        die "the remote dump failed - see its output above"
    fi
    ok "remote dump complete"
fi

log "Pulling /root/mig from aws1"
mkdir -p "$WORK"
# The tar streams from aws1; nothing is staged there beyond the dump itself.
if timeout 7200 "${SSH[@]}" /root/mig/send-migration-tar | tar -C "$(dirname "$WORK")" -xf -; then
    ok "extracted to $WORK"
else
    die "transfer failed - $WORK may be incomplete, do not migrate from it"
fi

log "Verifying against the manifest built on aws1"
if [ -f "$WORK/MANIFEST.sha256" ]; then
    if ( cd "$WORK" && sha256sum --quiet -c MANIFEST.sha256 ); then
        ok "$(grep -c . "$WORK/MANIFEST.sha256") files match their aws1 checksums"
    else
        bad "checksum mismatch - the transfer is not trustworthy"
    fi
else
    bad "no MANIFEST.sha256 - cannot verify the transfer"
fi

log "What arrived"
for f in db/grants.sql db/users.sql etc/imscp-db-keys etc/imscp.conf \
         letsencrypt.tar.gz usr-local.tar.gz jailtime.tar.gz src-repos.tar.gz; do
    [ -e "$WORK/$f" ] && ok "$f ($(du -h "$WORK/$f" | cut -f1))" || bad "$f MISSING"
done
n=$(find "$WORK/db" -name '*.sql.gz' 2>/dev/null | wc -l)
[ "$n" -gt 0 ] && ok "$n database dump(s)" || bad "no database dumps"

if [ -s "$WORK/db/users-unportable.txt" ]; then
    warn "accounts not on a native password hash - handle these by hand:"
    sed 's/^/      /' "$WORK/db/users-unportable.txt" >&2
fi

echo
if [ "${FAILED:-0}" -eq 0 ]; then
    log "Pull complete and verified. Next: 20-mount-data.sh."
else
    die "${FAILED} problem(s) - do not proceed until these are resolved"
fi
