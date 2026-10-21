#!/usr/bin/perl

# Regression tests for iMSCP::File::copyFile(), one per destination shape.
#
# Run from the repository root:
#
#   test/run.sh unit
#
# Runs as an ordinary user: ownership is preserved to the caller's own uid and
# gid, which lchown() allows without privileges.

use strict;
use warnings;
use Test::More;
use iMSCP::Debug qw/ getMessageByType /;
use iMSCP::File;
use iMSCPTest::Stub qw/ sandbox /;

# Record which paths copyFile() hands to lchown(): run unprivileged, it can
# only chown to our own ids, which changes nothing that could be checked.
# Lchown (libLchown-perl) is on every i-MSCP box but not necessarily where the
# tests run; without it, stand in with chown() for anything but a symlink.
my @lchowned;
{
    no warnings 'redefine';
    my $real = eval { require Lchown; \&Lchown::lchown };
    $INC{'Lchown.pm'} //= __FILE__;
    *Lchown::lchown = sub {
        my ( $uid, $gid, @paths ) = @_;
        push @lchowned, @paths;
        return $real->( $uid, $gid, @paths ) if $real;
        scalar grep { -l $_ || chown( $uid, $gid, $_ ) } @paths;
    };
}

my $tmp = sandbox();

sub mode { sprintf( '%04o', ( lstat( shift ) )[2] & 07777 ) }

sub spit
{
    my ( $path, $content, $mode ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $content;
    close $fh;
    chmod $mode, $path if defined $mode;
}

sub slurp
{
    my $path = shift;
    open my $fh, '<', $path or return undef;
    local $/;
    <$fh>;
}

sub copyFile
{
    my ( $src, $dst, $options ) = @_;
    @lchowned = ();
    my $rs = iMSCP::File->new( filename => $src )->copyFile( $dst, $options );
    diag( getMessageByType( 'error', { amount => 1, remove => 1 } )) if $rs;
    $rs;
}

my $n = 0;
sub case { my $d = "$tmp/" . ++$n; mkdir $d or die $!; $d }

subtest 'regular file into a directory' => sub {
    my $d = case();
    spit( "$d/f", "content\n", 0640 );
    mkdir "$d/dir" or die $!;
    chmod 0755, "$d/dir";

    is( copyFile( "$d/f", "$d/dir" ), 0, 'copyFile() succeeds' );
    is( mode( "$d/dir" ), '0755', 'directory mode is left alone' );
    chmod 0755, "$d/dir";
    ok( -f "$d/dir/f" && !-l "$d/dir/f", 'file lands inside the directory' );
    is( slurp( "$d/dir/f" ), "content\n", 'file content is copied' );
    is( mode( "$d/dir/f" ), '0640', 'source mode is applied to the copied file' );
    is_deeply( \@lchowned, [ "$d/dir/f" ], 'ownership is applied to the copied file' );
};

subtest 'regular file into a directory, preserve => no' => sub {
    my $d = case();
    spit( "$d/f", "content\n", 0640 );
    mkdir "$d/dir" or die $!;
    chmod 0755, "$d/dir";

    is( copyFile( "$d/f", "$d/dir", { preserve => 'no' } ), 0, 'copyFile() succeeds' );
    is( mode( "$d/dir" ), '0755', 'directory mode is left alone' );
    is( slurp( "$d/dir/f" ), "content\n", 'file lands inside the directory' );
};

subtest 'symlink into a directory' => sub {
    my $d = case();
    symlink 'target', "$d/lnk" or die $!;
    mkdir "$d/dir" or die $!;
    chmod 0755, "$d/dir";

    is( copyFile( "$d/lnk", "$d/dir" ), 0, 'copyFile() succeeds' );
    ok( -d "$d/dir" && !-l "$d/dir", 'directory is still a directory' );
    is( mode( "$d/dir" ), '0755', 'directory mode is left alone' );
    ok( -l "$d/dir/lnk", 'symlink lands inside the directory' );
    is( readlink( "$d/dir/lnk" ), 'target', 'symlink target is copied' );
    is_deeply( \@lchowned, [ "$d/dir/lnk" ], 'ownership is applied to the copied symlink' );
};

subtest 'symlink over a symlink to a directory (#24)' => sub {
    my $d = case();
    mkdir "$d/realdir" or die $!;
    symlink 'realdir', "$d/lnk" or die $!;
    mkdir "$d/stage" or die $!;
    symlink '../realdir', "$d/stage/lnk" or die $!;

    is( copyFile( "$d/lnk", "$d/stage/lnk" ), 0, 'copyFile() succeeds' );
    ok( -l "$d/stage/lnk", 'destination is still a symlink' );
    is( readlink( "$d/stage/lnk" ), 'realdir', 'destination symlink is replaced' );
    is_deeply( \@lchowned, [ "$d/stage/lnk" ], 'ownership is applied to the replaced symlink' );
    ok( !-e "$d/realdir/lnk" && !-l "$d/realdir/lnk", 'nothing is created inside the linked directory' );
};

subtest 'symlink over a symlink to a file' => sub {
    my $d = case();
    spit( "$d/file", "x\n" );
    symlink 'new', "$d/lnk" or die $!;
    symlink 'file', "$d/dst" or die $!;

    is( copyFile( "$d/lnk", "$d/dst" ), 0, 'copyFile() succeeds' );
    is( readlink( "$d/dst" ), 'new', 'destination symlink is replaced' );
};

subtest 'regular file over a symlink (9d1bcdae0)' => sub {
    my $d = case();
    spit( "$d/f", "ours\n", 0644 );
    spit( "$d/packaged", "theirs\n", 0600 );
    symlink 'packaged', "$d/dst" or die $!;

    is( copyFile( "$d/f", "$d/dst" ), 0, 'copyFile() succeeds' );
    ok( -f "$d/dst" && !-l "$d/dst", 'destination is now a real file' );
    is( slurp( "$d/dst" ), "ours\n", 'destination has the source content' );
    is( slurp( "$d/packaged" ), "theirs\n", 'former link target is untouched' );
    is( mode( "$d/packaged" ), '0600', 'former link target mode is untouched' );
    is( mode( "$d/dst" ), '0644', 'source mode is applied to the destination' );
};

subtest 'regular file to a full path' => sub {
    my $d = case();
    spit( "$d/f", "content\n", 0600 );

    is( copyFile( "$d/f", "$d/g" ), 0, 'copyFile() succeeds' );
    is( slurp( "$d/g" ), "content\n", 'file is copied' );
    is( mode( "$d/g" ), '0600', 'source mode is applied' );
};

done_testing();
