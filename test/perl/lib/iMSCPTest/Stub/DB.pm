package iMSCPTest::Stub::DB;

# iMSCP::Database->factory() returns a fake adapter whose raw handle answers
# SQL from the test's rules and records every statement.
#
#   my $db = stub_db(
#       qr/^SELECT .* FROM domain\b/ => [ { domain_id => 1, domain_name => 'a.test' } ],
#       qr/^UPDATE domain SET/       => 1,
#       qr/^SELECT COUNT/            => sub { my ( $sql, @bind ) = @_; [ [ 3 ] ] },
#   );
#   ...
#   is_deeply [ $db->statements ], [ [ 'UPDATE domain SET ... = ?', 'ok', 1 ] ];
#
# SQL is matched and recorded with its whitespace collapsed. A result is rows,
# as an array of hashes for the hash fetches or of arrays for the array
# fetches, or for do() the number of rows affected. A statement no rule matches
# fails the test and dies, as DBI does under RaiseError.

use strict;
use warnings;
use Carp qw/ croak /;
use Test::More ();
use iMSCP::Database ();
use iMSCPTest::Guard;
use iMSCPTest::Stub::Symbol qw/ stub_method /;
use parent 'Exporter';

our @EXPORT_OK = qw/ stub_db /;

sub stub_db
{
    my ( @rules ) = @_;

    iMSCPTest::Guard::require_kept( wantarray, 'stub_db' );
    @rules % 2 == 0 or croak( 'stub_db takes qr/.../ => result pairs' );

    my $dbh = iMSCPTest::Stub::DB::Dbh->new( \@rules );
    my $adapter = iMSCPTest::Stub::DB::Adapter->new( $dbh );
    my $factory = stub_method( 'iMSCP::Database', 'factory', sub { $adapter } );

    iMSCPTest::Stub::DB::Guard->new( sub { undef $factory }, dbh => $dbh );
}

package iMSCPTest::Stub::DB::Guard;

use parent -norequire, 'iMSCPTest::Guard';

sub dbh { $_[0]->{'dbh'} }
sub statements { @{ $_[0]->{'dbh'}->{'_statements'} } }

package iMSCPTest::Stub::DB::Adapter;

sub new
{
    my ( $class, $dbh ) = @_;
    bless { dbh => $dbh, db => { DATABASE_NAME => 'imscp' } }, $class;
}

sub getRawDb { $_[0]->{'dbh'} }

sub doQuery
{
    my ( $self, $key, $query, @bindValues ) = @_;

    # The contract of iMSCP::Database::MySQL::doQuery: a hashref on success
    # ({} when the statement gives no rows), the error string on failure.
    local $@;
    my $qrs = eval {
        defined $query or die 'No query provided';
        my $dbh = $self->getRawDb();
        local $dbh->{'RaiseError'} = 0;
        my $sth = $dbh->prepare( $query ) or die $DBI::errstr;
        $sth->execute( @bindValues ) or die $DBI::errstr;
        $sth->fetchall_hashref( $key ) || {};
    };

    return "$@" if $@;
    $qrs;
}

sub useDatabase
{
    my ( $self, $name ) = @_;

    my $old = $self->{'db'}->{'DATABASE_NAME'};
    $self->{'db'}->{'DATABASE_NAME'} = $name;
    $old;
}

sub startTransaction { my ( $self ) = @_; $self->{'dbh'}->begin_work(); $self->{'dbh'} }
sub endTransaction { my ( $self ) = @_; $self->{'dbh'}->{'AutoCommit'} = 1; $self->{'dbh'} }
sub quote { iMSCPTest::Stub::DB::Dbh::quote( undef, $_[1] ) }
sub quoteIdentifier { iMSCPTest::Stub::DB::Dbh::quote_identifier( undef, $_[1] ) }

package iMSCPTest::Stub::DB::Dbh;

use Carp qw/ croak /;

sub new
{
    my ( $class, $rules ) = @_;

    bless {
        RaiseError   => 1,
        PrintError   => 0,
        AutoCommit   => 1,
        Driver       => { Name => 'MariaDB' },
        _rules       => $rules,
        _statements  => []
    }, $class;
}

sub _normalise
{
    my ( $sql ) = @_;

    $sql =~ s/\s+/ /g;
    $sql =~ s/^ | $//g;
    $sql;
}

sub _answer
{
    my ( $self, $sql, @bind ) = @_;

    push @{ $self->{'_statements'} }, [ $sql, @bind ];

    my @rules = @{ $self->{'_rules'} };
    while ( my ( $re, $result ) = splice @rules, 0, 2 ) {
        next unless $sql =~ $re;
        return ref $result eq 'CODE' ? $result->( $sql, @bind ) : $result;
    }

    Test::More::fail( "unexpected SQL: $sql" );
    die( "unexpected SQL: $sql\n" );
}

sub _rows
{
    my ( $self, $sql, @bind ) = @_;

    my $rows = $self->_answer( $sql, @bind );
    return $rows if ref $rows eq 'ARRAY';
    Test::More::fail( "the rule for '$sql' gives no rows; a SELECT needs an array ref" );
    die( "no rows for: $sql\n" );
}

sub _hash
{
    my ( $row, $sql ) = @_;

    return $row if ref $row eq 'HASH';
    Test::More::fail( "the rows for '$sql' are arrays; this fetch needs hash rows" );
    die( "array rows for a hash fetch: $sql\n" );
}

