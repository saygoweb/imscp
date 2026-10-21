#!/usr/bin/perl

# docker/ci/prune-images.sh decides what to delete from ghcr.io/saygoweb/imscp-ci.
# Tried on made-up versions through the script's own PRUNE_VERSIONS_FILE and
# PRUNE_OPEN_PRS stand-ins, so no token or network is needed:
#
#   test/run.sh ci

use strict;
use warnings;
use FindBin;
use File::Temp qw/ tempfile /;
use JSON::PP;
use Test::More;

plan skip_all => 'needs jq' unless system( 'jq --version >/dev/null 2>&1' ) == 0;

my $script = "$FindBin::Bin/../../docker/ci/prune-images.sh";

# [ id, created_at, tags ]
my @versions = (
    [ 1, '2026-01-01T00:00:00Z', [ 'bookworm' ] ],
    [ 2, '2026-10-20T00:00:00Z', [ 'trixie', 'trixie-aaaaaaa' ] ],
    [ 3, '2026-10-01T00:00:00Z', [ 'trixie-1111111' ] ],
    [ 4, '2026-10-02T00:00:00Z', [ 'trixie-2222222' ] ],
    [ 5, '2026-10-03T00:00:00Z', [ 'trixie-3333333' ] ],
    [ 6, '2026-10-04T00:00:00Z', [ 'trixie-4444444' ] ],
    [ 7, '2026-10-05T00:00:00Z', [ 'trixie-5555555' ] ],
    [ 8, '2026-01-02T00:00:00Z', [ 'bookworm-8888888' ] ],
    [ 9, '2026-01-03T00:00:00Z', [ 'bookworm-9999999' ] ],
    [ 10, '2026-01-04T00:00:00Z', [ 'bookworm-aaaaaa0' ] ],
    [ 11, '2026-01-05T00:00:00Z', [ 'bookworm-bbbbbb0' ] ],
    [ 12, '2026-10-06T00:00:00Z', [ 'pr-12' ] ],
    [ 13, '2026-10-07T00:00:00Z', [ 'pr-17' ] ],
    [ 14, '2026-10-08T00:00:00Z', [] ],
    [ 15, '2026-10-09T00:00:00Z', [ 'pr-1234567' ] ],
    [ 16, '2026-10-10T00:00:00Z', [ 'trixie-20261021' ] ],
);

my ( $fh, $file ) = tempfile( UNLINK => 1 );
print $fh encode_json( [
    map { { id => $_->[0], created_at => $_->[1], metadata => { container => { tags => $_->[2] } } } } @versions
] );
close $fh;

sub doomed
{
    my ( @args ) = @_;
    my $out = `PRUNE_VERSIONS_FILE='$file' PRUNE_OPEN_PRS='17' '$script' --dry-run @args 2>&1`;
    is( $? >> 8, 0, "prune-images.sh @args exits 0" ) or diag( $out );
    [ sort { $a <=> $b } $out =~ /^would delete (\d+) /mg ];
}

is_deeply(
    doomed(),
    [ 3, 4, 8, 12, 14, 15 ],
    'keeps the bare suite tags, the newest three <suite>-<sha> of each suite and open PRs'
);
is_deeply( doomed( '--keep', 1 ), [ 3, 4, 5, 6, 8, 9, 10, 12, 14, 15 ], '--keep counts per suite' );
is_deeply( doomed( '--pr', 12 ), [ 12 ], '--pr deletes that pull request\'s image only' );

done_testing();
