#!/usr/bin/perl

use strict;
use warnings;

# ============================================================================
# i-MSCP preseed - aws1 migration, Debian 10 buster -> Debian 13 trixie
#
#   perl imscp-autoinstall -d --preseed /path/to/migrate/preseed.pl
#
# Derived value by value from the old box's /etc/imscp/imscp.conf
# (i-MSCP Git 1.5.x "Ennio Morricone", DISTRO_RELEASE 10.10).
# ============================================================================
#
# --preseed implies --noprompt. In preseed mode setupGetQuestion() returns the
# preseed value or the *hardcoded default* - it does not consult
# %::imscpConfig at all (engine/setup/imscp-setup-functions.pl:625). Restoring
# /etc/imscp/imscp.conf therefore does NOT preserve a setting during a
# preseeded run, which is why every value below is stated explicitly rather
# than left blank.
#
# Coverage: every user-settable question the installer asks is set here. The
# keys deliberately omitted - *_PACKAGE, ADMIN_OLD_LOGIN_NAME, IPV6_SUPPORT,
# *_SSL_HAS_VALID_CHAIN - are derived by the installer and must not be
# preseeded.
#
# ---------------------------------------------------------------------------
# What this file cannot carry
# ---------------------------------------------------------------------------
#
# 1. SYSTEM_USER_MIN_UID is not a question, and is not a UID floor.
#
#    It never reaches useradd. It is a *name* offset:
#
#        Modules/User.pm:111    $user = $group =
#            SYSTEM_USER_PREFIX . ( SYSTEM_USER_MIN_UID + admin_id )
#
#    so admin_id 6 becomes 'vu2006'. The numeric uid is whatever useradd
#    allocates; Modules/User.pm:133 reads it back with getpwnam() and stores it
#    in admin.admin_sys_uid / admin_sys_gid. Hence aws1 having
#    SYSTEM_USER_MIN_UID = 2000 while its uids run 1003-1196.
#
#    Setting it here does nothing (the modules read %::imscpConfig directly),
#    and changing it in imscp.conf would RENAME every account - vu2006 ->
#    vu1006. It stays 2000. The numeric uids are reproduced by
#    scripts/30-restore-users.sh before the installer runs.
#
# 2. Four /etc/imscp templates were hand-edited on aws1 and are <copy_config>
#    in install.xml, so the installer overwrites them from the repository
#    (autoinstaller/Functions.pm:911). Only one is load-bearing:
#
#      php/fpm/php.ini    memory_limit 512M (stock 64M)
#
#    That one is fixed in this fork rather than in /etc, so it survives every
#    future run. See migrate/README.md.
#
# 3. The Postfix customisations are reinstated by
#    migrate/listeners/10_saygoweb_postfix.pl.
# ---------------------------------------------------------------------------

# The master SQL password, in clear. Kept out of the repository: export it, or
# put it in an untracked migrate/secrets.sh that the scripts source.
#
# The base64 value in the old imscp.conf is Rijndael-CBC ciphertext
# under /etc/imscp/imscp-db-keys, NOT the password. The installer encrypts the
# cleartext itself (Servers/sqld/mysql/installer.pm:452).
my $MASTER_SQL_PASSWORD = $ENV{'IMSCP_MASTER_SQL_PASSWORD'} or die <<'ERR';

IMSCP_MASTER_SQL_PASSWORD is not set.

Leaving DATABASE_PASSWORD blank under --preseed does not fall back to
imscp.conf - it silently rotates the master SQL user's password to a fresh
random string. Export the real one before running the installer:

    export IMSCP_MASTER_SQL_PASSWORD='...'

ERR

