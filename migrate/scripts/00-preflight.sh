#!/usr/bin/env bash
#
# Read-only. Verifies the trixie box is ready before anything is changed.
# Run first, and again after fixing whatever it reports.
#
#   ./00-preflight.sh
#
cd "$(dirname "$0")" && . ./lib.sh

FAILED=0
log "Preflight checks for the aws1 migration"

# --- distribution ----------------------------------------------------------
if [ -r /etc/debian_version ] && grep -q '^13' /etc/debian_version; then
    ok "Debian $(cat /etc/debian_version)"
else
    bad "expected Debian 13, found $(cat /etc/debian_version 2>/dev/null || echo unknown)"
fi

# --- i-MSCP must not already be installed ----------------------------------
if [ -e /etc/imscp ] || [ -e /var/www/imscp ]; then
    bad "i-MSCP already present (/etc/imscp or /var/www/imscp) - this is a fresh-box procedure"
else
    ok "no existing i-MSCP installation"
fi

# --- aws1's /etc -----------------------------------------------------------
if [ -f "$OLD_ETC/imscp/imscp-db-keys" ]; then
    if [ "$(wc -c < "$OLD_ETC/imscp/imscp-db-keys")" -gt 60 ]; then
        ok "imscp-db-keys present in $OLD_ETC/imscp"
    else
        bad "imscp-db-keys looks truncated"
    fi
else
    bad "MISSING $OLD_ETC/imscp/imscp-db-keys - without it every stored password is lost"
fi
for f in imscp/imscp.conf passwd group; do
    [ -f "$OLD_ETC/$f" ] && ok "$OLD_ETC/$f" || bad "missing $OLD_ETC/$f"
done

# --- data volume -----------------------------------------------------------
if dev=$(blkid -U "$DATA_UUID" 2>/dev/null); then
    ok "data volume $DATA_UUID is $dev"
    if findmnt -n --source "$dev" >/dev/null 2>&1; then
        note "currently mounted at $(findmnt -n -o TARGET --source "$dev" | tr '\n' ' ')"
    fi
else
    bad "data volume $DATA_UUID not attached"
fi

# --- uid/gid collisions ----------------------------------------------------
collisions=0
while IFS=: read -r name _ id _; do
    if cur=$(getent group "$id" 2>/dev/null); then
        [ "${cur%%:*}" = "$name" ] || { bad "gid $id wanted by $name, held by ${cur%%:*}"; collisions=1; }
    fi
done < <(awk -F: -v lo="$ID_MIN" -v hi="$ID_MAX" '$3>=lo && $3<=hi' "$OLD_ETC/group" 2>/dev/null)

while IFS=: read -r name _ id _; do
    if cur=$(getent passwd "$id" 2>/dev/null); then
        [ "${cur%%:*}" = "$name" ] || { bad "uid $id wanted by $name, held by ${cur%%:*}"; collisions=1; }
    fi
done < <(awk -F: -v v="$UID_VMAIL" -v lo=1002 -v hi="$ID_MAX" \
           '$3==v || ($3>=lo && $3<=hi)' "$OLD_ETC/passwd" 2>/dev/null)
[ "$collisions" -eq 0 ] && ok "no uid/gid collisions in $UID_VMAIL, $ID_MIN-$ID_MAX"

# --- disk space ------------------------------------------------------------
root_avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "${root_avail:-0}" -ge 20 ]; then
    ok "root filesystem has ${root_avail}G free"
else
    bad "root filesystem has only ${root_avail}G free - the DB restore and packages need room"
fi

# --- packages the alternatives need ----------------------------------------
# apt-get -s rather than apt-cache policy: proftpd-basic is a virtual package
# on Trixie (provided by proftpd-core), so policy reports "Candidate: (none)"
# for something apt installs perfectly well. Simulating is the honest test.
#
# Note also: no `cmd | grep -q` here. grep -q exits on first match, the writer
# takes SIGPIPE, and under `set -o pipefail` that races into a false failure.
for p in mariadb-server proftpd-basic proftpd-mod-mysql proftpd-mod-crypto \
         courier-imap courier-pop courier-authlib-mysql maildrop \
         postfix apache2 nginx-full bind9; do
    if apt-get install -s -q "$p" >/dev/null 2>&1; then
        ok "apt can resolve $p"
    else
        bad "apt cannot resolve $p"
    fi
done

# --- sury, for php7.4 ------------------------------------------------------
if curl -sfI --max-time 15 https://packages.sury.org/php/dists/trixie/Release >/dev/null 2>&1; then
    ok "packages.sury.org reachable (php7.4 for customers)"
else
    warn "could not reach packages.sury.org - the installer adds it itself, but check egress"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    log "Preflight clean. Next: 10-dump-old.sh on aws1."
else
    die "$FAILED check(s) failed - fix before continuing"
fi
