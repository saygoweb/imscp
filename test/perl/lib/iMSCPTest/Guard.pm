package iMSCPTest::Guard;

# Undoes a stub when it goes out of scope. Every stub in the kit returns one:
# keep it in a lexical for as long as the stub should last, e.g. file-wide
#
#   my $db = stub_db( ... );

use strict;
use warnings;
use Carp qw/ croak /;

sub new
{
    my ( $class, $restore, %fields ) = @_;

    ref $restore eq 'CODE' or croak( 'A guard needs a restore sub' );
    bless { %fields, _restore => $restore }, $class;
}

# A stub called in void context would be undone before it was ever used.
sub require_kept
{
    my ( $wantarray, $name ) = @_;

    defined $wantarray or croak(
        "$name returns a guard that undoes it when dropped; keep it: my \$guard = $name( ... )"
    );
}

sub DESTROY
{
    my ( $self ) = @_;

    local ( $@, $!, $? );
    my $restore = delete $self->{'_restore'} or return;
    $restore->();
}

1;
