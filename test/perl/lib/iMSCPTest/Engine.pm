package iMSCPTest::Engine;

# Drive the installed engine the way the panel does, for the integration tests.
#
#   boot_engine();                         # once per file, before any fixture
#   my $c = customer( label => 'named' );  # iMSCPTest::Fixture
#   run_engine();                          # imscp-rqst-mngr, as the daemon runs it
#   is_ok( $c );                           # every row the fixture wrote is 'ok'
#
# Only on the throwaway CI image: test/run.sh checks for it.

use strict;
use warnings;
use Config ();
use Test::More ();
use parent 'Exporter';

our @EXPORT_OK = qw/ boot_engine engine_dir dbh run_engine is_ok is_gone /;

sub engine_dir { $ENV{'IMSCP_ENGINE_DIR'} || '/var/www/imscp/engine' }

# No lock: imscp-rqst-mngr, run by run_engine(), takes it.
sub boot_engine
{
    require iMSCP::Bootstrapper;
    iMSCP::Bootstrapper->getInstance()->boot( {
        mode            => 'backend',
        nolock          => 1,
        norequirements  => 1,
        config_readonly => 1
    } );
}

sub dbh
{
    require iMSCP::Database;
    iMSCP::Database->factory()->getRawDb();
}

sub run_engine
{
    my $engine = engine_dir();
    # exec: no shell in between to turn a signal into an exit status of 128+n.
    my $out = `exec perl '$engine/imscp-rqst-mngr' --verbose 2>&1`;
    my $status = $?;
    my $signal = $status & 127;
    my $ok = $status == 0;
    Test::More::ok( $ok, 'imscp-rqst-mngr exits 0' ) or Test::More::diag(
        ( $signal ? 'imscp-rqst-mngr was killed by signal ' . $signal . ' (' . ( ( split ' ', $Config::Config{'sig_name'} )[$signal] // '?' ) . ")\n" : '' )
            . $out
    );
    $ok;
}

# i-MSCP leaves the error text in the status column of whatever it could not
# process, so that is what a failure shows.
sub is_ok
{
    my ( $obj, $name ) = @_;

    my @bad;
    for my $row ( @{ $obj->{'rows'} } ) {
        my ( $status ) = dbh()->selectrow_array(
            "SELECT `$row->{'status'}` FROM `$row->{'table'}` WHERE `$row->{'key'}` = ?", undef, $row->{'id'}
        );
        push @bad, "$row->{'table'} $row->{'id'}: " . ( $status // 'no row' )
            unless defined $status && $status eq 'ok';
    }
    Test::More::ok( !@bad, $name // "$obj->{'name'} is ok" ) or Test::More::diag( join "\n", @bad );
}

sub is_gone
{
    my ( $obj, $name ) = @_;

    my @left;
    for my $row ( @{ $obj->{'rows'} } ) {
        my ( $count ) = dbh()->selectrow_array(
            "SELECT COUNT(*) FROM `$row->{'table'}` WHERE `$row->{'key'}` = ?", undef, $row->{'id'}
        );
        push @left, "$row->{'table'} $row->{'id'} is still there" if $count;
    }
    Test::More::ok( !@left, $name // "$obj->{'name'} is gone" ) or Test::More::diag( join "\n", @left );
}

1;
