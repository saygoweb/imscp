#!/usr/bin/perl

# iMSCPTest::Stub::Execute: commands run through iMSCP::Execute are answered by
# the test, in every module that imported execute(), and never reach a shell.

use strict;
use warnings;
use Test::More;
use iMSCP::Execute qw/ execute executeNoWait /;
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
    is_deeply( Caller::nowait(), [ 0, "one\n", "two", "E:oops" ], 'executeNoWait() feeds the callbacks line by line, a last line without its newline as it is' );
    is_deeply( [ $exec->commands ], [ 'echo hi', 'ls -l /nowhere', 'tail log' ], 'every command is recorded' );

    eval q{ package Later; use iMSCP::Execute; 1 } or die $@;
    is( Later::execute( 'echo hi', \my $out ), 0, 'a module that imports execute() after stubbing gets the stub' );
}

{
    my $exec = stub_execute(
        qr/^version$/ => [ 0, "9.18.1\n", '' ],
        qr/^both$/    => [ 0, "out\n", "err\n" ],
        qr/^errs$/    => [ 0, '', "err\n" ],
        qr/^lines$/   => [ 0, "a\n\nb\n", "c\nd" ],
    );
    execute( 'version', \my $version );
    is( $version, '9.18.1', 'execute() hands stdout back without its trailing newline' );
    execute( 'both', \my $out, \my $err );
    is_deeply( [ $out, $err ], [ 'out', 'err' ], 'and stderr too when both are captured' );
    execute( 'errs', undef, \my $only );
    is( $only, "err\n", 'a lone stderr capture is left alone, as in the real execute()' );
    my ( @o, @e );
    executeNoWait( 'lines', sub { push @o, $_[0] }, sub { push @e, $_[0] } );
    is_deeply( [ \@o, \@e ], [ [ "a\n", "\n", "b\n" ], [ "c\n", 'd' ] ], 'executeNoWait() splits like the real one, empty lines and a final partial line included' );
}

{
    my $exec = stub_execute( qr/^echo / => [ 0, '', '' ] );

    like( ( eval { execute( undef ); 1 } ? '' : $@ ), qr/Missing \$command parameter/, 'execute() without a command dies, as the real one does' );
    like( ( eval { execute( 'echo x', 'not a ref' ); 1 } ? '' : $@ ), qr/Expects a scalar reference as second parameter STDOUT capture/, 'a stdout capture that is not a scalar reference dies' );
    like( ( eval { execute( 'echo x', undef, [] ); 1 } ? '' : $@ ), qr/Expects a scalar reference as second parameter STDERR capture/, 'and so does a stderr capture' );
    like( ( eval { executeNoWait( 'echo x', 'no' ); 1 } ? '' : $@ ), qr/Invalid \$subSTDOUT parameter. CODE expected/, 'executeNoWait() refuses a stdout callback that is not CODE' );
    like( ( eval { executeNoWait( 'echo x', undef, 'no' ); 1 } ? '' : $@ ), qr/Invalid \$subSTDERR parameter. CODE expected/, 'and a stderr one' );
    is_deeply( [ $exec->commands ], [], 'none of those reached the rules' );

    my $out = 'old';
    execute( 'echo x', \$out );
    is( $out, '', 'a capture is emptied before the command answers' );

    my @debug;
    my $debug = stub_method( 'iMSCP::Debug', 'debug', sub { push @debug, $_[0]; undef } );
    execute( 'echo one' );
    execute( [ 'echo', 'two', 'words' ] );
    executeNoWait( 'echo three' );
    executeNoWait( [ 'echo', 'four' ] );
    is_deeply( \@debug, [ 'echo one', 'echo two words', 'echo three', 'echo four' ], 'every command is logged through debug(), as the real functions do' );
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
