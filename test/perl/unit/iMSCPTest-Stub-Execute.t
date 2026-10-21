#!/usr/bin/perl

# iMSCPTest::Stub::Execute: commands run through iMSCP::Execute are answered by
# the test, in every module that imported execute(), and never reach a shell.

use strict;
use warnings;
use Test::More;
use iMSCP::Execute ();
use iMSCPTest::Stub::Symbol qw/ stub_method /;
use iMSCPTest::Stub::Execute qw/ stub_execute /;

{
    package Caller;
    use iMSCP::Execute;
    sub string { my $rs = execute( 'echo hi', \my $out, \my $err ); [ $rs, $out, $err ] }
    sub list { my $rs = execute( [ 'ls', '-l', '/nowhere' ], \my $out, \my $err ); [ $rs, $out, $err ] }
    sub nowait { my @lines; my $rs = executeNoWait( 'tail log', sub { push @lines, @_ }, sub { push @lines, "E:@_" } ); [ $rs, @lines ] }
}

my $real = \&iMSCP::Execute::execute;

{
    my $exec = stub_execute(
        qr/^echo hi$/          => [ 0, 'stubbed', '' ],
        qr{^ls -l /nowhere$}   => [ 2, '', 'No such file' ],
        qr/^tail log$/         => [ 0, "one\ntwo", 'oops' ],
    );

    is_deeply( Caller::string(), [ 0, 'stubbed', '' ], 'an imported execute() is answered by the rule' );
    is_deeply( Caller::list(), [ 2, '', 'No such file' ], 'an array command matches as its joined line' );
    is_deeply( Caller::nowait(), [ 0, "one\n", "two\n", "E:oops\n" ], 'executeNoWait() feeds the output to the callbacks, line by line' );
    is_deeply( [ $exec->commands ], [ 'echo hi', 'ls -l /nowhere', 'tail log' ], 'every command is recorded' );

    eval q{ package Later; use iMSCP::Execute; 1 } or die $@;
    is( Later::execute( 'echo hi', \my $out ), 0, 'a module that imports execute() after stubbing gets the stub' );
}

is( \&Caller::execute, $real, 'the real execute() is back in the importing module' );
is( \&Later::execute, $real, 'and in a module that imported the stub' );
is( Caller::string()->[1], 'hi', 'and really runs' );

{
    my @failed;
    my $fail = stub_method( 'Test::More', 'fail', sub { push @failed, $_[0]; 0 } );
    my $exec = stub_execute( qr/^never$/ => [ 0 ] );
    my $result = Caller::string();
    undef $fail;
    is( $result->[0], 1, 'a command no rule matches returns 1' );
    is_deeply( \@failed, [ 'unexpected command: echo hi' ], 'and fails the test' );
}

{
    my $exec = stub_execute( qr/^ls/ => sub { my ( $command ) = @_; [ ref $command eq 'ARRAY' ? 0 : 9, 'array', '' ] } );
    is_deeply( Caller::list(), [ 0, 'array', '' ], 'a reply sub gets the command as it was given' );
}

like( ( eval { stub_execute(); 1 } ? '' : $@ ), qr/keep it/, 'a guard thrown away at once is refused' );

done_testing();
