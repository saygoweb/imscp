#!/usr/bin/env bash
#
# RUNS ON aws1 (the old buster box), as root.
#
# Captures everything that is not on the data volume: the databases, the SQL
# grants, and the handful of /etc files the new box needs. Safe to run while
# aws1 is serving - take a rehearsal copy now, and run it again during the
# cutover window with mail and web stopped.
#
#   ./10-dump-old.sh [outdir]        default: /root/mig
#
set -euo pipefail
OUT="${1:-/root/mig}"
DB="$OUT/db"
ETC="$OUT/etc"

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
mkdir -p "$DB" "$ETC"

# --events makes mysqldump run SHOW EVENTS, which fails with
#   ERROR 1577: Cannot proceed, because event scheduler is disabled
# when the server was started with event_scheduler=DISABLED. (Plain OFF is
# fine.) Probe it directly rather than guessing from the variable, and read
# mysql.event to know whether omitting it would actually lose anything - that
# table is readable whatever the scheduler is doing.
EVENTS_OPT="--events"
ev_count=$(mysql -N -B -e 'SELECT COUNT(*) FROM mysql.event' 2>/dev/null || echo '?')
if ! mysqldump --events --no-data --no-create-info mysql >/dev/null 2>&1; then
    EVENTS_OPT=""
    if [ "$ev_count" = "0" ]; then
        echo "==> Event scheduler is DISABLED; no events exist, dumping without --events"
    else
        echo "!!  Event scheduler is DISABLED and mysqldump cannot read events."
        echo "!!  $ev_count row(s) in mysql.event will NOT be in these dumps."
        echo "!!  Either restart MariaDB with --event-scheduler=OFF and re-run,"
        echo "!!  or recreate them by hand on the new box. Saving the raw rows:"
        mysqldump --no-create-info --skip-extended-insert mysql event \
            > "$DB/mysql-event-rows.sql" 2>/dev/null \
            && echo "!!  -> $DB/mysql-event-rows.sql" \
            || echo "!!  -> could not save them either"
    fi
fi

# Start from an empty db/ every time. Without this a re-run leaves the previous
# run's files in place, so the directory becomes a mix of dumps taken at
# different moments - and a database dropped or renamed between runs keeps a
# stale dump that would be restored as though it were current.
if [ -n "$(ls -A "$DB" 2>/dev/null)" ]; then
    prev="$OUT/db.previous.$(date +%Y%m%d-%H%M%S)"
    echo "==> Moving the previous dump aside to $prev"
    mv "$DB" "$prev"
    mkdir -p "$DB"
fi

echo "==> Dumping databases to $DB"
# Per-database, not --all-databases: the mysql system schema cannot be carried
# from 10.3 to 11.8, and per-file dumps let you reload one customer alone.
#
# --single-transaction gives a consistent snapshot for InnoDB only. Any MyISAM
# tables are dumped without locking, so for the CUTOVER dump stop mail and web
# first rather than relying on this.
failed=0
while read -r db; do
    printf '    %-40s' "$db"
    if mysqldump --single-transaction --quick --routines --triggers $EVENTS_OPT \
                 --default-character-set=utf8mb4 "$db" 2>"$DB/.err" | gzip -1 > "$DB/$db.sql.gz"
    then
        # mysqldump succeeding is not proof the file is whole: a kill between
        # gzip's last write and its trailer leaves a truncated archive that
        # restores silently as a partial database. Test it now, while there is
        # still something to compare against.
        if gzip -t "$DB/$db.sql.gz" 2>/dev/null; then
            printf 'ok  %s\n' "$(du -h "$DB/$db.sql.gz" | cut -f1)"
        else
            printf 'TRUNCATED\n'
            rm -f "$DB/$db.sql.gz"
            failed=$((failed+1))
        fi
    else
        printf 'FAILED\n'
        sed 's/^/        /' "$DB/.err" >&2
        # A partial dump is worse than none: it would restore as truncated data.
        rm -f "$DB/$db.sql.gz"
        failed=$((failed+1))
    fi
done < <(mysql -N -B -e 'SHOW DATABASES' \
         | grep -vxE 'mysql|information_schema|performance_schema|sys')
rm -f "$DB/.err"

