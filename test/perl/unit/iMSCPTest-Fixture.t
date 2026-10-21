#!/usr/bin/perl

# iMSCPTest::Fixture checks each table it writes against the live schema, so a
# panel schema change fails loudly instead of leaving a half-made customer.

use strict;
use warnings;
use Test::More;
use iMSCPTest::Stub qw/ stub_db /;
use iMSCPTest::Fixture qw/ test_name reseller /;

is( test_name( 'named' ), "named-$$.test", 'names are <label>-<pid>.test' );
ok( !eval { test_name( 'named' ); 1 }, 'and never handed out twice' );
ok( !eval { test_name( 'Bad_Label' ); 1 }, 'labels are lower-case letters, digits and dashes' );

sub columns
{
    my ( @extra ) = @_;
    [
        ( map { { Field => $_, Null => 'YES', Default => undef, Extra => '' } }
            qw/ admin_name admin_pass admin_type created_by email admin_status domain_created / ),
        { Field => 'admin_id', Null => 'NO', Default => undef, Extra => 'auto_increment' },
        @extra
    ];
}

{
    my $db = stub_db(
        qr/^SELECT admin_id FROM admin WHERE admin_name = / => [],
        qr/^SELECT admin_id FROM admin WHERE admin_type = 'admin'/ => [ [ 1 ] ],
        qr/^SHOW COLUMNS FROM `admin`$/ => columns( { Field => 'new_required', Null => 'NO', Default => undef, Extra => '' } ),
    );
    ok( !eval { reseller(); 1 }, 'a NOT NULL column without a default that the fixture does not set stops it' );
    like( $@, qr/new_required.*panel's schema/s, 'and says why' );
}

done_testing();
