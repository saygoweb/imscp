package iMSCPTest::Stub::Symbol;

# Stubs for a single sub and for a singleton's instance.
#
#   my $compile = stub_method( 'Servers::named::bind', '_compileZone', sub { 0 } );
#   my $net     = stub_singleton( 'iMSCP::Net', $fakeNet );
#
# Load the class before stubbing one of its subs: loading it afterwards would
# define the real sub over the stub.

use strict;
use warnings;
use Carp qw/ croak /;
use Scalar::Util ();
use iMSCPTest::Guard;
use parent 'Exporter';

our @EXPORT_OK = qw/ stub_method stub_singleton /;

sub stub_method
{
    my ( $class, $method, $code ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_method' );
    ref $code eq 'CODE' or croak( 'stub_method needs a code ref' );

    no strict 'refs';
    no warnings qw/ redefine prototype /;

    my $name = "${class}::$method";
    my $old = defined &{ $name } ? \&{ $name } : undef;
    my $proto = $old ? prototype $old : undef;
    &Scalar::Util::set_prototype( $code, $proto ) if defined $proto;
    *{ $name } = $code;

    iMSCPTest::Guard->new( sub {
        no strict 'refs';
        no warnings qw/ redefine prototype /;

        if ( $old ) {
            *{ $name } = $old;
            return;
        }

        # Remove the sub but keep whatever else shares its glob.
        my $glob = \*{ $name };
        my %slots = map { $_ => *{ $glob }{$_} } grep { defined *{ $glob }{$_} } qw/ SCALAR ARRAY HASH IO /;
        delete ${"${class}::"}{$method};
        *{ $name } = $slots{$_} for keys %slots;
    } );
}

sub stub_singleton
{
    my ( $class, $obj ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_singleton' );

    no strict 'refs';
    my $slot = \${"${class}::_instance"};
    my $old = ${ $slot };
    ${ $slot } = $obj;

    iMSCPTest::Guard->new( sub { ${ $slot } = $old } );
}

1;