if [ "$failed" -gt 0 ]; then
    echo
    echo "!!  $failed database(s) failed to dump. Fix the cause and re-run;"
    echo "!!  do NOT migrate with them missing."
    exit 1
fi

echo "==> Capturing SQL users and grants"
# i-MSCP does NOT store customer SQL passwords: sql_user holds only sqlu_name,
# sqlu_host and sqld_id - the sqlu_pass column was dropped (DatabaseUpdate
# r247), and there is no Modules/SqlUser.pm that would recreate the accounts.
#
# So the password exists in exactly two places: MariaDB's grant tables, as a
# mysql_native_password hash, and the customer's own application config on
# disk. Carrying the hash is what keeps a wp-config.php working unchanged.
#
# Two files, deliberately:
#   users.sql   accounts + password hashes, generated explicitly
#   grants.sql  privileges, from SHOW GRANTS
#
# The accounts are not left to SHOW GRANTS because its syntax for the password
# differs across versions (10.3 emits IDENTIFIED BY PASSWORD, 10.4+ emits
# IDENTIFIED VIA ... USING). Reading the hash out of mysql.user and emitting
# one canonical form avoids depending on that. On 10.3 a native-password user
# may carry the hash in `password` with an empty `plugin`, so take whichever
# column is populated.
mysql -N -B -e "
    SELECT CONCAT(
        'CREATE USER IF NOT EXISTS ', QUOTE(user), '@', QUOTE(host),
        ' IDENTIFIED VIA mysql_native_password USING ',
        QUOTE(COALESCE(NULLIF(authentication_string,''), NULLIF(password,''))), ';')
    FROM mysql.user
    WHERE user NOT IN ('root','mysql','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','debian-sys-maint')
      AND user <> ''
      AND COALESCE(NULLIF(authentication_string,''), NULLIF(password,'')) LIKE '*%'
    " > "$DB/users.sql"
echo "    $(grep -c . "$DB/users.sql") user account(s) with native password hashes"

# Anything not on a native password hash cannot be carried this way - report it
# rather than leaving it to be discovered later.
#
# The COALESCE ends in '' deliberately. An account with no password at all
# yields NULL, and `NULL NOT LIKE '*%'` is NULL rather than true - so without
# the empty-string default such an account matches neither this query nor the
# users.sql one above, and disappears without a word. That is exactly how
# aws1's `migrator` (ALL PRIVILEGES, WITH GRANT OPTION) was missed.
mysql -N -B -e "
    SELECT CONCAT(user,'@',host,
                  '  plugin=', IF(plugin='', '(none)', plugin),
                  '  password=', IF(COALESCE(NULLIF(authentication_string,''),
                                             NULLIF(password,''), '')='',
                                    'NONE', 'non-native'))
    FROM mysql.user
    WHERE user NOT IN ('root','mysql','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','debian-sys-maint')
      AND user <> ''
      AND COALESCE(NULLIF(authentication_string,''), NULLIF(password,''), '') NOT LIKE '*%'
    " > "$DB/users-unportable.txt"
if [ -s "$DB/users-unportable.txt" ]; then
    echo "    !! $(grep -c . "$DB/users-unportable.txt") account(s) NOT on a native password hash:"
    sed 's/^/       /' "$DB/users-unportable.txt"
    echo "       these need handling by hand - see $DB/users-unportable.txt"
fi

# Privileges. The USAGE line repeats the password in some versions; it is
# harmless on replay because users.sql has already created the account.
mysql -N -B -e "
    SELECT CONCAT('SHOW GRANTS FOR ', QUOTE(user), '@', QUOTE(host), ';')
    FROM mysql.user
    WHERE user NOT IN ('root','mysql','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','debian-sys-maint')
      AND user <> ''" \
  | mysql -N -B \
  | sed 's/$/;/' > "$DB/grants.sql"
echo "    $(grep -c ';' "$DB/grants.sql") grant statement(s)"

echo "==> Copying configuration that is not on the data volume"
install -m 0640 /etc/imscp/imscp-db-keys "$ETC/imscp-db-keys"
install -m 0644 /etc/imscp/imscp.conf    "$ETC/imscp.conf"

