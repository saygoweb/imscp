#!/usr/bin/perl

use strict;
use warnings;

# i-MSCP preseeding file for the Docker development server.
#
# Unlike ../Vagrant/preseed.pl this one is tracked and needs no editing: every
# value that differs between checkouts is read from the environment, which
# docker-compose.yml fills in from docker/.env. Anything left blank falls back
# to the installer's own default; see ../docs/preseed.pl for the full reference.
#
# The choices below are all "development server in a container" choices:
#
#   * BASE_SERVER_IP is 0.0.0.0 — the container's address is assigned by Docker
#     and changes between runs, so services listen on every interface. This is
#     what ../Vagrant/scripts/provision_imscp.sh appends for the same reason.
#   * LOCAL_DNS_RESOLVER is 'no'. Docker owns /etc/resolv.conf; pointing the
#     container's resolver at the bind9 it just installed breaks name resolution
#     inside the container for everything else.
#   * SSL is off for the panel and for the mail/FTP services. Self-signed
#     certificates only add a click-through to every request against a server
#     reached over a published port on localhost.
#   * The optional package sets default to the cheap end (no AWStats, no
#     webmail, no rootkit scanners) because they add several minutes to an
#     install you will re-run often. Raise them in docker/.env when you need
#     them.

sub env
{
    my ( $name, $default ) = @_;
    my $value = $ENV{$name};
    return $default unless defined $value && length $value;
    $value;
}

