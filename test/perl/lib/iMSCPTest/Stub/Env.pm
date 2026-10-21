package iMSCPTest::Stub::Env;

# What the code under test reaches for around it: the event manager, a place
# to write files, and the error log.
#
#   my $events = stub_events( fail => 'beforeNamedAddSub' );
#   my $dir    = sandbox();                        # one per test file
#   my $conf   = sandbox_path( '/etc/bind/named.conf' );
#   like( ( debug_messages() )[0], qr/.../ );

use strict;
use warnings;
use Carp qw/ croak /;
use File::Basename qw/ dirname /;
use File::Path qw/ make_path /;
use File::Temp qw/ tempdir /;
use iMSCP::Debug ();
use iMSCPTest::Guard;
use iMSCPTest::Stub::Symbol qw/ stub_singleton /;
use parent 'Exporter';

our @EXPORT_OK = qw/ stub_events sandbox sandbox_path debug_messages /;

sub stub_events
{
    my ( %opts ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_events' );

    my @fail = ref $opts{'fail'} ? @{ $opts{'fail'} } : grep { defined } $opts{'fail'};
    my $events = iMSCPTest::Stub::Env::Events->new( { map { $_ => 1 } @fail } );
    require iMSCP::EventManager;
    my $singleton = stub_singleton( 'iMSCP::EventManager', $events );

    iMSCPTest::Stub::Env::EventsGuard->new( sub { undef $singleton }, events => $events );
}

my $SANDBOX;

sub sandbox
{
    $SANDBOX //= tempdir( 'imscp-test-XXXXXX', TMPDIR => 1 );
}

sub sandbox_path
{
    my ( $real ) = @_;

    $real =~ m{^/} or croak( 'sandbox_path takes an absolute path' );
    my $path = sandbox() . $real;
    make_path( dirname( $path ) );
    $path;
}

sub debug_messages
{
    my ( $type ) = @_;

    iMSCP::Debug::getMessageByType( $type // 'error', { remove => 1 } );
}

# A failing test can leave a directory without its execute bit; give every
# directory its permissions back so that it can be removed.
END {
    if ( defined $SANDBOX && -d $SANDBOX ) {
        local $?;
        system( 'chmod', '-R', 'u+rwx', '--', $SANDBOX );
        system( 'rm', '-rf', '--', $SANDBOX );
    }
}

package iMSCPTest::Stub::Env::EventsGuard;

use parent -norequire, 'iMSCPTest::Guard';

sub object { $_[0]->{'events'} }
sub triggered { map { $_->[0] } @{ $_[0]->{'events'}->{'triggered'} } }

package iMSCPTest::Stub::Env::Events;

sub new
{
    my ( $class, $fail ) = @_;
    bless { fail => $fail, triggered => [], registered => [] }, $class;
}

sub trigger
{
    my ( $self, $event, @params ) = @_;

    push @{ $self->{'triggered'} }, [ $event, @params ];
    $self->{'fail'}->{$event} ? 1 : 0;
}

sub register { my ( $self, $event, $listener ) = @_; push @{ $self->{'registered'} }, [ $event, $listener ]; 0 }
sub registerOne { shift->register( @_ ) }
sub unregister { 0 }
sub hasListener { 0 }
sub clearListeners { 0 }

1;
