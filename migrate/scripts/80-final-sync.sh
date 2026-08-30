#!/usr/bin/env bash
#
# Final delta sync of customer data from aws1, including the mail store.
#
#   ./80-final-sync.sh --check     # is the channel allowlisted?
#   ./80-final-sync.sh             # DRY RUN - shows what would change
#   ./80-final-sync.sh --go        # transfer
#   ./80-final-sync.sh --go --delete   # ...and remove what aws1 no longer has
#
# The volume attached here is a snapshot taken before the rehearsal, so
# everything customers have changed on aws1 since then is missing. This closes
# that gap. /var/www/virtual/_mail holds the maildirs, so mail comes across in
# the same pass - /var/mail/virtual is only a symlink into it.
#
# STOP MAIL AND WEB ON aws1 FIRST. rsync builds its file list once: a message
# delivered after that is simply not in this run, and the customer never sees
# it. The same goes for a file written by a live site.
#
cd "$(dirname "$0")" && . ./lib.sh
need_root

AWS1="${AWS1:-34.212.49.11}"
SRC="${SRC:-/var/www/virtual/}"
DST="${DST:-/var/www/virtual/}"

# -a  archive; -H hardlinks; --numeric-ids because 30-restore-users.sh
#     reproduced aws1's uids exactly and numbers are the thing we trust
# -x  one-file-system. This is not optional: aws1 bind-mounts
#     /var/log/apache2/<domain> into /var/www/virtual/<domain>/logs/<domain>,
#     220 of them, and without -x rsync descends into every one and writes the
#     old box's Apache logs through this box's identical bind mounts.
RSYNC_FLAGS=( -aHx --numeric-ids )

MODE=dry; DELETE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --go)     MODE=go; shift ;;
        --check)  MODE=check; shift ;;
        --delete) DELETE=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

FAILED=0

# --- never sync from ourselves -------------------------------------------
target_ip=$(getent ahostsv4 "$AWS1" 2>/dev/null | awk '{print $1; exit}')
target_ip="${target_ip:-$AWS1}"
case "$target_ip" in
    0.0.0.0|127.*|::1) die "$AWS1 resolves to $target_ip - that is this box" ;;
esac
for own in $(hostname -I 2>/dev/null); do
    [ "$own" = "$target_ip" ] && die "$AWS1 resolves to $target_ip, one of this box's own addresses"
done

# --- the destination must be the mounted data volume ----------------------
mountpoint -q /var/www/virtual || die "/var/www/virtual is not a mount - run 20-mount-data.sh"

# --- report the exact remote command, so an rsync upgrade is self-diagnosing
# authprogs matches commands character for character, and the flag blob rsync
# asks the far end to run encodes this client's version and options. If rsync
# here is ever upgraded the string changes and aws1 will refuse it - so print
# what we are about to ask for rather than leaving a denial to be decoded.
probe=$(mktemp); trap 'rm -f "$probe" "$probe.out"' EXIT
cat > "$probe" <<'PROBE'
#!/bin/bash
echo "${@:2}" >> "$PROBE_OUT"
exit 0
PROBE
chmod +x "$probe"
PROBE_OUT="$probe.out" rsync "${RSYNC_FLAGS[@]}" --rsh="$probe" \
    "$AWS1:$SRC" /tmp/.rsync-probe-dst/ >/dev/null 2>&1 || true
remote_cmd=$(tail -1 "$probe.out" 2>/dev/null || true)
[ -n "$remote_cmd" ] && note "aws1 will be asked to run: $remote_cmd"

log "Source $AWS1:$SRC  ->  $DST"
note "mail is included: $SRC contains _mail/, which /var/mail/virtual points at"

# --- channel check --------------------------------------------------------
# Ask authprogs directly rather than starting a transfer to see whether it is
# refused. Sending the exact command with stdin closed costs about a tenth of a
# second either way: authprogs refuses it outright, or rsync --server starts,
# reaches EOF before requesting a file list, and exits with code 12.
#
# The earlier version ran a real `rsync --dry-run` and read its stderr, which
# was wrong twice over. Once allowlisted it would have walked the whole 199 GB
# tree on the far side just to answer "yes"; and `timeout 60` would then have
# killed it, leaving no output to match, so the check would fall through and
# report the channel open because it had run out of time. Success by accident
# is worse than no check.
dryrun_cmd="${remote_cmd/--server --sender -/--server --sender -n}"