%::questions = (
    ###
    ### Mandatory parameters
    ###

    # Services listen on every interface: the container IP is Docker's to choose.
    BASE_SERVER_IP                      => '0.0.0.0',
    ADMIN_PASSWORD                      => env( 'IMSCP_ADMIN_PASSWORD', 'imscp1234' ),
    DEFAULT_ADMIN_ADDRESS               => env( 'IMSCP_ADMIN_EMAIL', 'admin@example.com' ),

    # A fresh MariaDB installed by the installer itself, with unix_socket
    # authentication for root, so no root credentials are needed here.
    SQL_ROOT_USER                       => '',
    SQL_ROOT_PASSWORD                   => '',

    ###
    ### System
    ###

    # Set from the container's hostname/domainname (docker-compose.yml).
    SERVER_HOSTNAME                     => env( 'IMSCP_HOSTNAME', 'imscp.docker.local' ),

    # Left blank on purpose, which makes the installer look the WAN IP up
    # (ipinfo.io, then api.ipify.org) exactly as it does for the Vagrant boxes.
    #
    # There is no value that would work better. With BASE_SERVER_IP at
    # 0.0.0.0, dialogForBaseServerPublicIP() will only skip its dialog for an
    # address that is genuinely public, and under --noprompt a dialog it cannot
    # skip is a hard error ("iMSCP::Dialog::execute: Invalid configuration").
    # Blank is the one input that reaches the lookup and settles it.
    #
    # Set IMSCP_PUBLIC_IP in docker/.env if this machine has no route to those
    # services; any public-range address will do, since nothing here is
    # reachable from a WAN anyway.
    BASE_SERVER_PUBLIC_IP               => env( 'IMSCP_PUBLIC_IP', '' ),
    TIMEZONE                            => env( 'IMSCP_TIMEZONE', 'UTC' ),

    ###
    ### Backup
    ###

    # Nothing here is worth keeping, and the backup cron jobs only add noise.
    BACKUP_IMSCP                        => 'no',
    BACKUP_DOMAINS                      => 'no',

    ###
    ### SQL server
    ###

    SQL_SERVER                          => '',
    DATABASE_HOST                       => 'localhost',
    DATABASE_PORT                       => '3306',
    DATABASE_USER                       => 'imscp_user',
    DATABASE_PASSWORD                   => env( 'IMSCP_DATABASE_PASSWORD', 'imscp1234' ),
    DATABASE_USER_HOST                  => 'localhost',
    DATABASE_NAME                       => 'imscp',
    MYSQL_PREFIX                        => 'none',

    ###
    ### Control panel
    ###

    FRONTEND_SERVER                     => 'nginx',
    # Blank means panel.<SERVER_HOSTNAME>.
    BASE_SERVER_VHOST                   => env( 'IMSCP_PANEL_VHOST', '' ),
    BASE_SERVER_VHOST_HTTP_PORT         => env( 'IMSCP_PANEL_HTTP_PORT', '8880' ),
    BASE_SERVER_VHOST_HTTPS_PORT        => env( 'IMSCP_PANEL_HTTPS_PORT', '8443' ),
    BASE_SERVER_VHOST_PREFIX            => 'http://',
    PANEL_SSL_ENABLED                   => 'no',
    PANEL_SSL_SELFSIGNED_CERTIFICATE    => 'no',
    PANEL_SSL_PRIVATE_KEY_PATH          => '',
    PANEL_SSL_PRIVATE_KEY_PASSPHRASE    => '',
    PANEL_SSL_CA_BUNDLE_PATH            => '',
    PANEL_SSL_CERTIFICATE_PATH          => '',
    # Alternative URLs are subdomains of the panel domain; without a wildcard
    # DNS entry pointing at the container they only produce dead links.
    CLIENT_WEBSITES_ALT_URLS            => 'no',
    ADMIN_LOGIN_NAME                    => env( 'IMSCP_ADMIN_LOGIN', 'admin' ),

    ###
    ### DNS
    ###

    NAMED_SERVER                        => 'bind',
    BIND_MODE                           => 'master',
    PRIMARY_DNS                         => 'no',
    SECONDARY_DNS                       => 'no',
    BIND_IPV6                           => 'no',
    # See the header: Docker manages /etc/resolv.conf.
    LOCAL_DNS_RESOLVER                  => 'no',

    ###
    ### Httpd / PHP
    ###

    HTTPD_SERVER                        => 'apache_php_fpm',
    PHP_SERVER                          => '',
    # 'per_site' is what the PhpSwitcher-style plugins expect, and what the
    # SGW_PhpVersion plugin is developed against.
    PHP_CONFIG_LEVEL                    => 'per_site',
    PHP_FPM_LISTEN_MODE                 => 'uds',

    ###
    ### FTP
    ###

    FTPD_SERVER                         => 'proftpd',
    # Kept short and published verbatim by docker-compose.yml; a passive port
    # has to be reachable on the same number the server advertises. The range
    # has to sit inside 32768-60999 — proftpd's installer validates that, and
    # under --noprompt a rejected value is a hard error rather than a prompt.
    FTPD_PASSIVE_PORT_RANGE             => env( 'IMSCP_FTPD_PASSIVE_PORTS', '32768-32777' ) =~ s/-/ /r,

    ###
    ### Mail
    ###

    MTA_SERVER                          => 'postfix',
    PO_SERVER                           => env( 'IMSCP_PO_SERVER', 'dovecot' ),

    ###
    ### SSL for FTP, IMAP/POP and SMTP
    ###

    SERVICES_SSL_ENABLED                => 'no',
    SERVICES_SSL_SELFSIGNED_CERTIFICATE => 'no',
    SERVICES_SSL_PRIVATE_KEY_PATH       => '',
    SERVICES_SSL_PRIVATE_KEY_PASSPHRASE => '',
    SERVICES_SSL_CA_BUNDLE_PATH         => '',
    SERVICES_SSL_CERTIFICATE_PATH       => '',

    ###
    ### Optional packages
    ###

    WEB_STATISTIC_PACKAGES              => env( 'IMSCP_WEB_STATISTIC_PACKAGES', 'No' ),
    WEB_FTP_CLIENT_PACKAGES             => env( 'IMSCP_WEB_FTP_CLIENT_PACKAGES', 'No' ),
    SQL_ADMIN_TOOL_PACKAGES             => env( 'IMSCP_SQL_ADMIN_TOOL_PACKAGES', 'PhpMyAdmin' ),
    WEB_MAIL_CLIENT_PACKAGES            => env( 'IMSCP_WEB_MAIL_CLIENT_PACKAGES', 'No' ),
    ANTI_ROOTKIT_PACKAGES               => env( 'IMSCP_ANTI_ROOTKIT_PACKAGES', 'No' )
);

1;
__END__
