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
    # Probe send-migration-tar only, and only far enough to see it start. It is
    # read-only, and closing the pipe early just SIGPIPEs tar on aws1.
    #
    # dump-for-migration is deliberately NOT probed. There is no way to ask
    # authprogs whether a command is permitted without running it, and running
    # this one starts a full database dump - which, under the timeout a probe
    # needs, gets killed part-way and leaves db/ holding a mix of two runs.
    # An earlier version of this script did exactly that.
    out=$(timeout 30 "${SSH[@]}" /root/mig/send-migration-tar 2>&1 >/dev/null | head -1 || true)
    case "$out" in
        *"not allowed"*)
            bad "/root/mig/send-migration-tar is NOT allowlisted in authprogs.conf" ;;
        *"No such file"*|*"not found"*)
            bad "/root/mig/send-migration-tar is allowlisted but not installed on aws1" ;;
        *)
            ok "/root/mig/send-migration-tar is allowlisted and installed" ;;
    esac

    if [ "${FAILED:-0}" -eq 0 ]; then
        note "dump-for-migration is not probed: running it IS the dump."
        note "Both rules go in the same authprogs section, so if the above passed"
        note "it almost certainly does too - the real run confirms it either way."
        log "Channel ready."
        exit 0
    fi
    die "add the rules from migrate/authprogs.conf.snippet, and install the wrappers"
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

log "Dump integrity"
bad_gz=0
while IFS= read -r f; do
    gzip -t "$f" 2>/dev/null || { bad "truncated: ${f#$WORK/}"; bad_gz=$((bad_gz+1)); }
done < <(find "$WORK" -name '*.gz' 2>/dev/null)
[ "$bad_gz" -eq 0 ] && ok "every .gz in $WORK is complete" \
                    || bad "$bad_gz truncated archive(s) - re-run the dump"

if compgen -G "$WORK/db.previous.*" >/dev/null 2>&1; then
    warn "aws1 set an earlier dump aside as $(basename "$(echo "$WORK"/db.previous.* | head -1)")"
    warn "that is the old run, not this one - delete it once you are satisfied"
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
