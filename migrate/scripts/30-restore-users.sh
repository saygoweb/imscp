#!/usr/bin/env bash
#
# Recreates aws1's accounts with their ORIGINAL names and numeric ids, before
# the i-MSCP installer runs.
#
# Why this is not optional: the 199 GB of customer data is owned by uid
# 1003-1196. SYSTEM_USER_MIN_UID (2000) is a *username* offset, not a uid
# floor - Modules/User.pm:111 builds the name as
# SYSTEM_USER_PREFIX . (SYSTEM_USER_MIN_UID + admin_id), and the uid is
# whatever useradd allocates. Pre-creating the accounts makes
# Modules/User.pm:120 find them by uid and fall through to a no-op usermod
# instead of allocating fresh numbers.
#
# Every aws1 vu account is password-locked, so no shadow hashes are carried.
# Idempotent. DRY_RUN=1 to preview.
#
cd "$(dirname "$0")" && . ./lib.sh
need_root
need_old_etc

created_g=0 created_u=0 skipped=0

log "Groups (gid $ID_MIN-$ID_MAX) from $OLD_ETC/group"
while IFS=: read -r name _ gid members; do
    if cur=$(getent group "$gid" 2>/dev/null); then
        if [ "${cur%%:*}" = "$name" ]; then skipped=$((skipped+1)); continue; fi
        die "gid $gid wanted by '$name' but held by '${cur%%:*}' - resolve manually"
    fi
    getent group "$name" >/dev/null && die "group '$name' exists with the wrong gid"
    run groupadd -g "$gid" "$name"
    created_g=$((created_g+1))
done < <(awk -F: -v lo="$ID_MIN" -v hi="$ID_MAX" '$3>=lo && $3<=hi' "$OLD_ETC/group")
note "created $created_g, already correct $skipped"

skipped=0
log "Users (vmail $UID_VMAIL, imscp 1002, vu 1003-$ID_MAX) from $OLD_ETC/passwd"
while IFS=: read -r name _ uid gid gecos home shell; do
    if cur=$(getent passwd "$uid" 2>/dev/null); then
        if [ "${cur%%:*}" = "$name" ]; then skipped=$((skipped+1)); continue; fi
        die "uid $uid wanted by '$name' but held by '${cur%%:*}' - resolve manually"
    fi
    getent passwd "$name" >/dev/null && die "user '$name' exists with the wrong uid"
    if ! getent group "$gid" >/dev/null; then
        # Under DRY_RUN the groups above were only printed, so accept a gid
        # that the group pass would have created.
        if [ "${DRY_RUN:-0}" = "1" ] \
           && awk -F: -v g="$gid" '$3==g {found=1} END {exit !found}' "$OLD_ETC/group"; then
            :
        else
            die "gid $gid for '$name' does not exist - run the group pass first"
        fi
    fi

    # -M: the home directories already exist on the data volume and must not
    # be recreated or reskeletoned.
    run useradd -u "$uid" -g "$gid" -d "$home" -s "$shell" -M -c "$gecos" "$name"
    run passwd -l "$name" >/dev/null 2>&1 || true
    created_u=$((created_u+1))
done < <(awk -F: -v v="$UID_VMAIL" -v hi="$ID_MAX" \
           '$3==v || ($3>=1002 && $3<=hi)' "$OLD_ETC/passwd")
note "created $created_u, already correct $skipped"

# Supplementary memberships carry real meaning: vu2000 is in 'mail' and
# 'imscp' so the panel can read maildirsize files for realtime quota, and
# every vu group contains www-data.
log "Supplementary group memberships"
added=0
while IFS=: read -r gname _ _ members; do
    [ -n "$members" ] || continue
    getent group "$gname" >/dev/null || continue
    IFS=, read -ra list <<< "$members"
    for m in "${list[@]}"; do
        [ -n "$m" ] || continue
        getent passwd "$m" >/dev/null || continue
        # No pipeline: `... | grep -q` early-exits and SIGPIPEs the writer,
        # which `set -o pipefail` reports as failure.
        current=" $(id -nG "$m" 2>/dev/null || true) "
        case "$current" in *" $gname "*) continue ;; esac
        run gpasswd -a "$m" "$gname" >/dev/null
        added=$((added+1))
    done
done < "$OLD_ETC/group"
note "added $added membership(s)"

if [ "${DRY_RUN:-0}" != "1" ]; then
    echo
    log "Verification"
    FAILED=0
    for probe in "1005 vu2006" "999 vmail" "1002 imscp"; do
        set -- $probe
        got=$(getent passwd "$1" | cut -d: -f1 || true)
        [ "$got" = "$2" ] && ok "uid $1 = $2" || bad "uid $1 = '${got:-none}', expected $2"
    done
    if [ -d "$DATA_MNT" ]; then
        orphans=$(find "$DATA_MNT" -maxdepth 1 -nouser -o -maxdepth 1 -nogroup 2>/dev/null | head -5)
        [ -z "$orphans" ] && ok "no unowned entries at the top of $DATA_MNT" \
                          || bad "unowned: $(echo "$orphans" | tr '\n' ' ')"
    else
        warn "$DATA_MNT not mounted - run 20-mount-data.sh and re-check"
    fi
    [ "${FAILED:-0}" -eq 0 ] || die "verification failed"
fi
