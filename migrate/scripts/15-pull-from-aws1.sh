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

# An IP, not the name, and deliberately so. Once i-MSCP has run here it writes
#
#     0.0.0.0  aws1.saygoweb.com  aws1
#
# into /etc/hosts (from BASE_SERVER_IP), sets this box's hostname to aws1, and
# points the resolver at the local bind that is authoritative for saygoweb.com.
# nsswitch consults files before dns, so from this box "aws1.saygoweb.com"
# means 0.0.0.0 - itself. Every ssh below would then talk to the new box while
# looking entirely normal, and the cutover dump would overwrite the migrated
# database with a dump of itself.
AWS1="${AWS1:-34.212.49.11}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$AWS1")

MODE=full
case "${1:-}" in
    --pull-only) MODE=pull ;;
    --check)     MODE=check ;;
    "")          ;;
    *)           die "unknown argument: $1" ;;
esac

FAILED=0

# Refuse to talk to ourselves, whatever $AWS1 resolves to.
target_ip=$(getent ahostsv4 "$AWS1" 2>/dev/null | awk '{print $1; exit}')
target_ip="${target_ip:-$AWS1}"
case "$target_ip" in
    0.0.0.0|127.*|::1) die "$AWS1 resolves to $target_ip - that is this box, not aws1" ;;
esac
for own in $(hostname -I 2>/dev/null); do
    [ "$own" = "$target_ip" ] && die "$AWS1 resolves to $target_ip, which is one of this box's own addresses"
done

log "Checking the channel to $AWS1 ($target_ip)"
remote_host=$(timeout 30 "${SSH[@]}" hostname 2>&1 | tail -1) \
    || die "cannot reach $AWS1 over ssh: $remote_host"
# Both machines answer to "aws1" after the migration, so the hostname alone
# proves nothing. The uptime does: aws1 has been up for months.
[ "$remote_host" = "aws1" ] && ok "reached $remote_host at $target_ip" \
                            || warn "remote hostname is '$remote_host', expected aws1"
remote_up=$(timeout 30 "${SSH[@]}" uptime 2>/dev/null | grep -oP 'up\s+\K[0-9]+(?=\s+days)' || true)
if [ -n "${remote_up:-}" ] && [ "$remote_up" -gt 1 ]; then
    ok "remote has been up $remote_up days - this is the old box"
else
    warn "remote uptime is under a day; confirm this really is aws1 and not the new box"
fi
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
