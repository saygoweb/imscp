#!/bin/sh
# Install i-MSCP inside the running container, from the mounted checkout.
#
# The equivalent of ../Vagrant/scripts/distro_update.sh and
# ../Vagrant/scripts/provision_imscp.sh rolled together, with the differences a
# container forces:
#
#   * The installer is run from /var/www/imscp-git (the bind mount) rather than
#     from a copy, so it installs exactly the tree you are editing.
#   * The preseed file is docker/preseed.pl in that checkout, which reads its
#     values from the environment rather than needing to be edited.
#   * Afterwards the installed tree is linked back to the checkout by
#     link-dev-tree.sh, which is where the development part actually happens.
#
# Called by `docker/imscp install`. Expect 20-40 minutes on a first run: it is a
# full hosting stack coming down from the Debian and sury archives.

set -eu

GIT_ROOT="${IMSCP_GIT_ROOT:-/var/www/imscp-git}"
PRESEED="${IMSCP_PRESEED:-$GIT_ROOT/docker/preseed.pl}"
HERE="$(dirname "$0")"

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

log() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\ninstall-imscp: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -f "$GIT_ROOT/imscp-autoinstall" ] || die "$GIT_ROOT does not look like an i-MSCP checkout"
[ -f "$PRESEED" ] || die "preseed file $PRESEED not found"

log "waiting for systemd to finish booting"
i=0
while ! systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; do
    i=$(( i + 1 ))
    [ "$i" -gt 60 ] && die "systemd did not finish booting; try 'docker/imscp journal'"
    sleep 2
done

# DebianAdapter::preinstall runs `apt-get --simulate dist-upgrade` and aborts
# the whole install if anything is still pending, so the distribution has to be
# brought fully up to date first. The image did this at build time, but the
# archives will have moved on since.
log "bringing the distribution up to date"
apt-get update
apt-get --assume-yes dist-upgrade
apt-get --assume-yes install ca-certificates perl
dpkg --configure -a

# Not a fresh install: take the links down so the installer only ever sees real
# directories under /var/www/imscp.
if [ -f /etc/imscp/imscp.conf ]; then
    log "removing development links before reinstalling"
    sh "$HERE/unlink-dev-tree.sh"
fi

log "running the i-MSCP installer"
# --noprompt with --preseed is what makes this unattended; --debug --verbose
# make the transcript worth keeping when something fails halfway through.
cd "$GIT_ROOT"
perl ./imscp-autoinstall --debug --verbose --noprompt --preseed "$PRESEED" "$@"

log "linking the installed tree back to the checkout"
sh "$HERE/link-dev-tree.sh"

log "i-MSCP installed"
