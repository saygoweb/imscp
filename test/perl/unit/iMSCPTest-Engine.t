#!/usr/bin/perl

# iMSCPTest::Engine's status checks, against a stubbed database: an entity the
# engine could not process keeps its error text in its status column, and
# is_ok() must show it even when the engine itself exited 0.

use strict;
use warnings;
use Test::More;
use iMSCPTest::Stub qw/ stub_db stub_method sandbox /;
use iMSCPTest::Engine qw/ run_engine is_ok is_gone /;

my $customer = {
    name => 'c-1.test',
    rows => [
        { table => 'admin', key => 'admin_id', status => 'admin_status', id => 1 },
        { table => 'domain', key => 'domain_id', status => 'domain_status', id => 2 }
    ]
};

my %status;
my $db = stub_db(
    qr/^SELECT `(\w+)` FROM `(\w+)` WHERE `\w+` = \?$/ => sub {
        my ( $sql, $id ) = @_;
        my ( $table ) = $sql =~ /FROM `(\w+)`/;
        exists $status{"$table/$id"} ? [ [ $status{"$table/$id"} ] ] : [];
    },
    qr/^SELECT COUNT\(\*\) FROM `(\w+)` WHERE `\w+` = \?$/ => sub {
        my ( $sql, $id ) = @_;
        my ( $table ) = $sql =~ /FROM `(\w+)`/;
        [ [ exists $status{"$table/$id"} ? 1 : 0 ] ];
    },
);

sub outcome
{
    my ( $check, @args ) = @_;
    my ( @ok, @diag );
    my $okStub = stub_method( 'Test::More', 'ok', sub { push @ok, $_[0] ? 1 : 0; $_[0] } );
    my $diagStub = stub_method( 'Test::More', 'diag', sub { push @diag, @_; 0 } );
    $check->( @args );
    undef $okStub;
    undef $diagStub;
    [ $ok[0], join( "\n", @diag ) ];
}

%status = ( 'admin/1' => 'ok', 'domain/2' => 'ok' );
is_deeply( outcome( \&is_ok, $customer ), [ 1, '' ], 'is_ok passes when every row is ok' );

%status = ( 'admin/1' => 'ok', 'domain/2' => "Couldn't create the zone: named-checkzone failed" );
my $result = outcome( \&is_ok, $customer );
is( $result->[0], 0, 'is_ok fails on an error status' );
like( $result->[1], qr/domain 2: Couldn't create the zone/, 'and shows the error text' );

%status = ( 'admin/1' => 'ok' );
like( outcome( \&is_ok, $customer )->[1], qr/domain 2: no row/, 'a missing row is reported as such' );

%status = ();
is_deeply( outcome( \&is_gone, $customer ), [ 1, '' ], 'is_gone passes when every row is gone' );

%status = ( 'domain/2' => 'todelete' );
$result = outcome( \&is_gone, $customer );
is( $result->[0], 0, 'is_gone fails while a row remains' );
like( $result->[1], qr/domain 2/, 'and names it' );

# run_engine(): the exit status of imscp-rqst-mngr, a signal included.
my $engineDir = sandbox( 'engine' );
sub fake_engine
{
    my ( $code ) = @_;
    open my $fh, '>', "$engineDir/imscp-rqst-mngr" or die "imscp-rqst-mngr: $!";
    print {$fh} "$code\n";
    close $fh;
}
local $ENV{'IMSCP_ENGINE_DIR'} = $engineDir;

fake_engine( 'print "all done\n"; exit 0;' );
is_deeply( outcome( \&run_engine ), [ 1, '' ], 'run_engine passes when the request manager exits 0' );

fake_engine( 'print "it broke\n"; exit 3;' );
$result = outcome( \&run_engine );
is( $result->[0], 0, 'run_engine fails when it exits non-zero' );
like( $result->[1], qr/it broke/, 'and shows its output' );

fake_engine( '$| = 1; print "dying\n"; kill 9, $$; sleep 5;' );
$result = outcome( \&run_engine );
is( $result->[0], 0, 'run_engine fails when the request manager is killed by a signal' );
like( $result->[1], qr/killed by signal 9 \(KILL\)/, 'naming the signal' );
like( $result->[1], qr/dying/, 'and shows its output' );

done_testing();
