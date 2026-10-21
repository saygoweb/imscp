#!/usr/bin/perl

# iMSCPTest::Stub: the whole unit kit in one import, and new_server().

use strict;
use warnings;
use Test::More;
use iMSCPTest::Stub qw/ :all /;

ok( defined &$_, "exports $_" ) for qw/
    stub_method stub_singleton stub_execute stub_db stub_config server_config config_path repo_root
    stub_events sandbox sandbox_path debug_messages new_server
/;

ok( !eval { new_server( 'Servers::named::bind' ); 1 }, 'new_server() refuses without stub_events()' );
like( $@, qr/stub_events/, 'and says what is missing' );

my $events = stub_events();
my $named = new_server( 'Servers::named::bind', config => { BIND_MODE => 'master' }, wrkDir => sandbox() );
isa_ok( $named, 'Servers::named::bind' );
is( $named->{'events'}, $events->object, 'it gets the stubbed event manager' );
is( $named->{'config'}->{'BIND_MODE'}, 'master', 'and the fields it is given' );

done_testing();
