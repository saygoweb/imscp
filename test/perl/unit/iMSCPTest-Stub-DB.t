#!/usr/bin/perl

# iMSCPTest::Stub::DB: iMSCP::Database->factory() hands out a fake adapter
# whose handle answers SQL from the test's rules and records every statement.

use strict;
use warnings;
use Test::More;
use iMSCP::Database;
use iMSCPTest::Stub::Symbol qw/ stub_method /;
use iMSCPTest::Stub::DB qw/ stub_db /;

my $realFactory = \&iMSCP::Database::factory;

{
    my $db = stub_db(
        qr/^SELECT domain_id, domain_name FROM domain WHERE domain_id = \?$/ => [ { domain_id => 7, domain_name => 'a.test' } ],
        qr/^SELECT domain_name FROM domain$/                                => [ { domain_name => 'a.test' }, { domain_name => 'b.test' } ],
        qr/^SELECT COUNT\(\*\) FROM subdomain/                              => [ [ 3 ] ],
        qr/^UPDATE domain SET domain_status = \?/                           => 1,
        qr/^SELECT \* FROM php_ini/                                         => sub { my ( $sql, @bind ) = @_; [ { id => $bind[0] } ] },
    );
    my $dbh = iMSCP::Database->factory()->getRawDb();

    is_deeply(
        $dbh->selectrow_hashref( "SELECT domain_id, domain_name\n    FROM domain WHERE domain_id = ?", undef, 7 ),
        { domain_id => 7, domain_name => 'a.test' },
        'a rule matches with the whitespace collapsed'
    );
    is_deeply( $dbh->selectcol_arrayref( 'SELECT domain_name FROM domain' ), [ 'a.test', 'b.test' ], 'a column fetch takes a one-key hash row\'s value' );
    is( scalar $dbh->selectrow_array( 'SELECT COUNT(*) FROM subdomain' ), 3, 'an array fetch takes array rows' );
    is( $dbh->do( 'UPDATE domain SET domain_status = ? WHERE domain_id = ?', undef, 'ok', 7 ), 1, 'do() returns the rows affected' );
    is_deeply( $dbh->selectall_arrayref( 'SELECT * FROM php_ini WHERE domain_id = ?', { Slice => {} }, 9 ), [ { id => 9 } ], 'a rule sub gets the bind values' );

    my $sth = $dbh->prepare( 'SELECT domain_name FROM domain' );
    $sth->execute();
    my @names;
    while ( my $row = $sth->fetchrow_hashref() ) { push @names, $row->{'domain_name'} }
    is_deeply( \@names, [ 'a.test', 'b.test' ], 'prepare/execute/fetchrow_hashref walks the rows' );

    is_deeply(
        iMSCP::Database->factory()->doQuery( 'domain_name', 'SELECT domain_name FROM domain' ),
        { 'a.test' => { domain_name => 'a.test' }, 'b.test' => { domain_name => 'b.test' } },
        'doQuery() keys the rows'
    );

    $dbh->begin_work();
    $dbh->commit();
    {
        local $dbh->{'RaiseError'} = 0;
        is( $dbh->{'RaiseError'}, 0, 'handle attributes can be localised' );
    }

    is_deeply(
        [ ( $db->statements )[3, 7, 8] ],
        [ [ 'UPDATE domain SET domain_status = ? WHERE domain_id = ?', 'ok', 7 ], [ 'BEGIN' ], [ 'COMMIT' ] ],
        'statements are recorded with their bind values, transactions too'
    );

    my @failed;
    my $fail = stub_method( 'Test::More', 'fail', sub { push @failed, $_[0]; 0 } );
    ok( !eval { $dbh->do( 'DELETE FROM admin' ); 1 }, 'a statement no rule matches dies' );
    undef $fail;
    is_deeply( \@failed, [ 'unexpected SQL: DELETE FROM admin' ], 'and fails the test' );

    @failed = ();
    $fail = stub_method( 'Test::More', 'fail', sub { push @failed, $_[0]; 0 } );
    ok( !eval { $dbh->selectrow_hashref( 'SELECT COUNT(*) FROM subdomain' ); 1 }, 'a hash fetch of array rows dies' );
    undef $fail;
    like( $failed[0], qr/hash/, 'and says why' );
}

{
    my $db = stub_db(
        qr/^UPDATE domain SET/ => 1,
        qr/^SELECT boom/       => sub { die "kaboom\n" },
        qr/^SELECT id FROM t$/ => [ { id => 5 } ],
    );
    my $adapter = iMSCP::Database->factory();

    is_deeply( $adapter->doQuery( 'u', 'UPDATE domain SET x = 1' ), {}, 'doQuery() of a statement without rows is an empty hash' );
    is( $adapter->doQuery( 'u', 'SELECT boom' ), "kaboom\n", 'a failing statement gives the error string, not a die' );
    is_deeply( $adapter->doQuery( 'id', "SELECT  id\nFROM t" ), { 5 => { id => 5 } }, 'a SELECT is keyed by the column' );
    is_deeply( [ map { $_->[0] } $db->statements ], [ 'UPDATE domain SET x = 1', 'SELECT boom', 'SELECT id FROM t' ], 'and the statements are recorded normalised, once' );
}

is( \&iMSCP::Database::factory, $realFactory, 'the real factory() is back' );
like( ( eval { stub_db(); 1 } ? '' : $@ ), qr/keep it/, 'a guard thrown away at once is refused' );

done_testing();
