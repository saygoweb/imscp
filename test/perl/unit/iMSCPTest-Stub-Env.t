#!/usr/bin/perl

# iMSCPTest::Stub::Env: events, a sandbox for files, and the error log.

use strict;
use warnings;
use Test::More;
use iMSCP::Debug qw/ error /;
use iMSCP::EventManager;
use iMSCPTest::Stub::Env qw/ stub_events sandbox sandbox_path debug_messages /;

{
    my $events = stub_events( fail => 'beforeNamedAddSub' );
    my $manager = iMSCP::EventManager->getInstance();
    is( $manager, $events->object, 'stub_events() is what getInstance() returns' );
    is( $manager->trigger( 'beforeNamedAddDmn', { x => 1 } ), 0, 'an event succeeds' );
    is( $manager->trigger( 'beforeNamedAddSub' ), 1, 'unless it is told to fail' );
    is( $manager->register( 'onBoot', sub { 0 } ), 0, 'listeners can be registered' );
    is_deeply( [ $events->triggered ], [ 'beforeNamedAddDmn', 'beforeNamedAddSub' ], 'triggered events are recorded in order' );
}
ok( ref( $iMSCP::EventManager::_instance // '' ) ne 'iMSCPTest::Stub::Env::Events', 'the event manager is restored' );

my $dir = sandbox();
ok( -d $dir, 'sandbox() is a directory' );
is( sandbox(), $dir, 'the same one for the whole file' );
my $path = sandbox_path( '/etc/bind/named.conf' );
is( $path, "$dir/etc/bind/named.conf", 'sandbox_path() maps a real path into it' );
ok( -d "$dir/etc/bind", 'and creates its directory' );

my $pid = fork() // die "fork: $!";
if ( $pid == 0 ) {
    sandbox_path( '/from/child' );
    exit 0;    # a normal exit runs END
}
waitpid $pid, 0;
ok( -d $dir, 'a forked child that exits does not remove the parent\'s sandbox' );

{
    my $code = q{
        use iMSCPTest::Stub::Env qw/ sandbox /;
        my $dir = sandbox();
        mkdir "$dir/locked" or die $!;
        chmod 0000, "$dir/locked";
        print $dir, "\n";
    };
    open my $child, '-|', $^X, ( map { "-I$_" } @INC ), '-e', $code or die "perl: $!";
    chomp( my $left = <$child> // '' );
    close $child;
    ok( length $left && $left =~ m{/imscp-test-}, 'a child test made a sandbox' );
    ok( !-e $left, 'a directory without permissions is still removed when it exits' );
}

error( 'something broke' );
like( ( debug_messages() )[0], qr/something broke/, 'debug_messages() returns logged errors' );
is_deeply( [ debug_messages() ], [], 'once' );

like( ( eval { stub_events(); 1 } ? '' : $@ ), qr/keep it/, 'a guard thrown away at once is refused' );

done_testing();
