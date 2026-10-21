#!/usr/bin/perl

# named: a customer's domain and subdomain are served by the DNS server once
# the engine has added them, and stop being served once it has deleted them.
# Through the real request pipeline, on the CI image only:
#
#   docker/ci/engine-test.sh -- integration test/perl/integration/named.t

use strict;
use warnings;
use Net::DNS;
use Test::More;
use iMSCPTest::Engine qw/ boot_engine run_engine is_ok is_gone /;
use iMSCPTest::Fixture qw/ customer subdomain schedule /;

boot_engine();
require Servers::named;
my $zoneDir = Servers::named->factory()->{'config'}->{'BIND_DB_MASTER_DIR'};

my $resolver = Net::DNS::Resolver->new(
    nameservers => [ '127.0.0.1' ], recurse => 0, udp_timeout => 2, retry => 1
);

# The engine reloads the server as it finishes, and named loads zones in the
# background, so give it a few seconds either way.
#
# undef when the server does not answer at all, which is not the same as
# answering without an A record: a stopped or broken named must not look like
# a name that is no longer served.
sub a_records
{
    my ( $name ) = @_;

    my $reply = $resolver->send( $name, 'A' ) or return undef;
    [ map { $_->address } grep { $_->type eq 'A' } $reply->answer ];
}

sub served
{
    my $records = a_records( @_ );
    $records && @{ $records } ? @{ $records } : ();
}

sub eventually
{
    my ( $test ) = @_;

    for ( 1 .. 10 ) {
        return 1 if $test->();
        sleep 1;
    }
    0;
}

my $customer = customer( label => 'named' );
my $sub = subdomain( $customer, 'sub' );

run_engine() or BAIL_OUT( 'the engine could not add the customer' );
is_ok( $customer );
is_ok( $sub );
ok( -f "$zoneDir/$customer->{'name'}.db", 'the zone file is written' );

ok( eventually( sub { served( $customer->{'name'} ) } ), "$customer->{'name'} answers an A record" );
my @domainA = served( $customer->{'name'} );
ok( eventually( sub { served( $sub->{'name'} ) } ), "$sub->{'name'} answers an A record" );
is_deeply( [ served( $sub->{'name'} ) ], \@domainA, 'at the domain\'s address' );

schedule( $_, 'todelete' ) for $sub, $customer;
run_engine() or BAIL_OUT( 'the engine could not delete the customer' );
is_gone( $sub );
is_gone( $customer );
ok( !-e "$zoneDir/$customer->{'name'}.db", 'the zone file is removed' );
ok( eventually( sub { my $records = a_records( $customer->{'name'} ); $records && !@{ $records } } ),
    'the server answers, and no longer serves the domain' );

done_testing();