# The panel certificate lives in /etc/imscp too, as <BASE_SERVER_VHOST>.pem -
# key and fullchain concatenated. nginx refuses to start without it, and the
# installer does not rebuild it from the PANEL_SSL_* inputs on an upgrade, so
# it has to travel. /usr/local/bin/panel-combine-ssl regenerates it from the
# certbot files if it is ever lost.
for pem in /etc/imscp/*.pem; do
    [ -e "$pem" ] || continue
    install -m 0600 "$pem" "$ETC/$(basename "$pem")"
    echo "    panel certificate: $(basename "$pem")"
done

# Postfix pieces the listener refers to, but does not itself contain
mkdir -p "$ETC/postfix/tls"
for f in header_checks dnsbl-reply-map; do
    [ -f "/etc/postfix/$f" ] && cp -a "/etc/postfix/$f" "$ETC/postfix/"
done
cp -a /etc/postfix/tls/. "$ETC/postfix/tls/" 2>/dev/null || true
# for reference when checking the listener's output
postconf -n > "$ETC/postfix-postconf-n.txt"

# Account map - the authoritative uid/gid source
for f in passwd group; do cp -a "/etc/$f" "$ETC/$f"; done

echo "==> Archiving Let's Encrypt (168 lineages)"
tar -C /etc -czf "$OUT/letsencrypt.tar.gz" letsencrypt

echo "==> Archiving jailtime and friends"
tar -C /etc -czf "$OUT/jailtime.tar.gz" \
    jailtime blockhandler snivirtualproxy \
    cipwhois.conf iptocidr.conf php-fpm-site.conf 2>/dev/null || \
    echo "    (some paths absent - check the archive)"

# The live /etc/jailtime/jail.yaml is root-only, and it is not settled whether
# it includes the /home/cambell/jailtime working copy or the /etc one. Pull it
# out on its own so the answer is in plain sight next to the archive.
[ -f /etc/jailtime/jail.yaml ] && cp -a /etc/jailtime/jail.yaml "$ETC/jailtime-jail.yaml"

echo "==> Archiving /usr/local and the jailtime binaries"
# None of this is packaged and none of it is on the data volume. Only the venv
# is excluded: it is rebuilt on the new box against python3.13, not carried.
# server-utils' own .git is kept, so the archive restores as a usable checkout.
tar -C / -czf "$OUT/usr-local.tar.gz" \
    --exclude='usr/local/bin/server-utils/.venv' \
    usr/local/bin usr/local/sbin usr/local/lib/jailtime \
    usr/share/doc/jailtime usr/sbin/jailtime usr/sbin/jailtimed 2>/dev/null || \
    echo "    (some paths absent - check the archive)"

echo "==> Archiving the two source repos that exist only on aws1"
# server-utils.git and blockhandler.git are bare, with no upstream. If these
# are lost with the box, the tools in /usr/local/bin lose their history.
if [ -d /home/cambell/src/sgw ]; then
    tar -C /home/cambell/src/sgw -czf "$OUT/src-repos.tar.gz" \
        server-utils.git blockhandler.git 2>/dev/null || \
        echo "    (one or both absent - check the archive)"
else
    echo "    /home/cambell/src/sgw is gone - the bare repos are NOT captured"
fi

echo "==> Copying the systemd units and the loose bits of /etc"
mkdir -p "$ETC/systemd"
for u in jailtimed.service blockhandler.service snivirtualproxy.service; do
    [ -e "/etc/systemd/system/$u" ] && cp -a "/etc/systemd/system/$u" "$ETC/systemd/"
    [ -d "/etc/systemd/system/$u.d" ] && cp -a "/etc/systemd/system/$u.d" "$ETC/systemd/"
done
mkdir -p "$ETC/logrotate.d" "$ETC/sysctl.d"
[ -f /etc/logrotate.d/blockhandler ] && cp -a /etc/logrotate.d/blockhandler "$ETC/logrotate.d/"
cp -a /etc/sysctl.d/*.conf "$ETC/sysctl.d/" 2>/dev/null || true

# What refreshes dshield-block.txt and cidr-block.txt is not in /etc/cron.d.
crontab -l -u root > "$ETC/root.crontab" 2>/dev/null \
    && echo "    root crontab: $(grep -cvE '^\s*(#|$)' "$ETC/root.crontab") entries" \
    || echo "    (no root crontab)"

echo
echo "==> Done. Copy $OUT to the new box, e.g.:"
echo "    rsync -aHz $OUT/ newbox:/root/mig/"
du -sh "$OUT"
