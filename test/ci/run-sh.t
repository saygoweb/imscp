#!/usr/bin/perl

# test/run.sh: what it runs, from wherever it is started, and what it refuses.

use strict;
use warnings;
use FindBin;
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

my $out = `cd '$dir' && sh '$run' unit '$dir/pass.t' 2>&1`;
is( $? >> 8, 0, 'unit runs the named file, started from another directory' ) or diag( $out );

$out = `sh '$run' unit '$dir/fail.t' 2>&1`;
is( $? >> 8, 1, 'unit exits 1 when a test fails' ) or diag( $out );

$out = `sh '$run' nonsense 2>&1`;
is( $? >> 8, 2, 'an unknown command exits 2' );
like( $out, qr/usage/i, 'and prints the usage' );

SKIP: {
    skip 'this host is a CI image', 2 if -e '/etc/imscp/ci-image';
    $out = `sh '$run' integration 2>&1`;
    is( $? >> 8, 2, 'integration refuses to run off the CI image' );
    like( $out, qr{/etc/imscp/ci-image}, 'and names the marker it looked for' );
}

done_testing();
