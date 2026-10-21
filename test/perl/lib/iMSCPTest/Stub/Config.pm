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

# A file as iMSCP::Config reads it, without a lock, root or an installed i-MSCP.
sub _read
{
    my ( $path ) = @_;

    require iMSCP::Config;
    tie my %tied, 'iMSCP::Config', fileName => $path, readonly => 1, nocreate => 1;
    my %config = %tied;
    untie %tied;
    \%config;
}

sub stub_config
{
    my ( %over ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_config' );

    no warnings 'once';
    my $tie = tied %main::imscpConfig;
    my %old = %main::imscpConfig;
    { no warnings 'untie'; untie %main::imscpConfig if $tie }    # we hold the object
    %main::imscpConfig = ( %{ _read( config_path( 'imscp.conf' ) ) }, %over );

    iMSCPTest::Guard->new( sub {
        # A tied hash goes back to the object it was tied to, which kept its
        # own contents; a plain one gets its values back.
        # Code under test may have tied the hash to something newer: let that
        # go without a CLEAR, which would write to its file.
        { no warnings 'untie'; untie %main::imscpConfig }
        if ( $tie ) {
            tie %main::imscpConfig, 'iMSCPTest::Stub::Config::Retie', $tie;
        } else {
            %main::imscpConfig = %old;
        }
    } );
}

sub server_config
{
    my ( $server, %over ) = @_;

    +{ %{ _read( config_path( "$server/$server.data.dist" ) ) }, %over };
}

package iMSCPTest::Stub::Config::Retie;

# tie() with an object it is given instead of a new one.
sub TIEHASH { $_[1] }

1;
