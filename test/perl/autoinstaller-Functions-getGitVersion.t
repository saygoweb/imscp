#!/usr/bin/perl

# Tests for autoinstaller::Functions::getGitVersion(), which gives the version
# and build the installer records from the Git checkout it runs from.
#
# Run from the repository root:
#
#   prove -I. -Iengine/PerlLib -Iengine/PerlVendor test/perl

use strict;
use warnings;
use File::Temp qw/ tempdir /;
use Test::More;
use autoinstaller::Functions;

my $tmp = tempdir( 'imscp-gitversion-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

sub git
{
    system( 'git', '-C', $tmp, @_ ) == 0 or die "git @_ failed";
}

sub commit
{
    git( qw/ -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m /, @_ );
    my $sha = `git -C $tmp rev-parse --short HEAD`;
    chomp $sha;
    $sha;
}

is_deeply [ autoinstaller::Functions::getGitVersion( $tmp ) ], [], 'not a Git checkout';

git( qw/ init -q / );
commit( 'first' );
is_deeply [ autoinstaller::Functions::getGitVersion( $tmp ) ], [], 'no version tag';

my $sha = commit( 'tagged' );
git( qw/ tag 1.5.4 / );
is_deeply [ autoinstaller::Functions::getGitVersion( $tmp ) ], [ '1.5.4', $sha ], 'on a version tag';

git( qw{ tag archived/1.1.x } );
$sha = commit( 'after the tag' );
is_deeply [ autoinstaller::Functions::getGitVersion( $tmp ) ], [ '1.5.4', $sha ],
    'past a version tag: the nearest version tag, other tags ignored';

done_testing();
