package iMSCPTest::Stub::Config;

# The configuration files i-MSCP ships, for the Debian release production runs
# (trixie; IMSCP_TEST_SUITE picks another), falling back to configs/debian/default.
#
#   my $config = stub_config( DEBUG => 1 );           # %main::imscpConfig
#   my $bind   = server_config( 'bind', BIND_MODE => 'master' );
#   my $tplDir = config_path( 'bind/parts' );

use strict;
use warnings;
use Carp qw/ croak /;
use Cwd qw/ abs_path /;
use File::Basename qw/ dirname /;
use iMSCPTest::Guard;
use parent 'Exporter';

our @EXPORT_OK = qw/ repo_root config_path stub_config server_config /;

# test/perl/lib/iMSCPTest/Stub/Config.pm, five levels down.
my $ROOT = abs_path( dirname( __FILE__ ) . '/../../../../..' );

sub repo_root { $ROOT }

sub config_path
{
    my ( $relative ) = @_;

    my $suite = $ENV{'IMSCP_TEST_SUITE'} || 'trixie';
    for my $dir ( "configs/debian/$suite", 'configs/debian/default' ) {
        my $path = "$ROOT/$dir/$relative";
        return $path if -e $path;
    }
    croak( "$relative is shipped neither for $suite nor in configs/debian/default" );
}

# The parse iMSCP::Config does.
sub _read
{
    my ( $path ) = @_;

    open my $fh, '<', $path or croak( "$path: $!" );
    my %config;
    while ( my $line = <$fh> ) {
        chomp $line;
        next unless $line =~ /^([^#\s=]+)\s*=\s*(.*)$/;
        $config{$1} = $2;
    }
    \%config;
}

sub stub_config
{
    my ( %over ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_config' );

    no warnings 'once';
    my %old = %main::imscpConfig;
    untie %main::imscpConfig if tied %main::imscpConfig;
    %main::imscpConfig = ( %{ _read( config_path( 'imscp.conf' ) ) }, %over );

    iMSCPTest::Guard->new( sub { %main::imscpConfig = %old } );
}

sub server_config
{
    my ( $server, %over ) = @_;

    +{ %{ _read( config_path( "$server/$server.data.dist" ) ) }, %over };
}

1;
