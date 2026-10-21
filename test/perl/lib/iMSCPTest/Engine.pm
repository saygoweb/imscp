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
    my $out = `perl '$engine/imscp-rqst-mngr' --verbose 2>&1`;
    my $exit = $? >> 8;
    Test::More::ok( $exit == 0, 'imscp-rqst-mngr exits 0' ) or Test::More::diag( $out );
    $exit == 0;
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