probe_allowed() {
    local cmd="$1" out
    out=$(timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=15 "$AWS1" "$cmd" \
            </dev/null 2>&1 | head -2 || true)
    case "$out" in
        *"not allowed"*) return 1 ;;
        *)               return 0 ;;
    esac
}

if [ -n "$remote_cmd" ] && ! probe_allowed "$remote_cmd"; then
    bad "rsync is not allowlisted on aws1 for this exact command."
    echo
    echo "  Add these two lines to aws1's /root/.ssh/authprogs.conf, under the"
    echo "  section for this box. Two, because --dry-run changes the request:"
    echo
    echo "      $remote_cmd"
    echo "      $dryrun_cmd"
    echo
    echo "  Both are sender-only and pinned to $SRC, so aws1 can be read from"
    echo "  and never written to."
    die "channel not ready"
fi
ok "transfer command is allowlisted on aws1"

if [ -n "$dryrun_cmd" ] && ! probe_allowed "$dryrun_cmd"; then
    # Only the dry run is blocked, so a real --go would work. Say so plainly
    # rather than refusing outright.
    warn "the --dry-run variant is NOT allowlisted; add it too:"
    warn "    $dryrun_cmd"
    [ "$MODE" = "dry" ] && die "cannot dry run without it"
else
    ok "dry-run command is allowlisted on aws1"
fi

[ "$MODE" = "check" ] && { log "Channel ready. Next: ./80-final-sync.sh (dry run)."; exit 0; }

# --- the transfer ---------------------------------------------------------
args=( "${RSYNC_FLAGS[@]}" --info=stats2,progress2 --human-readable )
[ "$DELETE" = "1" ] && args+=( --delete --delete-delay )
[ "$MODE" = "dry" ] && args+=( --dry-run )

if [ "$MODE" = "go" ]; then
    warn "About to write to $DST on this box."
    [ "$DELETE" = "1" ] && warn "--delete is on: files absent from aws1 will be REMOVED here."
    warn "Mail and web should already be stopped on aws1."
    confirm "Proceed with the real transfer?"
else
    log "DRY RUN - nothing will be written. Add --go to transfer."
fi

# Wall clock, because the cutover window is planned around it. `time` writes
# its own format to stderr and would be swallowed by the redirections a caller
# is likely to use, so measure it here and print it with everything else.
#
# `|| rc=$?` rather than a bare call: under `set -e` a failing rsync would end
# the script at that line, and the die below - the one that says do not cut
# over - would never run.
hms() {
    local s=$1
    printf '%dh %02dm %02ds' "$((s/3600))" "$(((s%3600)/60))" "$((s%60))"
}

started=$(date +%s)
log "rsync started $(date -Is)"

rc=0
timeout 21600 rsync "${args[@]}" -e "ssh -o BatchMode=yes" "$AWS1:$SRC" "$DST" || rc=$?

elapsed=$(( $(date +%s) - started ))
log "rsync finished $(date -Is) - wall clock $(hms "$elapsed")"

if [ "$rc" -eq 124 ]; then
    die "rsync hit the 6 hour timeout after $(hms "$elapsed") - do not cut over"
elif [ "$rc" -ne 0 ]; then
    die "rsync exited $rc after $(hms "$elapsed") - do not cut over until this is clean"
fi

if [ "$MODE" = "dry" ]; then
    log "Dry run complete in $(hms "$elapsed")."
    note "The real run adds the time to move the bytes listed above, so treat"
    note "this as the floor for the cutover window, not the estimate."
    exit 0
fi

# --- after the real thing -------------------------------------------------
log "Verifying"
n=$(find "$DST" -maxdepth 1 \( -nouser -o -nogroup \) 2>/dev/null | wc -l)
[ "$n" -eq 0 ] && ok "every top-level entry still resolves to a name" \
               || bad "$n unowned entr(ies) - the uid map and aws1 disagree"
got=$(stat -c %U "$DST/saygoweb.com" 2>/dev/null || echo none)
[ "$got" = "vu2006" ] && ok "saygoweb.com owned by vu2006" || bad "saygoweb.com owned by '$got'"
d=$(ls /var/mail/virtual 2>/dev/null | wc -l)
[ "${d:-0}" -gt 0 ] && ok "$d mail domains visible through /var/mail/virtual" || bad "mail store unreadable"

echo
if [ "${FAILED:-0}" -eq 0 ]; then
    log "Sync complete in $(hms "$elapsed"). Re-run 60-verify.sh and 70-test-services.sh, then move the Elastic IP."
else
    die "$FAILED check(s) failed"
fi
