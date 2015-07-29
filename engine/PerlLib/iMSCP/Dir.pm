=head1 NAME

 iMSCP::Dir - Package providing basic utilities for filesystem (directories handling).

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2015 by Laurent Declercq <l.declercq@nuxwin.com>
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
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package iMSCP::Dir;

use strict;
use warnings;
use File::Copy qw/copy cp move/;
use File::Path qw/make_path remove_tree/;
use File::Spec;
use parent 'Common::Object';

=head1 DESCRIPTION

 Package providing basic utilities for filesystem (directories handling).

=head1 PUBLIC METHODS

=over 4

=item mode($mode)

 Set directory mode

 Param dirmode $mode
 Return int 0 on success or die on failure

=cut

sub mode
{
	my ($self, $mode) = @_;
	defined $mode or die('Missing mode parameter');
	chmod $mode, $self->{'dirname'} or die(sprintf('Could not set mode on %s: %s', $self->{'dirname'}, $!));

	0;
}

=item owner($owner, $group)

 Set directory owner and group

 Param string $owner Owner
 Param string $group Group
 Return int 0 on success, die on failure

=cut

sub owner
{
	my ($self, $owner, $group) = @_;
	defined $owner or die('Missing owner parameter');
	defined $group or die('Missing group parameter');

	my $uid = -1;
	my $gid = -1;
	$uid = scalar getpwnam($owner) unless $owner eq -1;
	$gid = scalar getgrnam($group) unless $group eq -1;

	defined $uid or die(sprintf('Owner parameter refers to an inexistent user: %s', $owner));
	defined $gid or die(sprintf('Group parameter refers to an inexistent group: %s', $group));

	chown $uid, $gid, $self->{'dirname'} or die(sprintf('Could not set owner/group on %s: %s', $self->{'dirname'}, $!));

	0;
}

=item getFiles()

 Get list of files inside directory (only one depth)

 Return array representing list files or die on failure

=cut

sub getFiles
{
	my $self = shift;
	opendir my $dh, $self->{'dirname'} or die(sprintf('Could not open %s: %s', $self->{'dirname'}, $!));
	my @files = grep { -f "$self->{'dirname'}/$_" } File::Spec->no_upwards(readdir($dh));
	($self->{'fileType'}) ? grep(/$self->{'fileType'}$/, @files) : @files;
}

=item getDirs()

 Get list of directories inside directory (only one depth)

 Return array representing list of directories or die on failure

=cut

sub getDirs
{
	my $self = shift;
	opendir my $dh, $self->{'dirname'} or die(sprintf('Could not open %s: %s', $self->{'dirname'}, $!));
	grep (-d "$self->{'dirname'}/$_", File::Spec->no_upwards(readdir($dh)));
}

=item getAll()

 Get list of files and directories inside directory (only one depth)

 Return list of files and directories or die on failure

=cut

sub getAll
{
	my $self = shift;
	opendir my $dh, $self->{'dirname'} or die(sprintf('Could not open %s: %s', $self->{'dirname'}, $!));
	File::Spec->no_upwards(readdir($dh));
}

=item isEmpty()

 Is directory empty?

 Return bool TRUE if the given directory is empty, FALSE otherwise - die on failure

=cut

sub isEmpty
{
	my $self = shift;
	opendir my $dh, $self->{'dirname'} or die(sprintf('Could not open %s: %s', $self->{'dirname'}, $!));

	for my $file(readdir $dh) {
		if($file ne '.' && $file ne '..') {
			return 0;
		}
	}

	1;
}

=item make([ \%options ])

 Create directory

 Param hash \%options OPTIONAL Options:
    mode: Directory octal mode (default: 0755)
    user: Directory owner (default: root)
    group: Directory group (default: root)
 Return int 0 on success, die on failure

=cut

