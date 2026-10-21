#!/usr/bin/perl

# Servers::named::bind: deleteSub() removes the block addSub() wrote.
#
# Runs from the repository root without an installed server:
#
#   prove -Iengine/PerlLib -Iengine/PerlVendor test/perl
#
# The zone is built from the shipped db.tpl and db_sub.tpl. Events and zone
# compilation are stubbed; everything else is the real code path.

use strict;
use warnings;
use FindBin;
use File::Temp qw/ tempdir /;
use Test::More;
use iMSCP::File;
use iMSCP::TemplateParser qw/ process /;
use Servers::named::bind;

my $tplDir = "$FindBin::Bin/../../configs/debian/default/bind/parts";
my $wrkDir = tempdir( CLEANUP => 1 );
my $parent = 'example.test';

{
    package StubEvents;
    sub new { bless {}, shift }
    sub trigger { 0 }
}

{
    # IPv4 documentation addresses only; avoids needing Data::Validate::IP
    package StubNet;
    sub new { bless {}, shift }
    sub getAddrVersion { 'ipv4' }
    sub isRoutableAddr { 1 }
}

no warnings qw/ redefine once /;
local *Servers::named::bind::_compileZone = sub { 0 };
local *iMSCP::Net::getInstance = sub { StubNet->new() };
use warnings qw/ redefine once /;

my $named = bless {
    config  => { BIND_MODE => 'master' },
    events  => StubEvents->new(),
    tplDir  => $tplDir,
    wrkDir  => $wrkDir,
    serials => { $parent => 1 },
    reload  => 0
}, 'Servers::named::bind';

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

done_testing();
