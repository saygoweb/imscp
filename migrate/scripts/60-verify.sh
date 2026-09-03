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
    # A grant is only useful if it names a database that exists. SHOW GRANTS
    # escapes the _ wildcard in a database name with a backslash, and capturing
    # that output through mysql's batch mode doubles it - so the grant lands on
    # a name containing a literal backslash, which matches nothing. The account
    # still authenticates, then fails every query with ERROR 1044. Counting
    # users would not notice; this does.
    # One backslash in mysql.db is CORRECT - it escapes the _ wildcard, so a
    # grant on saygoweb_fa is stored as saygoweb\_fa. The corruption signature
    # is TWO consecutive backslashes. CHAR(92) sidesteps three layers of
    # escaping between bash, mysql and LIKE.
    n=$(mysql -N -B --raw -e "
        SELECT COUNT(*) FROM mysql.db
        WHERE LOCATE(CONCAT(CHAR(92),CHAR(92)), Db) > 0" 2>/dev/null || echo '?')
    [ "${n:-0}" = "0" ] && ok "no grants on backslash-mangled database names" \
                        || bad "$n grant(s) name a doubled-backslash database - re-dump with mysql --raw"

    n=$(mysql -N -B --raw -e "
        SELECT COUNT(*) FROM information_schema.SCHEMATA s
        LEFT JOIN mysql.db d
          ON d.Db = s.SCHEMA_NAME OR d.Db = REPLACE(s.SCHEMA_NAME,'_','\\\\_')
        WHERE s.SCHEMA_NAME NOT IN
              ('mysql','information_schema','performance_schema','sys','imscp')
          AND s.SCHEMA_NAME NOT LIKE 'imscp\\_orig%'
          AND d.Db IS NULL" 2>/dev/null || echo '?')
    if [ "${n:-0}" = "0" ]; then
        ok "every customer database has at least one grantee"
    else
        warn "$n customer database(s) have no grantee - check they were like that on aws1 too"
    fi

    # customer SQL users must exist as real grants, not just panel metadata
    meta=$(mysql -N -B -e "SELECT COUNT(DISTINCT sqlu_name) FROM imscp.sql_user" 2>/dev/null || echo 0)
    real=$(mysql -N -B -e "SELECT COUNT(DISTINCT user) FROM mysql.user WHERE user NOT IN ('root','mysql','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','debian-sys-maint','imscp_user')" 2>/dev/null || echo 0)
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

# --- git-checkout deployment ------------------------------------------------
# A full imscp-autoinstall removes gui/ and engine/ and re-creates them as real
# directories, which silently ends the checkout deployment: everything keeps
# working, but every later `git pull` stops taking effect. See docs/deployment.md.
GIT_ROOT="${GIT_ROOT:-/var/www/imscp-git}"
if [ -d "$GIT_ROOT/.git" ]; then
    for d in engine gui; do
        if [ -L "/var/www/imscp/$d" ]; then
            tgt=$(readlink -f "/var/www/imscp/$d")
            [ "$tgt" = "$GIT_ROOT/$d" ] \
                && ok "/var/www/imscp/$d -> $tgt" \
                || bad "/var/www/imscp/$d points at $tgt, not $GIT_ROOT/$d"
        else
            bad "/var/www/imscp/$d is a real directory - the symlink was lost (autoinstall?); git pull no longer deploys"
        fi
    done
    br=$(git -C "$GIT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ "$br" = "migrate/2026-09" ] && ok "checkout on $br" || bad "checkout on '$br', expected migrate/2026-09"
    n=$(git -C "$GIT_ROOT" status --porcelain 2>/dev/null | wc -l)
    [ "$n" -eq 0 ] && ok "checkout working tree clean" || bad "$n uncommitted change(s) in $GIT_ROOT"
    # SSL private keys must not have been swept up by a blanket chown
    n=$(find "$GIT_ROOT/gui/data/certs" -name '*.pem' ! -user root 2>/dev/null | wc -l)
    [ "$n" -eq 0 ] && ok "all certs/*.pem still root-owned" || bad "$n private key(s) in certs/ no longer owned by root"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    log "All checks passed. Safe to move the Elastic IP."
else
    die "$FAILED check(s) failed"
fi
