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

# Find preseed file in possible locations
if [ -f /vagrant/preseed.pl ]; then
  PRESEED_FILE="/vagrant/preseed.pl"
elif [ -f /usr/local/src/imscp/Vagrant/preseed.pl ]; then
  PRESEED_FILE="/usr/local/src/imscp/Vagrant/preseed.pl"
else
  echo "The i-MSCP preseed.pl file has not been found. Please create it first."
  exit 1
fi

rm -f /tmp/preseed.pl
head -n -2 "$PRESEED_FILE" > /tmp/preseed.pl
cat <<'EOT' >> /tmp/preseed.pl
$::questions{'BASE_SERVER_IP'} = '0.0.0.0';

1;
__END__
EOT

# Execute the i-MSCP installer using preseeding file
perl /usr/local/src/imscp/imscp-autoinstall --debug --verbose --preseed /tmp/preseed.pl
