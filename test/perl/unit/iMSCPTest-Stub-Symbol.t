#!/usr/bin/perl

# iMSCPTest::Stub::Symbol: stubs for one sub and for a singleton's instance,
# undone when their guard goes.

use strict;
use warnings;
use Test::More;
use iMSCPTest::Stub::Symbol qw/ stub_method stub_singleton /;

{
    package Sample;
    sub plain { 'real' }
    sub proto ($;$) { 'real' }
}

{
    my $guard = stub_method( 'Sample', 'plain', sub { 'stub' } );
    is( Sample->plain, 'stub', 'stub_method replaces the sub' );
}
is( Sample->plain, 'real', 'and puts it back when its guard goes' );

{
    my $guard = stub_method( 'Sample', 'proto', sub { 'stub' } );
    is( prototype( \&Sample::proto ), '$;$', 'the stub keeps the original prototype' );
    is( Sample::proto( 1 ), 'stub', 'and is called' );
}
is( Sample::proto( 1 ), 'real', 'a prototyped sub is put back' );

{
    my $guard = stub_method( 'Sample', 'added', sub { 'new' } );
    is( Sample->added, 'new', 'a sub that did not exist can be stubbed' );
}
ok( !Sample->can( 'added' ), 'and is removed again' );

like(
    ( eval { stub_method( 'Sample', 'plain', sub { 'stub' } ); 1 } ? '' : $@ ),
    qr/keep it/,
    'a guard thrown away at once is refused'
);
is( Sample->plain, 'real', 'and the sub is left alone' );

{
    package Single;
    use parent 'Common::SingletonClass';
}

my $fake = bless {}, 'Fake';
{
    my $guard = stub_singleton( 'Single', $fake );
    is( Single->getInstance(), $fake, 'stub_singleton sets the instance getInstance() returns' );
}
isnt( Single->getInstance(), $fake, 'and restores it' );

my $real = Single->getInstance();
{
    my $guard = stub_singleton( 'Single', $fake );
}
is( Single->getInstance(), $real, 'an existing instance comes back' );

done_testing();