%::questions = (
    #
    ## Mandatory
    #

    # 0.0.0.0 on aws1 (EC2) - services listen on all interfaces.
    BASE_SERVER_IP                      => '0.0.0.0',

    # MUST be empty for a migration, and this is not a style preference.
    #
    # Package/FrontEnd.pm:1628 upserts the master admin with
    #
    #     `admin_pass` = IF(LENGTH(?) > 0, ?, `admin_pass`)
    #
    # so an empty value preserves the password already in the restored
    # database and any non-empty value REPLACES it. The setup dialog is
    # skipped either way once the admin row exists (:1094), which makes a
    # placeholder here look harmless while silently resetting the panel
    # password - the failure only shows up when someone tries to log in.
    ADMIN_PASSWORD                      => '',

    DEFAULT_ADMIN_ADDRESS               => 'cambell.prince@gmail.com',

    # Trixie's MariaDB root uses unix_socket authentication.
    SQL_ROOT_USER                       => '',
    SQL_ROOT_PASSWORD                   => '',

    #
    ## System
    #

    SERVER_HOSTNAME                     => 'aws1.saygoweb.com',

    # The Elastic IP moves with the box, so this is unchanged from aws1.
    BASE_SERVER_PUBLIC_IP               => '34.212.49.11',

    TIMEZONE                            => 'UTC',

    #
    ## Backup
    #

    BACKUP_IMSCP                        => 'yes',
    BACKUP_DOMAINS                      => 'no',

    #
    ## SQL server
    #

    # aws1 ran mariadb_10.3, which is not an alternative on trixie.
    # DebianAdapter.pm:998 resets an unknown alternative and falls back to the
    # distro default; stated explicitly so the run is deterministic.
    SQL_SERVER                          => 'mariadb_11.8',
    KEEP_LOCAL_SQL_SERVER               => 'yes',

    DATABASE_HOST                       => 'localhost',
    DATABASE_PORT                       => '3306',
    DATABASE_USER                       => 'imscp_user',
    DATABASE_PASSWORD                   => $MASTER_SQL_PASSWORD,
    DATABASE_USER_HOST                  => 'localhost',
    DATABASE_NAME                       => 'imscp',
    MYSQL_PREFIX                        => 'none',

    #
    ## Control panel
    #

    FRONTEND_SERVER                     => 'nginx',
    BASE_SERVER_VHOST                   => 'my.saygoweb.com',
    BASE_SERVER_VHOST_HTTP_PORT         => '8880',
    BASE_SERVER_VHOST_HTTPS_PORT        => '8443',
    BASE_SERVER_VHOST_PREFIX            => 'https://',
    PANEL_SSL_ENABLED                   => 'yes',

    # aws1 used a real certificate for the panel. The installer assembles
    # /etc/imscp/my.saygoweb.com.pem from these three inputs; pointing them at
    # the certbot originals keeps renewal meaningful. NOTE: certbot renewing
    # does not rebuild that pem - see README, "Panel certificate renewal".
    PANEL_SSL_SELFSIGNED_CERTIFICATE    => 'no',
    PANEL_SSL_PRIVATE_KEY_PATH          => '/etc/letsencrypt/live/my.saygoweb.com/privkey.pem',
    PANEL_SSL_PRIVATE_KEY_PASSPHRASE    => '',
    PANEL_SSL_CA_BUNDLE_PATH            => '/etc/letsencrypt/live/my.saygoweb.com/chain.pem',
    PANEL_SSL_CERTIFICATE_PATH          => '/etc/letsencrypt/live/my.saygoweb.com/cert.pem',

    CLIENT_WEBSITES_ALT_URLS            => 'no',

    # Blank => taken from the restored database.
    ADMIN_LOGIN_NAME                    => '',

    #
    ## DNS
    #

    NAMED_SERVER                        => 'bind',
    BIND_MODE                           => 'master',

    # Unchanged: the public IP follows the box, so every generated zone keeps
    # the NS records it already has.
    PRIMARY_DNS                         => '34.212.49.11',
    SECONDARY_DNS                       => '52.35.134.194',

    BIND_IPV6                           => 'no',
    LOCAL_DNS_RESOLVER                  => 'yes',

    #
    ## Httpd / PHP
    #

    HTTPD_SERVER                        => 'apache_php_fpm',

    # php7.4 is still published for debian13 by packages.sury.org (verified
    # against the repository index: 7.4.33), so the 192 existing per-site pools
    # reproduce as they are. Moving customers to a supported PHP is a separate
    # exercise, done per site from the panel afterwards.
    PHP_SERVER                          => 'php7.4',
    PHP_CONFIG_LEVEL                    => 'per_site',
    PHP_FPM_LISTEN_MODE                 => 'uds',

    #
    ## FTP
    #

    FTPD_SERVER                         => 'proftpd',
    # aws1's range, wider than the 32800 33800 default.
    FTPD_PASSIVE_PORT_RANGE             => '32768 60999',

    #
    ## Mail
    #

    MTA_SERVER                          => 'postfix',

    # Courier, not the trixie default (dovecot): it is what the maildirs and
    # authmysqlrc already expect. Supported on trixie - the package list was
    # fixed in 5815b50.
    PO_SERVER                           => 'courier',

    # aws1 had SERVICES_SSL_ENABLED = no: TLS for smtp/imap/pop was wired up by
    # hand against /etc/postfix/tls/mail.saygoweb.com.pem rather than by
    # i-MSCP. Kept off here; reinstated by the Postfix listener.
    SERVICES_SSL_ENABLED                => 'no',
    SERVICES_SSL_SELFSIGNED_CERTIFICATE => '',
    SERVICES_SSL_PRIVATE_KEY_PATH       => '',
    SERVICES_SSL_PRIVATE_KEY_PASSPHRASE => '',
    SERVICES_SSL_CA_BUNDLE_PATH         => '',
    SERVICES_SSL_CERTIFICATE_PATH       => '',

    #
    ## Addon packages - as on aws1
    #

    WEB_STATISTIC_PACKAGES              => 'AWStats',
    WEB_FTP_CLIENT_PACKAGES             => 'MonstaFTP',
    SQL_ADMIN_TOOL_PACKAGES             => 'PhpMyAdmin',
    WEB_MAIL_CLIENT_PACKAGES            => 'RainLoop,Roundcube',
    ANTI_ROOTKIT_PACKAGES               => 'Chkrootkit,Rkhunter'
);

1;
__END__
