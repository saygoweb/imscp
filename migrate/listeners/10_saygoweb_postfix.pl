# i-MSCP listener: reinstate the SayGoWeb Postfix configuration.
#
# Install to /etc/imscp/listeners.d/10_saygoweb_postfix.pl
#
# WHY THIS EXISTS
#
# aws1's /etc/postfix/main.cf and master.cf were edited by hand, but i-MSCP
# regenerates both from its own templates on every installer run. On aws1
# nothing protected them (listeners.d held only the README), so the edits
# survived purely because the installer had not been re-run. On the new box
# they would be lost on first install and on every update after that.
#
# ORDERING
#
# Both hooks register at priority -99. The event manager pops highest priority
# first (EventManager.pm:73), and the Courier installer registers its own
# afterMtaBuildConf listener at the default priority of 1 - so -99 runs last
# and these values win. That matters for smtpd_sasl_auth_enable in particular:
# Courier sets it to 'yes', and aws1 deliberately sets it to 'no' on port 25,
# enabling SASL only on 587/465 through master.cf.
#
# THE SPAMHAUS DQ KEY
#
# The RBL hostnames use a paid Spamhaus Data Query key, which must not live in
# a git repository. It is read at runtime from /etc/postfix/dq-key (one line,
# mode 0600). Without that file the listener falls back to the free public
# zen/dbl zones, which are rate-limited but functional.

package Listener::SayGoWeb::Postfix;

use strict;
use warnings;
use iMSCP::Debug qw/ debug error warning /;
use iMSCP::Execute 'execute';
use iMSCP::EventManager;
use Servers::mta;

#
## Configuration
#

my $MAIL_HOSTNAME = 'mail.saygoweb.com';
my $TLS_CERT      = '/etc/postfix/tls/mail.saygoweb.com.pem';
my $TLS_KEY       = '/etc/postfix/tls/mail.saygoweb.com.key';
my $DQ_KEY_FILE   = '/etc/postfix/dq-key';

