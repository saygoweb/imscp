#!/usr/bin/perl

# Servers::named::bind: deleteSub() removes the block addSub() wrote.
#
#   test/run.sh unit
#
# The zone is built from the shipped db.tpl and db_sub.tpl. Events, the address
# checks and zone compilation are stubbed; everything else is the real code
# path, and no command may reach the shell.

use strict;
use warnings;
use Test::More;
use iMSCP::File;
use iMSCP::TemplateParser qw/ process /;
use iMSCPTest::Stub qw/ :all /;

my $tplDir = config_path( 'bind/parts' );
my $wrkDir = sandbox();
my $parent = 'example.test';

{
    # IPv4 documentation addresses only; avoids needing Data::Validate::IP
    package StubNet;
    sub new { bless {}, shift }
    sub getAddrVersion { 'ipv4' }
    sub isRoutableAddr { 1 }
}

my $events = stub_events();
my $exec = stub_execute();
my $net = stub_singleton( 'iMSCP::Net', StubNet->new() );

my $named = new_server(
    'Servers::named::bind',
    config  => { BIND_MODE => 'master' },
    tplDir  => $tplDir,
    wrkDir  => $wrkDir,
    serials => { $parent => 1 },
    reload  => 0
);
my $compile = stub_method( 'Servers::named::bind', '_compileZone', sub { 0 } );

sub zone
{
    iMSCP::File->new( filename => "$wrkDir/$parent.db" )->get();
}

my $zone = process(
    {
        DOMAIN_NAME => $parent,
        IP_TYPE     => 'A',
        DOMAIN_IP   => '192.0.2.1',
        TIMESTAMP   => '2026010101'
    },
    iMSCP::File->new( filename => "$tplDir/db.tpl" )->get()
);
my $file = iMSCP::File->new( filename => "$wrkDir/$parent.db" );
$file->set( $zone );
$file->save() == 0 or die "Couldn't write the test zone\n";

my %sub = (
    DOMAIN_NAME           => "sub.$parent",
    PARENT_DOMAIN_NAME    => $parent,
    DOMAIN_IP             => '192.0.2.10',
    BASE_SERVER_PUBLIC_IP => '192.0.2.1',
    MAIL_ENABLED          => 1
);
my %other = ( %sub, DOMAIN_NAME => "other.$parent", MAIL_ENABLED => 0 );

is( $named->addSub( \%sub ), 0, 'addSub succeeds' );
is( $named->addSub( \%other ), 0, 'addSub succeeds for a second subdomain' );
like(
    zone(),
    qr/^; subdomain \[sub\.example\.test\] records BEGIN$/m,
    'addSub writes the subdomain block'
);

is( $named->deleteSub( \%sub ), 0, 'deleteSub succeeds' );
my $after = zone();
unlike( $after, qr/sub\.example\.test/, 'deleteSub removes the subdomain block' );
like(
    $after,
    qr/^; subdomain \[other\.example\.test\] records BEGIN\n\$ORIGIN other\.example\.test\.\n.*?^; subdomain \[other\.example\.test\] records ENDING\n/ms,
    'deleteSub leaves the other subdomain block alone'
);
like(
    $after,
    qr/^; subdomain \[\{SUBDOMAIN_NAME\}\] records BEGIN\n; subdomain \[\{SUBDOMAIN_NAME\}\] records ENDING$/m,
    'deleteSub leaves the insertion point for the next subdomain'
);
is_deeply( [ $exec->commands ], [], 'no command reached the shell' );

done_testing();
