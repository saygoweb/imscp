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

echo "==> Dumping databases to $DB"
# Per-database, not --all-databases: the mysql system schema cannot be carried
# from 10.3 to 11.8, and per-file dumps let you reload one customer alone.
mysql -N -B -e 'SHOW DATABASES' \
  | grep -vxE 'mysql|information_schema|performance_schema|sys' \
  | while read -r db; do
        printf '    %s\n' "$db"
        mysqldump --single-transaction --quick --routines --triggers --events \
                  --default-character-set=utf8mb4 "$db" \
          | gzip -1 > "$DB/$db.sql.gz"
    done

echo "==> Capturing SQL grants"
# i-MSCP has no module that recreates customer SQL users: the sql_user table is
# panel metadata only. Without these grants every customer application loses
# its database login.
mysql -N -B -e "
    SELECT CONCAT('SHOW GRANTS FOR ', QUOTE(user), '@', QUOTE(host), ';')
    FROM mysql.user
    WHERE user NOT IN ('root','mysql.sys','mysql.session','debian-sys-maint')
      AND user <> ''" \
  | mysql -N -B \
  | sed 's/$/;/' > "$DB/grants.sql"
echo "    $(grep -c ';' "$DB/grants.sql") grant statements"

echo "==> Copying configuration that is not on the data volume"
install -m 0640 /etc/imscp/imscp-db-keys "$ETC/imscp-db-keys"
install -m 0644 /etc/imscp/imscp.conf    "$ETC/imscp.conf"

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
    jailtime blockhandler snivirtualproxy cipwhois.conf iptocidr.conf 2>/dev/null || \
    echo "    (some paths absent - check the archive)"

echo
echo "==> Done. Copy $OUT to the new box, e.g.:"
echo "    rsync -aHz $OUT/ newbox:/root/mig/"
du -sh "$OUT"