sub _dqKey
{
    return '' unless -f $DQ_KEY_FILE;
    open my $fh, '<', $DQ_KEY_FILE or return '';
    chomp( my $key = <$fh> // '' );
    close $fh;
    $key =~ s/^\s+|\s+$//g;
    $key =~ /^[a-z0-9]+$/ ? $key : '';
}

sub _zones
{
    my $key = _dqKey();

    unless ( length $key ) {
        warning( sprintf(
            "%s absent or malformed; falling back to the public Spamhaus zones. "
            . "Rate limits apply on a mail server this size.", $DQ_KEY_FILE
        ));
        return ( 'zen.spamhaus.org', 'dbl.spamhaus.org' );
    }

    debug( 'Using the Spamhaus DQ zones' );
    ( "$key.zen.dq.spamhaus.net", "$key.dbl.dq.spamhaus.net" );
}

#
## main.cf
#

# header_checks above is a pcre: map, and Debian ships PCRE support for Postfix
# in a separate package that i-MSCP does not ask for. Without it the map type
# does not exist, and cleanup(8) rejects every message with
#
#   header_checks map lookup problem -- message not accepted, try again later
#
# which is a total mail outage that looks like a transient failure.
iMSCP::EventManager->getInstance()->registerOne(
    'beforeInstallPackages',
    sub {
        push @{ $_[0] }, 'postfix-pcre';
        0;
    }
);

# Keep it through an uninstall pass, for the same reason.
iMSCP::EventManager->getInstance()->registerOne(
    'beforeUninstallPackages',
    sub {
        @{ $_[0] } = grep { $_ ne 'postfix-pcre' } @{ $_[0] };
        0;
    }
);

iMSCP::EventManager->getInstance()->register(
    'afterMtaBuildConf',
    sub {
        my ( $zen, $dbl ) = _zones();

        my $rblClient  = "reject_rbl_client $zen=127.0.0.[2..4]";
        my $rblStrict  = "reject_rbl_client $zen=127.0.0.[2..11]";
        my $rhsSender  = "reject_rhsbl_sender $dbl=127.0.1.[2..99]";
        my $rhsHelo    = "reject_rhsbl_helo $dbl=127.0.1.[2..99]";
        my $rhsClient  = "reject_rhsbl_reverse_client $dbl=127.0.1.[2..99]";

        my %p = (
            # --- identity -------------------------------------------------
            # i-MSCP would set this to SERVER_HOSTNAME (aws1.saygoweb.com).
            # The mail identity is deliberately separate.
            myhostname                  => [ $MAIL_HOSTNAME ],
            mydomain                    => [ "$MAIL_HOSTNAME.local" ],
            message_size_limit          => [ '0' ],

            # --- virtual delivery ------------------------------------------
            virtual_minimum_uid         => [ '999' ],
            virtual_uid_maps            => [ 'static:999' ],
            virtual_gid_maps            => [ 'static:8' ],

            # --- SASL ------------------------------------------------------
            # Off on 25; master.cf turns it on for submission and smtps.
            smtpd_sasl_auth_enable      => [ 'no' ],
            smtpd_tls_auth_only         => [ 'no' ],

            # --- restriction classes used by master.cf ---------------------
            mua_client_restrictions     => [ 'permit_mynetworks', $rblClient, 'permit' ],
            mua_helo_restrictions       => [ 'permit' ],
            mua_sender_restrictions     => [ 'permit_mynetworks', 'permit_sasl_authenticated', 'reject' ],
            mua_recipient_restrictions  => [
                'reject_non_fqdn_recipient', 'reject_unknown_recipient_domain',
                'permit_mynetworks', 'permit_sasl_authenticated', 'reject'
            ],
            submission_client_restrictions => [
                'permit_mynetworks', 'permit_sasl_authenticated', $rblClient, 'reject'
            ],
            smtps_client_restrictions   => [
                'permit_mynetworks', 'permit_sasl_authenticated', $rblClient, 'reject'
            ],

            # --- smtpd restrictions ----------------------------------------
            smtpd_delay_reject          => [ 'yes' ],
            smtpd_helo_required         => [ 'yes' ],
            smtpd_client_restrictions   => [ 'permit_mynetworks', $rblClient, 'permit' ],
            smtpd_helo_restrictions     => [
                'permit_mynetworks', 'permit_sasl_authenticated',
                'reject_non_fqdn_helo_hostname', 'reject_invalid_helo_hostname', 'permit'
            ],
            smtpd_sender_restrictions   => [
                'permit_mynetworks', 'permit_sasl_authenticated',
                'reject_non_fqdn_sender', 'reject_unknown_sender_domain', 'permit'
            ],
            smtpd_recipient_restrictions => [
                'reject_non_fqdn_recipient', 'reject_unknown_recipient_domain',
                'permit_mynetworks', 'permit_sasl_authenticated', 'reject_unauth_destination',
                $rblStrict, $rhsSender, $rhsHelo, $rhsClient,
                'reject_unlisted_recipient', 'permit'
            ],
            smtpd_data_restrictions     => [
                'reject_multi_recipient_bounce', 'reject_unauth_pipelining'
            ],

            # --- TLS -------------------------------------------------------
            smtpd_tls_cert_file         => [ $TLS_CERT ],
            smtpd_tls_key_file          => [ $TLS_KEY ],
            smtpd_tls_security_level    => [ 'may' ],
            smtp_tls_security_level     => [ 'may' ],
            smtpd_tls_received_header   => [ 'yes' ],
            smtpd_tls_ciphers           => [ 'high' ],
            smtp_tls_ciphers            => [ 'high' ],
            smtpd_tls_exclude_ciphers   => [ 'aNULL', 'MD5' ],
            smtp_tls_exclude_ciphers    => [ 'aNULL', 'MD5' ],
            smtpd_tls_protocols         => [ '!SSLv2', '!SSLv3' ],
            smtp_tls_protocols          => [ '!SSLv2', '!SSLv3' ],
            smtp_tls_CAfile             => [ '/etc/ssl/certs/ca-certificates.crt' ],
            smtpd_tls_session_cache_database => [ 'btree:/var/lib/postfix/smtpd_scache' ],
            smtp_tls_session_cache_database  => [ 'btree:/var/lib/postfix/smtp_scache' ],
            smtpd_tls_session_cache_timeout  => [ '3600s' ],

            # --- SASL config lookup ----------------------------------------
            # Without this, Cyrus SASL on Debian 13 never finds
            # /etc/postfix/sasl/smtpd.conf: it falls back to its own defaults,
            # advertises the full mech list instead of the configured
            # "plain login", uses auxprop rather than authdaemond, and every
            # SMTP AUTH fails with "unable to canonify user and get auxprops".
            # Buster's libsasl2 searched that directory on its own; Trixie's
            # does not. aws1 therefore has no such setting and does not need
            # one.
            cyrus_sasl_config_path      => [ '/etc/postfix/sasl' ],

            # --- local policy ----------------------------------------------
            header_checks               => [ 'pcre:/etc/postfix/header_checks' ],
            rbl_reply_maps              => [ 'hash:$config_directory/dnsbl-reply-map' ]
        );

        my $rs = Servers::mta->factory()->postconf(
            map { $_ => { action => 'replace', values => $p{$_} } } keys %p
        );
        return $rs if $rs;

        # smtpd_relay_restrictions is deliberately EMPTY on aws1: relay policy
        # is carried by smtpd_recipient_restrictions and the master.cf
        # overrides. It cannot go through postconf() above - an empty values
        # list there means "keep whatever is set", and for a parameter never
        # explicitly set that is Postfix's own default, which postconf prints
        # as a conditional macro expression. Round-tripping that writes the
        # literal expression into main.cf, after which every postconf run dies
        # with "macro processing error" and Postfix will not start. Set it
        # directly.
        $rs = execute(
            [ 'postconf', '-e', 'smtpd_relay_restrictions=' ],
            \my $rout, \my $rerr
        );
        debug( $rout ) if length $rout;
        error( $rerr || 'Unknown error' ) if $rs;
        return $rs if $rs;

        # rbl_reply_maps names a hash: table, so Postfix needs the .db, not the
        # source. Nothing else rebuilds it - the file arrives from aws1 as
        # plain text - and postfix starts happily without it, only to fail
        # every lookup at run time.
        for my $map ( '/etc/postfix/dnsbl-reply-map' ) {
            next unless -f $map;
            next if -f "$map.db" && ( stat "$map.db" )[9] >= ( stat $map )[9];
            my $prs = execute( [ 'postmap', $map ], \my $stdout, \my $stderr );
            debug( $stdout ) if length $stdout;
            error( $stderr || 'Unknown error' ) if $prs;
            return $prs if $prs;
        }

        0;
    },
    -99
);

#
## master.cf
#
# MASTER(5): where a service name and type are repeated, the last definition
# wins. Appending is therefore enough to redefine submission and smtps, and
# avoids having to rewrite what i-MSCP and the Courier installer emitted.
#

iMSCP::EventManager->getInstance()->register(
    'afterMtaBuildMasterCfFile',
    sub {
        ${ $_[0] } .= <<'EOF';

# --- SayGoWeb: submission/smtps with SASL and the mua_* restriction classes.
# Redefined here rather than edited above; the last definition wins.
submission inet n       -       y       -       -       smtpd
 -o syslog_name=postfix/submission
 -o smtpd_tls_security_level=may
 -o smtpd_sasl_auth_enable=yes
 -o smtpd_delay_reject=no
 -o smtpd_reject_unlisted_recipient=no
 -o smtpd_client_restrictions=$mua_client_restrictions
 -o smtpd_helo_restrictions=$mua_helo_restrictions
 -o smtpd_sender_restrictions=$mua_sender_restrictions
 -o smtpd_recipient_restrictions=$mua_recipient_restrictions
 -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
smtps     inet n       -       y       -       -       smtpd
 -o syslog_name=postfix/smtps
 -o smtpd_tls_wrappermode=yes
 -o smtpd_sasl_auth_enable=yes
 -o smtpd_delay_reject=no
 -o smtpd_reject_unlisted_recipient=no
 -o smtpd_client_restrictions=$mua_client_restrictions
 -o smtpd_helo_restrictions=$mua_helo_restrictions
 -o smtpd_sender_restrictions=$mua_sender_restrictions
 -o smtpd_recipient_restrictions=$mua_recipient_restrictions
 -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
EOF
        0;
    },
    -99
);

1;
__END__
