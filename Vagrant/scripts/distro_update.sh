#!/bin/sh
# i-MSCP - internet Multi Server Control Panel
# Copyright 2010-2019 by Laurent Declercq <l.declercq@nuxwin.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

set -e

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# Remove unwanted foreign i386 architecture which is enabled in
# some Vagrant boxes
dpkg --remove-architecture i386 2>/dev/null || true

# Debian's grub-pc upgrade asks which devices to install GRUB to whenever the
# device list recorded in the box image no longer matches the disks exposed by
# the provider (/dev/vda under libvirt/virtio vs /dev/sda under VirtualBox).
# Under a noninteractive frontend that prompt is a hard failure, so answer it
# up front with whichever disk currently carries the root filesystem.
BOOT_DISK="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -n 1)"
if [ -n "$BOOT_DISK" ]; then
    echo "grub-pc grub-pc/install_devices multiselect /dev/$BOOT_DISK" \
        | debconf-set-selections
    echo "grub-pc grub-pc/install_devices_disks_changed multiselect /dev/$BOOT_DISK" \
        | debconf-set-selections
fi

# Recover from an earlier run that was interrupted by that prompt
dpkg --configure -a

apt-get update
apt-get --assume-yes dist-upgrade
apt-get --assume-yes install ca-certificates perl