sub make
{
	my ($self, $options) = @_;
	$options = { } unless defined $options && ref $options eq 'HASH';

	unless(-d $self->{'dirname'}) {
		my @dirs = make_path($self->{'dirname'}, {
			error => \my $errStack,
			owner => $options->{'user'},
			group => $options->{'group'},
			mode => 0755
		});

		if(@{$errStack}) {
			my $errorStr = '';
			for my $diag (@{$errStack}) {
				my ($dir, $message) = %{$diag};
				$errorStr .= ($dir eq '') ? "general error: $message\n" : "problem creating $dir: $message\n";
			}

			die(sprintf('Could not create %s: %s', $self->{'dirname'}, $errorStr));
		}

		if(defined $options->{'mode'}) {
			# We set mode separately because make_path doesn't allow to set special modes (e.g: setgid)
			iMSCP::Dir->new( dirname => $_ )->mode($options->{'mode'}) for @dirs;
		}
	} else {
		if(defined $options->{'user'} || defined $options->{'group'}) {
			$self->owner($options->{'user'} // -1, $options->{'group'} // -1);
		}

		$self->mode($options->{'mode'}) if defined $options->{'mode'};
	}

	0;
}

=item remove()

 Remove directory

 Return int 0 on success, die on failure

=cut

sub remove
{
	my $self = shift;

	if (-d $self->{'dirname'}) {
		remove_tree($self->{'dirname'}, { error => \my $errStack });

		if(@{$errStack}) {
			my $errorStr = '';
			for my $diag (@{$errStack}) {
				my ($file, $message) = %{$diag};
				$errorStr .= ($file eq '') ? "general error: $message\n" : "problem unlinking $file: $message\n";
			}

			die(sprintf('Could not delete %s: %s', $self->{'dirname'}, $errorStr));
		}
	}

	0;
}

=item rcopy($destdir [, \%options ])

 Copy content of the directory recursively

 Note: Symlinks are not followed.

 Param string $destdir Destination directory
 Param hash \%options OPTIONAL Options:
   preserve: If true, copy file attributes (uid, gid and mode)
 Return int 0 on success, die on failure

=cut

sub rcopy
{
	my ($self, $destdir, $options) = @_;
	$options = { } unless defined $options && ref $options eq 'HASH';
	defined $destdir or die("Missing destdir parameter");
	opendir my $dh, $self->{'dirname'} or die(sprintf('Could not open %s', $self->{'dirname'}));

	while (readdir $dh) {
		if($_ ne '.' && $_ ne '..') {
			my $src = "$self->{'dirname'}/$_";
			print "Src: $src\n";
			my $target = "$destdir/$_";
			print "Target: $target\n";

			if (-d $src) {
				my $opts = {};
				if($options->{'preserve'}) {
					my (undef, undef, $mode, undef, $uid, $gid) = lstat($src);
					$opts = { user => scalar getpwuid($uid), mode => $mode & 07777, group => scalar getgrgid($gid) }
				}

				iMSCP::Dir->new( dirname => $target )->make($opts);
				iMSCP::Dir->new( dirname => $src )->rcopy($target, $options);
			} else {
				if($options->{'preserve'}) {
					cp($src, $target) or die(sprintf('Could not copy %s to %s: %s', $src, $target, $!));
				} else {
					copy($src, $target) or die(sprintf('Could not copy %s to %s: %s', $src, $target, $!));
				}
			}
		}
	}

	0;
}

=item moveDir($destdir)

 Move directory

 Param string $destdir Destination directory
 Return int 0 on success, die on failure

=cut

sub moveDir
{
	my ($self, $destdir) = @_;
	defined $destdir or die('Missing destdir parameter');
	-d $self->{'dirname'} or die(sprintf("Directory %s doesn't exits", $self->{'dirname'}));
	move $self->{'dirname'}, $destdir or die(sprintf('Could not move %s to %s: %s', $self->{'dirname'}, $destdir, $!));

	0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize object

 iMSCP::Dir

=cut

sub _init
{
	my $self = shift;
	defined $self->{'dirname'} or die('Option dirname is not defined');
	$self;
}

=back

=head1 AUTHOR

Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
