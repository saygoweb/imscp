#!/usr/bin/perl

# test/run.sh: what it runs, from wherever it is started, and what it refuses.

use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Temp qw/ tempdir /;
use Test::More;

my $run = "$FindBin::Bin/../run.sh";
my $dir = tempdir( CLEANUP => 1 );

sub spit
{
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $content;
    close $fh;
}

spit( "$dir/pass.t", "use Test::More; pass( 'passes' ); done_testing();\n" );
spit( "$dir/fail.t", "use Test::More; fail( 'fails' ); done_testing();\n" );
mkdir "$dir/sub" or die "mkdir: $!";
spit( "$dir/sub/rel.t", "use Test::More; pass( 'relative' ); done_testing();\n" );

my $out = `cd '$dir' && sh '$run' unit '$dir/pass.t' 2>&1`;
is( $? >> 8, 0, 'unit runs the named file, started from another directory' ) or diag( $out );

$out = `cd '$dir/sub' && sh '$run' unit rel.t 2>&1`;
is( $? >> 8, 0, 'unit resolves a relative test path against the caller\'s directory' ) or diag( $out );

$out = `sh '$run' unit '$dir/fail.t' 2>&1`;
is( $? >> 8, 1, 'unit exits 1 when a test fails' ) or diag( $out );

$out = `sh '$run' nonsense 2>&1`;
is( $? >> 8, 2, 'an unknown command exits 2' );
like( $out, qr/usage/i, 'and prints the usage' );

my $relative = File::Spec->abs2rel( $run, "$dir/sub" );
$out = `cd '$dir/sub' && sh '$relative' bogus 2>&1`;
is( $? >> 8, 2, 'an unknown command exits 2 from a subdirectory, the script named by a relative path' );
like( $out, qr{test/run\.sh unit}, 'and the usage is read out of the script' );

SKIP: {
    skip 'Devel::Cover is not installed', 2 unless eval { require Devel::Cover; 1 };
    $out = `cd '$dir/sub' && COVER_DIR=cov sh '$run' unit --cover rel.t 2>&1`;
    is( $? >> 8, 0, 'unit --cover runs with a relative COVER_DIR' ) or diag( $out );
    ok( -d "$dir/sub/cov", 'and writes it under the caller\'s directory' );
}

SKIP: {
    skip 'Devel::Cover is not installed', 5 unless eval { require Devel::Cover; 1 };
    # A bind mount cannot be removed: the directory stays, emptied.
    mkdir "$dir/mount" or die "mkdir: $!";
    spit( "$dir/mount/stale", "old\n" );
    $out = `COVER_DIR='$dir/mount' sh '$run' unit --cover '$dir/pass.t' 2>&1`;
    is( $? >> 8, 0, 'unit --cover runs with a COVER_DIR that already holds files' ) or diag( $out );
    ok( !-e "$dir/mount/stale", 'and empties it' );
    ok( -d "$dir/mount", 'but keeps the directory itself' );
    ok( -f "$dir/mount/html/coverage.html", 'and writes the HTML report there' );
    unlike( $out, qr/invalid database/, 'beside the database, not inside it' );
}

SKIP: {
    skip 'this host is a CI image', 2 if -e '/etc/imscp/ci-image';
    $out = `sh '$run' integration 2>&1`;
    is( $? >> 8, 2, 'integration refuses to run off the CI image' );
    like( $out, qr{/etc/imscp/ci-image}, 'and names the marker it looked for' );
}

# `all` passes its arguments to the unit run. A unit failure ends it with 1;
# otherwise the exit status is the integration run's own.
$out = `sh '$run' all '$dir/fail.t' 2>&1`;
is( $? >> 8, 1, 'all exits 1 when the unit run fails' );
unlike( $out, qr/ci-image/, 'and does not go on to integration' );

SKIP: {
    skip 'this host is a CI image', 2 if -e '/etc/imscp/ci-image';
    $out = `sh '$run' all '$dir/pass.t' 2>&1`;
    is( $? >> 8, 2, 'all exits 2 when integration refuses after a passing unit run' );
    like( $out, qr/pass\.t/, 'having run the unit file it was given' );
}

done_testing();
