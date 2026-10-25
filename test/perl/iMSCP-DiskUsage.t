#!/usr/bin/perl

# Unit tests for iMSCP::DiskUsage, the du output parsing behind imscp-dsk-quota.
#
# Run from the repository root:
#
#   prove -Iengine/PerlLib -Iengine/PerlVendor test/perl

use strict;
use warnings;
use Test::More;
use iMSCP::DiskUsage;

my $dir = '/var/mail/virtual/example.com';

subtest 'several mailboxes and the domain total' => sub {
    my $out = "4096\t$dir/john\n1048576\t$dir/john.doe\n12288\t$dir/info\n1069056\t$dir\n";
    my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1( $out, $dir );
    is $total, 1069056, 'total is the line for the domain directory itself';
    is_deeply $byAcc, { john => 4096, 'john.doe' => 1048576, info => 12288 }, 'one entry per mailbox directory';
};

subtest 'trailing slash on the domain directory' => sub {
    my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1( "10\t$dir/a\n20\t$dir\n", "$dir/" );
    is $total, 20;
    is_deeply $byAcc, { a => 10 };
};

subtest 'empty output' => sub {
    my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1( '', $dir );
    is $total, 0;
    is_deeply $byAcc, {};
};

subtest 'partial output from a failed du still yields what was printed' => sub {
    my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1( "10\t$dir/a\n", $dir );
    is $total, 10, 'without a total line, the total is the sum of the children';
    is_deeply $byAcc, { a => 10 };
};

subtest 'lines outside the domain directory are ignored' => sub {
    my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1(
        "5\t/var/mail/virtual/other.com/x\n10\t$dir/a\n10\t$dir\n", $dir
    );
    is $total, 10;
    is_deeply $byAcc, { a => 10 };
};

subtest 'mapping to mail addresses' => sub {
    my $map = iMSCP::DiskUsage::mapMailboxUsage(
        'example.com',
        { john => 4096, 'john.doe' => 1048576, leftover => 999 },
        [ 'john@example.com', 'john.doe@example.com', 'new@example.com', 'a@sub.example.com', 'b@other.com' ]
    );
    is_deeply $map, {
        'john@example.com'     => 4096,
        'john.doe@example.com' => 1048576,
        'new@example.com'      => 0,
    }, 'mailboxes of this domain only; no directory means 0; leftover directories are not mapped';
};

subtest 'mapping ignores case in the domain part' => sub {
    my $map = iMSCP::DiskUsage::mapMailboxUsage( 'Example.com', { a => 1 }, [ 'a@example.COM' ] );
    is_deeply $map, { 'a@example.COM' => 1 };
};

done_testing();
