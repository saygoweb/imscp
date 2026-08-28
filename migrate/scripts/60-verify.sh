#!/usr/bin/env bash
#
# Post-install verification. Read-only, safe to run repeatedly.
# Run before moving the Elastic IP - everything here can be checked while aws1
# is still serving.
#
cd "$(dirname "$0")" && . ./lib.sh
FAILED=0
log "Post-install verification"

# --- the encryption key survived ------------------------------------------
if [ -f /etc/imscp/imscp-db-keys ]; then
    if cmp -s /etc/imscp/imscp-db-keys "$OLD_ETC/imscp/imscp-db-keys"; then
        ok "imscp-db-keys matches aws1 - stored passwords remain decryptable"
    else
        bad "imscp-db-keys DIFFERS from aws1 - stored credentials are unrecoverable"
    fi
else
    bad "/etc/imscp/imscp-db-keys missing"
fi

# --- ownership -------------------------------------------------------------
if mountpoint -q "$DATA_MNT"; then
    ok "$DATA_MNT mounted"
    n=$(find "$DATA_MNT" -maxdepth 1 \( -nouser -o -nogroup \) 2>/dev/null | wc -l)
    [ "$n" -eq 0 ] && ok "no unowned entries at the top of $DATA_MNT" \
                   || bad "$n unowned entr(ies) - uid map is wrong"
    got=$(stat -c %U "$DATA_MNT/saygoweb.com" 2>/dev/null || echo none)
    [ "$got" = "vu2006" ] && ok "saygoweb.com owned by vu2006" \
                          || bad "saygoweb.com owned by '$got', expected vu2006"
else
    bad "$DATA_MNT is not mounted"
fi

# --- mail store ------------------------------------------------------------
if [ -L "$MAIL_LINK" ] && [ -d "$MAIL_LINK" ]; then
    ok "$MAIL_LINK -> $(readlink "$MAIL_LINK") ($(ls "$MAIL_LINK" | wc -l) domains)"
else
    bad "$MAIL_LINK is not a working symlink"
fi

# --- database --------------------------------------------------------------
if mysql -N -B -e 'SELECT 1' >/dev/null 2>&1; then
    ok "MariaDB $(mysql -N -B -e 'SELECT VERSION()')"
    for q in "admin:SELECT COUNT(*) FROM imscp.admin WHERE admin_type='user'" \
             "domain:SELECT COUNT(*) FROM imscp.domain" \
             "mail:SELECT COUNT(*) FROM imscp.mail_users"; do
        lbl=${q%%:*}; sql=${q#*:}
        n=$(mysql -N -B -e "$sql" 2>/dev/null || echo 0)
        [ "${n:-0}" -gt 0 ] && ok "$lbl rows: $n" || bad "$lbl table empty"
    done
    # entities that did not rebuild cleanly
    for t in "domain:domain_status" "subdomain:subdomain_status" \
             "domain_aliasses:alias_status" "mail_users:status" "ftp_users:status"; do
        tbl=${t%%:*}; col=${t#*:}
        n=$(mysql -N -B -e "SELECT COUNT(*) FROM imscp.$tbl WHERE $col NOT IN ('ok','disabled')" 2>/dev/null || echo '?')
        [ "$n" = "0" ] && ok "$tbl: all ok" || bad "$tbl: $n row(s) not ok"
    done
    # customer SQL users must exist as real grants, not just panel metadata
    meta=$(mysql -N -B -e "SELECT COUNT(DISTINCT sqlu_name) FROM imscp.sql_user" 2>/dev/null || echo 0)
    real=$(mysql -N -B -e "SELECT COUNT(DISTINCT user) FROM mysql.user WHERE user NOT IN ('root','mariadb.sys','mysql','debian-sys-maint','imscp_user')" 2>/dev/null || echo 0)
    if [ "${meta:-0}" -gt 0 ] && [ "${real:-0}" -ge "${meta:-0}" ]; then
        ok "customer SQL users: $real present for $meta in sql_user"
    else
        bad "customer SQL users: only $real present for $meta in sql_user - replay grants.sql"
    fi
else
    bad "cannot reach MariaDB"
fi

# --- services --------------------------------------------------------------
for s in apache2 nginx mariadb postfix courier-authdaemon courier-imap \
         courier-pop proftpd named imscp_daemon imscp_panel; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then ok "$s active"
    elif systemctl list-unit-files "$s.service" >/dev/null 2>&1 \
         && systemctl cat "$s" >/dev/null 2>&1; then bad "$s not active"
    else note "$s not installed"; fi
done
n=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
[ "$n" -eq 0 ] && ok "no failed units" || bad "$n failed unit(s): $(systemctl --failed --no-legend | awk '{print $1}' | tr '\n' ' ')"

# --- the Postfix listener actually applied ---------------------------------
if command -v postconf >/dev/null 2>&1; then
    for chk in "myhostname=mail.saygoweb.com" "smtpd_sasl_auth_enable=no" \
               "header_checks=pcre:/etc/postfix/header_checks" "virtual_uid_maps=static:999"; do
        k=${chk%%=*}; want=${chk#*=}
        got=$(postconf -h "$k" 2>/dev/null || echo '')
        [ "$got" = "$want" ] && ok "postconf $k = $want" \
                             || bad "postconf $k = '$got', expected '$want'"
    done
    for m in header_checks dnsbl-reply-map; do
        [ -f "/etc/postfix/$m" ] && ok "/etc/postfix/$m present" || bad "/etc/postfix/$m missing"
    done
    [ -f /etc/postfix/dnsbl-reply-map.db ] && ok "dnsbl-reply-map is postmapped" \
        || bad "run: postmap /etc/postfix/dnsbl-reply-map"
    grep -q 'smtpd_sasl_auth_enable=yes' /etc/postfix/master.cf 2>/dev/null \
        && ok "master.cf carries the submission/smtps overrides" \
        || bad "master.cf missing the submission/smtps overrides"
fi

# --- php ------------------------------------------------------------------
if [ -f /etc/imscp/php/fpm/php.ini ]; then
    got=$(awk -F= '/^memory_limit/{gsub(/ /,"",$2); print $2}' /etc/imscp/php/fpm/php.ini)
    [ "$got" = "512M" ] && ok "customer php memory_limit = 512M" \
                        || bad "customer php memory_limit = '$got', expected 512M"
fi
n=$(ls /etc/php/7.4/fpm/pool.d/*.conf 2>/dev/null | wc -l)
[ "$n" -gt 100 ] && ok "$n PHP-FPM pools generated" || bad "only $n PHP-FPM pools (aws1 had 192)"

# --- vhosts and certs ------------------------------------------------------
n=$(ls /etc/apache2/sites-enabled/*.conf 2>/dev/null | wc -l)
[ "$n" -gt 300 ] && ok "$n apache vhosts enabled" || bad "only $n apache vhosts (aws1 had 380)"
n=$(ls /etc/letsencrypt/renewal/*.conf 2>/dev/null | wc -l)
[ "$n" -gt 150 ] && ok "$n certbot renewal configs" || bad "only $n renewal configs (aws1 had 168)"

echo
if [ "$FAILED" -eq 0 ]; then
    log "All checks passed. Safe to move the Elastic IP."
else
    die "$FAILED check(s) failed"
fi
