#!/usr/bin/env bash
#
# Restores the databases and the SQL grants, before the i-MSCP installer runs.
#
# MariaDB is installed here rather than left to the installer, because the
# database has to be in place first: with the admin row present the installer
# skips the master-password dialog, and setupDbTasks() rebuilds every customer
# entity from these tables.
#
# The grants matter as much as the data. i-MSCP has no module that recreates
# customer SQL users - sql_user is panel metadata only - so without them every
# customer application loses its database login.
#
# Idempotent-ish: reloading a dump overwrites that database. DRY_RUN=1 to preview.
#
cd "$(dirname "$0")" && . ./lib.sh
need_root

[ -d "$DUMP_DIR" ] || die "no dumps at $DUMP_DIR - run 10-dump-old.sh on aws1 and copy $WORK across"
count=$(find "$DUMP_DIR" -name '*.sql.gz' | wc -l)
[ "$count" -gt 0 ] || die "no *.sql.gz in $DUMP_DIR"
log "$count database dump(s) in $DUMP_DIR"

if ! command -v mariadb >/dev/null 2>&1 && ! command -v mysql >/dev/null 2>&1; then
    log "Installing MariaDB 11.8 from Debian main"
    run apt-get update -qq
    run apt-get -y --no-install-recommends install mariadb-server mariadb-client
fi
run systemctl enable --now mariadb
[ "${DRY_RUN:-0}" = "1" ] || mysqladmin ping >/dev/null 2>&1 || die "MariaDB is not responding"

confirm "Restore $count database(s) into $(mysql -N -B -e 'SELECT VERSION()' 2>/dev/null || echo 'MariaDB')?"

log "Restoring databases"
for f in "$DUMP_DIR"/*.sql.gz; do
    db=$(basename "$f" .sql.gz)
    printf '    %-40s' "$db"
    if [ "${DRY_RUN:-0}" = "1" ]; then echo "(dry)"; continue; fi
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$db\`
              CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    if zcat "$f" | mysql "$db"; then echo "ok"; else echo "FAILED"; fi
done

if [ -f "$DUMP_DIR/users.sql" ]; then
    log "Recreating SQL user accounts"
    # Verified on MariaDB 11.8.6: a mysql_native_password hash carried over
    # from 10.3 replays unchanged, the plugin is preserved, and the original
    # plaintext still authenticates over both TCP and the unix socket. That is
    # what keeps every customer's wp-config.php working untouched.
    if [ "${DRY_RUN:-0}" != "1" ]; then
        ufail=0
        while IFS= read -r stmt; do
            [ -n "${stmt// }" ] || continue
            mysql -e "$stmt" 2>/dev/null || { warn "user failed: ${stmt:0:70}"; ufail=$((ufail+1)); }
        done < "$DUMP_DIR/users.sql"
        n=$(grep -c . "$DUMP_DIR/users.sql")
        [ "$ufail" -eq 0 ] && ok "$n SQL account(s) recreated with their original passwords" \
                           || warn "$ufail of $n account(s) failed"
    fi
else
    warn "no users.sql - customer SQL passwords will NOT survive"
fi

if [ -s "$DUMP_DIR/users-unportable.txt" ]; then
    warn "these accounts are not on a native password hash and need handling by hand:"
    sed 's/^/      /' "$DUMP_DIR/users-unportable.txt" >&2
fi

if [ -f "$DUMP_DIR/grants.sql" ]; then
    log "Replaying SQL grants"
    # MariaDB still accepts IDENTIFIED BY PASSWORD '<hash>' and still ships
    # mysql_native_password, so 10.3 hashes replay onto 11.8. Failures are
    # reported rather than fatal - a single unparsable grant should not stop
    # the rest.
    if [ "${DRY_RUN:-0}" != "1" ]; then
        fails=0
        while IFS= read -r stmt; do
            [ -n "${stmt// }" ] || continue
            case "$stmt" in \#*|--*) continue ;; esac
            mysql -e "$stmt" 2>/dev/null || { warn "grant failed: ${stmt:0:80}"; fails=$((fails+1)); }
        done < "$DUMP_DIR/grants.sql"
        run mysql -e "FLUSH PRIVILEGES"
        [ "$fails" -eq 0 ] && ok "all grants replayed" || warn "$fails grant(s) failed - review above"
    fi
else
    warn "no grants.sql - customer SQL users will NOT exist"
fi

log "Running mariadb-upgrade (10.3 -> 11.8)"
run mariadb-upgrade

if [ "${DRY_RUN:-0}" != "1" ]; then
    echo
    FAILED=0
    mysql -N -B -e "USE imscp; SELECT 1" >/dev/null 2>&1 \
        && ok "imscp database present" || bad "imscp database missing"
    n=$(mysql -N -B -e "SELECT COUNT(*) FROM imscp.admin WHERE admin_type='user'" 2>/dev/null || echo 0)
    [ "${n:-0}" -gt 0 ] && ok "$n customer account(s) in imscp.admin" || bad "no customers in imscp.admin"
    n=$(mysql -N -B -e "SELECT COUNT(*) FROM imscp.domain" 2>/dev/null || echo 0)
    note "$n domain row(s)"
    [ "${FAILED:-0}" -eq 0 ] || die "database restore did not verify"
fi
