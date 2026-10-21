package iMSCPTest::Fixture;

# Panel-shaped rows for the integration tests: what the panel writes when a
# reseller adds a customer or a customer adds a subdomain, left with status
# 'toadd' for the engine. Mirrors gui/public/reseller/user_add3.php and
# gui/public/client/subdomain_add.php.
#
#   my $c = customer( label => 'named' );            # named-<pid>.test
#   my $s = subdomain( $c, 'sub' );                  # sub.named-<pid>.test
#   run_engine();
#   schedule( $_, 'todelete' ) for $s, $c;
#   run_engine();

use strict;
use warnings;
use Carp qw/ croak /;
use iMSCPTest::Engine qw/ dbh /;
use parent 'Exporter';

our @EXPORT_OK = qw/ test_name reseller customer subdomain schedule /;

my %USED;

sub test_name
{
    my ( $label ) = @_;

    defined $label && $label =~ /^[a-z0-9-]+$/ or croak(
        'test_name needs a label of lower-case letters, digits and dashes'
    );
    my $name = "$label-$$.test";
    croak( "test_name: $name is already used in this run" ) if $USED{$name}++;
    $name;
}

my %CHECKED;

# Insert a row and return its id. The first insert into each table checks the
# live schema, so that a panel schema change stops the fixture with a reason.
sub _insert
{
    my ( $table, %row ) = @_;

    unless ( $CHECKED{$table}++ ) {
        my $columns = dbh()->selectall_arrayref( "SHOW COLUMNS FROM `$table`", { Slice => {} } );
        my %have = map { $_->{'Field'} => 1 } @{ $columns };
        my @unknown = grep { !$have{$_} } sort keys %row;
        my @unset = map { $_->{'Field'} } grep {
            $_->{'Null'} eq 'NO' && !defined $_->{'Default'} && $_->{'Extra'} !~ /auto_increment/
                && !exists $row{ $_->{'Field'} }
        } @{ $columns };
        croak( "the $table table has no column @unknown: the fixture no longer matches the panel's schema" ) if @unknown;
        croak( "the fixture does not set @unset in $table, which has no default: the panel's schema has moved on" ) if @unset;
    }

    my @columns = sort keys %row;
    dbh()->do(
        sprintf(
            'INSERT INTO `%s` (%s) VALUES (%s)',
            $table, join( ', ', map { "`$_`" } @columns ), join( ', ', ( '?' ) x @columns )
        ),
        undef, @row{@columns}
    );
    ( dbh()->selectrow_array( 'SELECT LAST_INSERT_ID()' ) )[0];
}

# Customers need a reseller. One serves the whole container.
sub reseller
{
    my ( $id ) = dbh()->selectrow_array( "SELECT admin_id FROM admin WHERE admin_name = 'citest-reseller'" );
    return $id if $id;

    my ( $adminId ) = dbh()->selectrow_array(
        "SELECT admin_id FROM admin WHERE admin_type = 'admin' ORDER BY admin_id LIMIT 1"
    );
    $adminId or croak( 'there is no admin account: is i-MSCP installed?' );

    _insert(
        'admin',
        admin_name     => 'citest-reseller',
        admin_pass     => '!',
        admin_type     => 'reseller',
        created_by     => $adminId,
        email          => 'reseller@citest.test',
        domain_created => time(),
        admin_status   => 'ok'
    );
}

sub customer
{
    my ( %domain ) = @_;

    my $name = test_name( delete $domain{'label'} // 'customer' );
    my ( $ipId ) = dbh()->selectrow_array( 'SELECT ip_id FROM server_ips ORDER BY ip_id LIMIT 1' );
    $ipId or croak( 'there is no server IP' );

    my $adminId = _insert(
        'admin',
        admin_name     => $name,
        admin_pass     => '!',
        admin_type     => 'user',
        created_by     => reseller(),
        email          => "admin\@$name",
        domain_created => time(),
        admin_status   => 'toadd'
    );
    my $domainId = _insert(
        'domain',
        domain_name                   => $name,
        domain_admin_id               => $adminId,
        domain_created                => time(),
        domain_expires                => 0,
        domain_mailacc_limit          => 0,
        domain_ftpacc_limit           => 0,
        domain_traffic_limit          => 0,
        domain_sqld_limit             => 0,
        domain_sqlu_limit             => 0,
        domain_status                 => 'toadd',
        domain_alias_limit            => 0,
        domain_subd_limit             => 0,
        domain_ip_id                  => $ipId,
        domain_disk_limit             => 0,
        domain_disk_usage             => 0,
        domain_php                    => 'yes',
        domain_cgi                    => 'no',
        allowbackup                   => 'dmn|sql|mail',
        domain_dns                    => 'no',
        phpini_perm_system            => 'no',
        phpini_perm_allow_url_fopen   => 'no',
        phpini_perm_display_errors    => 'no',
        phpini_perm_disable_functions => 'no',
        phpini_perm_mail_function     => 'yes',
        domain_external_mail          => 'no',
        web_folder_protection         => 'yes',
        mail_quota                    => 0,
        url_forward                   => 'no',
        type_forward                  => undef,
        host_forward                  => 'Off',
        wildcard_alias                => 'no',
        %domain
    );
    _insert( 'php_ini', admin_id => $adminId, domain_id => $domainId, domain_type => 'dmn' );
    _insert( 'user_gui_props', user_id => $adminId, lang => 'auto', layout => 'default' );

    +{
        type      => 'customer',
        name      => $name,
        admin_id  => $adminId,
        domain_id => $domainId,
        rows      => [
            { table => 'admin', key => 'admin_id', status => 'admin_status', id => $adminId },
            { table => 'domain', key => 'domain_id', status => 'domain_status', id => $domainId }
        ]
    };
}

sub subdomain
{
    my ( $customer, $label ) = @_;

    ref $customer eq 'HASH' && $customer->{'type'} eq 'customer' or croak( 'subdomain needs a customer' );
    defined $label && $label =~ /^[a-z0-9-]+$/ or croak( 'subdomain needs a label' );

    my $id = _insert(
        'subdomain',
        domain_id                => $customer->{'domain_id'},
        subdomain_name           => $label,
        subdomain_mount          => "/$label",
        subdomain_document_root  => '/htdocs',
        subdomain_url_forward    => 'no',
        subdomain_type_forward   => undef,
        subdomain_host_forward   => 'Off',
        subdomain_wildcard_alias => 'no',
        subdomain_status         => 'toadd'
    );
    _insert( 'php_ini', admin_id => $customer->{'admin_id'}, domain_id => $id, domain_type => 'sub' );

    +{
        type         => 'subdomain',
        name         => "$label.$customer->{'name'}",
        subdomain_id => $id,
        rows         => [ { table => 'subdomain', key => 'subdomain_id', status => 'subdomain_status', id => $id } ]
    };
}

# Ask the engine to do something to an existing object on its next run, as the
# panel does: deleting a customer marks its admin and domain rows todelete.
sub schedule
{
    my ( $obj, $status ) = @_;

    grep { $status eq $_ } qw/ todelete tochange todisable toenable / or croak( "schedule: unknown status $status" );
    dbh()->do( "UPDATE `$_->{'table'}` SET `$_->{'status'}` = ? WHERE `$_->{'key'}` = ?", undef, $status, $_->{'id'} )
        for @{ $obj->{'rows'} };
}

1;
