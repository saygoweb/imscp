#!/usr/bin/env bash
#
# Puts back the files that make this box "aws1" as far as i-MSCP is concerned,
# before the installer runs.
#
# The important one is imscp-db-keys. Every mailbox password and customer SQL
# password in the database is Rijndael-CBC ciphertext keyed on it, and
# iMSCP::Bootstrapper silently GENERATES A NEW KEY if the file is missing or
# the wrong length (Bootstrapper.pm:186-227). Run the installer once without
# it and every stored credential is unrecoverable.
#
# Idempotent. DRY_RUN=1 to preview.
#
cd "$(dirname "$0")" && . ./lib.sh
need_root

SRC="${1:-$WORK/etc}"
[ -d "$SRC" ] || SRC="$OLD_ETC/imscp"     # fall back to the copied /etc
log "Restoring i-MSCP identity from $SRC"

keys=""
for c in "$SRC/imscp-db-keys" "$OLD_ETC/imscp/imscp-db-keys"; do
    [ -f "$c" ] && { keys="$c"; break; }
done
[ -n "$keys" ] || die "imscp-db-keys not found - refusing to continue"
[ "$(wc -c < "$keys")" -gt 60 ] || die "$keys looks truncated"

conf=""
for c in "$SRC/imscp.conf" "$OLD_ETC/imscp/imscp.conf"; do
    [ -f "$c" ] && { conf="$c"; break; }
done
[ -n "$conf" ] || die "imscp.conf not found"

run mkdir -p /etc/imscp
run install -m 0640 -o root -g root "$keys" /etc/imscp/imscp-db-keys
run install -m 0644 -o root -g root "$conf" /etc/imscp/imscp.conf
ok "imscp-db-keys and imscp.conf in place"
note "loadConfig() will now treat this as an upgrade and merge aws1's values"

# --- Postfix support files the listener refers to --------------------------
if [ -d "$WORK/etc/postfix" ]; then
    log "Postfix support files"
    run mkdir -p /etc/postfix/tls
    for f in header_checks dnsbl-reply-map; do
        [ -f "$WORK/etc/postfix/$f" ] && run install -m 0644 "$WORK/etc/postfix/$f" "/etc/postfix/$f"
    done
    [ -d "$WORK/etc/postfix/tls" ] && run cp -a "$WORK/etc/postfix/tls/." /etc/postfix/tls/
    note "postmap runs after Postfix is installed - 60-verify.sh checks it"
else
    warn "no $WORK/etc/postfix - run 10-dump-old.sh on aws1 and copy $WORK across"
fi

# --- Spamhaus DQ key -------------------------------------------------------
# Extracted from aws1's main.cf rather than committed: it is a paid Data Query
# credential and has no business in a git repository. The listener reads it
# from here and falls back to the free public zones if it is absent.
log "Spamhaus DQ key"
dqsrc=""
for c in "$WORK/etc/postfix-postconf-n.txt" "$OLD_ETC/postfix/main.cf"; do
    [ -f "$c" ] && { dqsrc="$c"; break; }
done
if [ -n "$dqsrc" ]; then
    dqkey=$(grep -oE '[a-z0-9]{16,}\.zen\.dq\.spamhaus\.net' "$dqsrc" \
            | head -1 | cut -d. -f1 || true)
    if [ -n "${dqkey:-}" ]; then
        run mkdir -p /etc/postfix
        if [ "${DRY_RUN:-0}" != "1" ]; then
            printf '%s\n' "$dqkey" > /etc/postfix/dq-key
            chmod 0600 /etc/postfix/dq-key
        fi
        ok "DQ key recovered from $(basename "$dqsrc") and written to /etc/postfix/dq-key (0600)"
    else
        warn "no DQ key found in $dqsrc - the listener will use the public Spamhaus zones"
    fi
else
    warn "no source for the DQ key - the listener will use the public Spamhaus zones"
fi

# --- Let's Encrypt ---------------------------------------------------------
if [ -f "$WORK/letsencrypt.tar.gz" ]; then
    log "Let's Encrypt archive"
    run tar -C /etc -xzf "$WORK/letsencrypt.tar.gz"
    ok "$(ls /etc/letsencrypt/renewal 2>/dev/null | wc -l) renewal configs"
elif [ -d "$OLD_ETC/letsencrypt" ]; then
    log "Let's Encrypt from $OLD_ETC"
    run rsync -aHAX "$OLD_ETC/letsencrypt/" /etc/letsencrypt/
else
    warn "no Let's Encrypt source found - the panel cert paths in the preseed will not resolve"
fi

# --- the Postfix listener --------------------------------------------------
log "Postfix listener"
run mkdir -p /etc/imscp/listeners.d
run install -m 0644 "../listeners/10_saygoweb_postfix.pl" \
    /etc/imscp/listeners.d/10_saygoweb_postfix.pl
ok "listener installed - main.cf and master.cf customisations will survive"