sub _array
{
    my ( $row, $sql ) = @_;

    return $row if ref $row eq 'ARRAY';
    return [ values %{ $row } ] if ref $row eq 'HASH' && keys %{ $row } == 1;
    Test::More::fail( "the rows for '$sql' are hashes; this fetch needs array rows" );
    die( "hash rows for an array fetch: $sql\n" );
}

sub do
{
    my ( $self, $sql, undef, @bind ) = @_;
    $sql = _normalise( $sql );

    my $result = $self->_answer( $sql, @bind );
    my $count = ref $result eq 'ARRAY' ? scalar @{ $result } : $result;
    $count || '0E0';
}

sub selectrow_hashref
{
    my ( $self, $sql, undef, @bind ) = @_;
    $sql = _normalise( $sql );

    my $rows = $self->_rows( $sql, @bind );
    @{ $rows } ? _hash( $rows->[0], $sql ) : undef;
}

sub selectrow_arrayref
{
    my ( $self, $sql, undef, @bind ) = @_;
    $sql = _normalise( $sql );

    my $rows = $self->_rows( $sql, @bind );
    @{ $rows } ? _array( $rows->[0], $sql ) : undef;
}

sub selectrow_array
{
    my ( $self, @args ) = @_;

    my $row = $self->selectrow_arrayref( @args ) or return;
    wantarray ? @{ $row } : $row->[0];
}

sub selectcol_arrayref
{
    my ( $self, $sql, undef, @bind ) = @_;
    $sql = _normalise( $sql );

    [ map { _array( $_, $sql )->[0] } @{ $self->_rows( $sql, @bind ) } ];
}

sub selectall_arrayref
{
    my ( $self, $sql, $attr, @bind ) = @_;
    $sql = _normalise( $sql );

    my $rows = $self->_rows( $sql, @bind );
    my $hashes = ref $attr eq 'HASH' && ref $attr->{'Slice'} eq 'HASH';
    [ map { $hashes ? _hash( $_, $sql ) : _array( $_, $sql ) } @{ $rows } ];
}

sub selectall_hashref
{
    my ( $self, $sql, $key, undef, @bind ) = @_;
    $sql = _normalise( $sql );

    +{ map { my $row = _hash( $_, $sql ); ( $row->{$key} => $row ) } @{ $self->_rows( $sql, @bind ) } };
}

sub prepare
{
    my ( $self, $sql ) = @_;
    $sql = _normalise( $sql );
    iMSCPTest::Stub::DB::Sth->new( $self, $sql );
}

sub begin_work { my ( $self ) = @_; push @{ $self->{'_statements'} }, [ 'BEGIN' ]; $self->{'AutoCommit'} = 0; 1 }
sub commit { my ( $self ) = @_; push @{ $self->{'_statements'} }, [ 'COMMIT' ]; $self->{'AutoCommit'} = 1; 1 }
sub rollback { my ( $self ) = @_; push @{ $self->{'_statements'} }, [ 'ROLLBACK' ]; $self->{'AutoCommit'} = 1; 1 }
sub ping { 1 }
sub err { undef }
sub errstr { '' }

sub quote
{
    my ( undef, $value ) = @_;

    return 'NULL' unless defined $value;
    ( my $quoted = $value ) =~ s/'/''/g;
    "'$quoted'";
}

sub quote_identifier
{
    my ( undef, @parts ) = @_;

    join '.', map { ( my $part = $_ ) =~ s/`/``/g; "`$part`" } grep { defined } @parts;
}

package iMSCPTest::Stub::DB::Sth;

sub new
{
    my ( $class, $dbh, $sql ) = @_;
    bless { dbh => $dbh, sql => $sql, rows => [], count => undef }, $class;
}

sub execute
{
    my ( $self, @bind ) = @_;

    my $result = $self->{'dbh'}->_answer( $self->{'sql'}, @bind );
    $self->{'rows'} = ref $result eq 'ARRAY' ? [ @{ $result } ] : [];
    $self->{'count'} = ref $result eq 'ARRAY' ? scalar @{ $result } : $result;
    $self->{'count'} || '0E0';
}

sub _sql { $_[0]->{'sql'} }

sub fetchrow_hashref
{
    my ( $self ) = @_;

    my $row = shift @{ $self->{'rows'} } or return undef;
    iMSCPTest::Stub::DB::Dbh::_hash( $row, $self->_sql );
}

sub fetchrow_arrayref
{
    my ( $self ) = @_;

    my $row = shift @{ $self->{'rows'} } or return undef;
    iMSCPTest::Stub::DB::Dbh::_array( $row, $self->_sql );
}

sub fetchrow_array
{
    my ( $self ) = @_;

    my $row = $self->fetchrow_arrayref() or return;
    @{ $row };
}

sub fetchall_arrayref
{
    my ( $self, $slice ) = @_;

    my @rows = splice @{ $self->{'rows'} };
    ref $slice eq 'HASH'
        ? [ map { iMSCPTest::Stub::DB::Dbh::_hash( $_, $self->_sql ) } @rows ]
        : [ map { iMSCPTest::Stub::DB::Dbh::_array( $_, $self->_sql ) } @rows ];
}

sub fetchall_hashref
{
    my ( $self, $key ) = @_;

    +{ map { my $row = iMSCPTest::Stub::DB::Dbh::_hash( $_, $self->_sql ); ( $row->{$key} => $row ) } splice @{ $self->{'rows'} } };
}

sub rows { $_[0]->{'count'} // -1 }
sub finish { 1 }

1;
