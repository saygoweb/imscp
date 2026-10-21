package iMSCPTest::Stub;

# The unit kit in one import. See test/perl/README.md.
#
#   use iMSCPTest::Stub qw/ :all /;
#
#   my $events = stub_events();
#   my $exec   = stub_execute( qr/^named-checkzone/ => [ 0 ] );
#   my $named  = new_server( 'Servers::named::bind', config => server_config( 'bind' ) );

use strict;
use warnings;
use Carp qw/ croak /;
use iMSCPTest::Stub::Symbol qw/ stub_method stub_singleton /;
use iMSCPTest::Stub::Execute qw/ stub_execute /;
use iMSCPTest::Stub::DB qw/ stub_db /;
use iMSCPTest::Stub::Config qw/ repo_root config_path stub_config server_config /;
use iMSCPTest::Stub::Env qw/ stub_events sandbox sandbox_path debug_messages /;
use parent 'Exporter';

our @EXPORT_OK = qw/
    stub_method stub_singleton stub_execute stub_db stub_config server_config config_path repo_root
    stub_events sandbox sandbox_path debug_messages new_server
/;
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

# An instance with the fields its constructor would have set, without running
# _init(), which reads the installed server's configuration.
sub new_server
{
    my ( $class, %fields ) = @_;

    no warnings 'once';
    ref $iMSCP::EventManager::_instance eq 'iMSCPTest::Stub::Env::Events' or croak(
        'new_server() needs stub_events() first: the real event manager loads listener files'
    );

    ( my $file = "$class.pm" ) =~ s{::}{/}g;
    require $file;
    bless { events => $iMSCP::EventManager::_instance, config => {}, %fields }, $class;
}

1;
