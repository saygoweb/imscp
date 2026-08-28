#!/usr/bin/env bash
#
# Mounts the customer data volume and recreates the mail symlink.
# Idempotent. DRY_RUN=1 to preview.
#
cd "$(dirname "$0")" && . ./lib.sh
need_root

log "Data volume $DATA_UUID -> $DATA_MNT"

dev=$(blkid -U "$DATA_UUID") || die "volume $DATA_UUID not attached"
note "device: $dev"

# Release the read-only inspection mount if one is in the way
if mountpoint -q /mnt/olddata 2>/dev/null; then
    log "Releasing inspection mount at /mnt/olddata"
    run umount /mnt/olddata
    run rmdir /mnt/olddata
fi

run mkdir -p "$DATA_MNT"

# fstab: nofail so a detached volume cannot strand the box at boot, and pass 2
# rather than aws1's 1 - only the root filesystem should be pass 1.
line="UUID=$DATA_UUID $DATA_MNT ext4 defaults,nofail 0 2"
if grep -q "$DATA_UUID" /etc/fstab; then
    note "fstab already references the volume, leaving it alone"
else
    log "Adding fstab entry"
    note "$line"
    run cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
    if [ "${DRY_RUN:-0}" != "1" ]; then printf '%s\n' "$line" >> /etc/fstab; fi
fi

run systemctl daemon-reload
mountpoint -q "$DATA_MNT" || run mount "$DATA_MNT"

# The mail store lives inside the volume; /var/mail/virtual is a symlink to it,
# exactly as on aws1:
#   virtual -> /var/www/virtual/_mail/virtual
log "Mail symlink $MAIL_LINK -> $MAIL_TARGET"
run mkdir -p /var/mail
if [ -L "$MAIL_LINK" ]; then
    cur=$(readlink "$MAIL_LINK")
    [ "$cur" = "$MAIL_TARGET" ] && note "already correct" \
        || die "$MAIL_LINK points at $cur, expected $MAIL_TARGET"
elif [ -e "$MAIL_LINK" ]; then
    die "$MAIL_LINK exists and is not a symlink - inspect before continuing"
else
    run ln -s "$MAIL_TARGET" "$MAIL_LINK"
fi

if [ "${DRY_RUN:-0}" != "1" ]; then
    echo
    df -h "$DATA_MNT"
    [ -d "$MAIL_TARGET" ] && ok "mail store reachable: $(ls "$MAIL_TARGET" | wc -l) domains" \
                          || bad "$MAIL_TARGET not found on the volume"
fi
