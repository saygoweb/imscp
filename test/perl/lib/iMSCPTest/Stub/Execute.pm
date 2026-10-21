package iMSCPTest::Stub::Execute;

# Every command the code under test runs through iMSCP::Execute is answered by
# the test instead of the shell.
#
#   my $exec = stub_execute(
#       qr/^named-checkconf\b/ => [ 0, '', '' ],                 # exit, stdout, stderr
#       qr/^systemctl reload/  => sub { my ( $command ) = @_; [ 0, '', '' ] },
#   );
#   ...
#   is_deeply [ $exec->commands ], [ ... ];
#
# A command no rule matches fails the test and returns 1. `use iMSCP::Execute`
# copies execute() into each module that imports it, so every copy is
# replaced, not only the original.

use strict;
use warnings;
use Carp qw/ croak /;
use Scalar::Util ();
use Test::More ();
use iMSCP::Execute ();
use iMSCPTest::Guard;
use parent 'Exporter';

our @EXPORT_OK = qw/ stub_execute /;

sub stub_execute
{
    my ( @rules ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_execute' );
    @rules % 2 == 0 or croak( 'stub_execute takes qr/.../ => answer pairs' );

    my @calls;
    my $answer = sub {
        my ( $command ) = @_;

        my $line = ref $command eq 'ARRAY' ? join( ' ', @{ $command } ) : $command;
        push @calls, $line;

        for ( my $i = 0; $i < @rules; $i += 2 ) {
            my ( $re, $reply ) = @rules[$i, $i + 1];
            next unless $line =~ $re;
            $reply = $reply->( $command ) if ref $reply eq 'CODE';
            my ( $exit, $stdout, $stderr ) = @{ $reply };
            return ( $exit // 0, $stdout // '', $stderr // '' );
        }

        Test::More::fail( "unexpected command: $line" );
        ( 1, '', "unexpected command: $line" );
    };

    my $execute = sub {
        my ( $command, $stdout, $stderr ) = @_;

        my ( $exit, $out, $err ) = $answer->( $command );

        # Output as the real execute() hands it back: both captures lose one
        # trailing newline, but a lone STDERR capture is left as it came
        # (the real code chomps the reference there, which changes nothing).
        ${ $stdout } = $out if $stdout;
        ${ $stderr } = $err if $stderr;
        chomp( ${ $stdout } ) if $stdout;
        chomp( ${ $stderr } ) if $stderr && $stdout;
        $? = $exit << 8;
        $exit;
    };

    my $executeNoWait = sub {
        my ( $command, $onStdout, $onStderr ) = @_;

        my ( $exit, $out, $err ) = $answer->( $command );
        $onStdout //= sub { print STDOUT $_[0] };
        $onStderr //= sub { print STDERR $_[0] . "\n" };

        # Lines arrive with their newline, a last line without one as it is.
        $onStdout->( $_ ) for $out =~ /\G([^\n]*\n|[^\n]+)/g;
        $onStderr->( $_ ) for $err =~ /\G([^\n]*\n|[^\n]+)/g;
        $? = $exit << 8;
        $exit;
    };

    my %real = (
        execute       => \&iMSCP::Execute::execute,
        executeNoWait => \&iMSCP::Execute::executeNoWait
    );
    my %stub = ( execute => $execute, executeNoWait => $executeNoWait );
    for my $name ( keys %stub ) {
        &Scalar::Util::set_prototype( $stub{$name}, prototype $real{$name} );
        _swap( $real{$name}, $stub{$name} );
    }

    iMSCPTest::Stub::Execute::Guard->new(
        sub { _swap( $stub{$_}, $real{$_} ) for keys %stub },
        calls => \@calls
    );
}

# Point every glob in every package whose sub is $from at $to.
sub _swap
{
    my ( $from, $to ) = @_;

    no strict 'refs';
    no warnings qw/ redefine prototype /;

    my @stashes = ( 'main::' );
    my %seen;
    while ( defined( my $stash = shift @stashes ) ) {
        next if $seen{$stash}++;
        for my $key ( keys %{ $stash } ) {
            my $full = $stash eq 'main::' ? $key : "$stash$key";
            if ( $key =~ /::\z/ ) {
                push @stashes, $full unless $key eq 'main::';
                next;
            }
            my $glob = ${ $stash }{$key};
            next unless ref \$glob eq 'GLOB';
            my $code = *{ $glob }{CODE} or next;
            *{ $glob } = $to if $code == $from;
        }
    }
}

package iMSCPTest::Stub::Execute::Guard;

use parent -norequire, 'iMSCPTest::Guard';

sub commands { @{ $_[0]->{'calls'} } }

1;
