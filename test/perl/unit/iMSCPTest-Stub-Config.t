#!/usr/bin/perl

# iMSCPTest::Stub::Config: the shipped configuration files, for the suite
# production runs, as the code under test would read them.

use strict;
use warnings;
use Test::More;
use iMSCPTest::Stub::Config qw/ repo_root config_path stub_config server_config /;

ok( -f repo_root() . '/engine/imscp-rqst-mngr', 'repo_root() is the checkout' );
is( config_path( 'bind/parts/db.tpl' ), repo_root() . '/configs/debian/trixie/bind/parts/db.tpl', 'config_path() prefers the suite' );
is( config_path( 'cron' ), repo_root() . '/configs/debian/default/cron', 'and falls back to default' );
ok( !eval { config_path( 'no/such/file' ); 1 }, 'and dies for a file that is shipped nowhere' );

{
    local $ENV{'IMSCP_TEST_SUITE'} = 'bookworm';
    is( config_path( 'imscp.conf' ), repo_root() . '/configs/debian/bookworm/imscp.conf', 'IMSCP_TEST_SUITE picks another suite' );
}

%main::imscpConfig = ( BEFORE => 1 );
{
    my $config = stub_config( DEBUG => 1 );
    ok( exists $main::imscpConfig{'CONF_DIR'}, 'stub_config() loads the shipped imscp.conf' );
    is( $main::imscpConfig{'DEBUG'}, 1, 'with the overrides on top' );
    ok( !exists $main::imscpConfig{'BEFORE'}, 'and nothing left from before' );
}
is_deeply( \%main::imscpConfig, { BEFORE => 1 }, 'the old configuration comes back' );

{
    package TestTie;
    require Tie::Hash;
    our @ISA = 'Tie::StdHash';
}
{
    %main::imscpConfig = ();
    my $object = tie %main::imscpConfig, 'TestTie';
    $main::imscpConfig{'TIED'} = 1;
    {
        my $config = stub_config( DEBUG => 1 );
        ok( !tied %main::imscpConfig, 'a tied configuration is untied while stubbed' );
    }
    is( tied %main::imscpConfig, $object, 'and tied to the same object afterwards' );
    is( $main::imscpConfig{'TIED'}, 1, 'with its contents' );
    undef $object;
    untie %main::imscpConfig;
    %main::imscpConfig = ( BEFORE => 1 );
}

my $bind = server_config( 'bind', BIND_MODE => 'master' );
is( $bind->{'BIND_DB_MASTER_DIR'}, '/var/cache/bind/imscp/master', 'server_config() reads the server\'s .data.dist' );
is( $bind->{'BIND_MODE'}, 'master', 'with the overrides on top' );

like( ( eval { stub_config(); 1 } ? '' : $@ ), qr/keep it/, 'a guard thrown away at once is refused' );

done_testing();
