# i-MSCP listener: keep Courier's IMAPS/POP3S services running.
#
# Install to /etc/imscp/listeners.d/20_saygoweb_courier_ssl.pl
#
# WHY THIS EXISTS
#
# aws1 serves IMAPS on 993 and POP3S on 995, but with SERVICES_SSL_ENABLED set
# to 'no' - the certificates were built by hand from the certbot files by
# /usr/local/bin/courier-combine-ssl, and courier-imap-ssl / courier-pop-ssl
# were enabled directly. i-MSCP never knew about any of it.
#
# On a fresh install that combination does not survive: with
# SERVICES_SSL_ENABLED=no the Courier installer adds both SSL services to its
# disable list (Servers/po/courier/installer.pm:138) and masks them, so 993
# and 995 stop listening on every installer run. Enabling them by hand lasts
# until the next run.
#
# So do the same thing aws1 does, but as a listener: rebuild the two pem files
# from the certbot originals, then unmask, enable and start the services.
#
# The alternative is to set SERVICES_SSL_ENABLED=yes and hand i-MSCP the
# certificate. That is tidier, but it also puts i-MSCP in charge of Postfix's
# TLS settings, which 10_saygoweb_postfix.pl deliberately owns - so it would
# have to be done as one deliberate change, not as a side effect of this.

package Listener::SayGoWeb::CourierSSL;

use strict;
use warnings;
use iMSCP::Debug qw/ debug error warning /;
use iMSCP::EventManager;
use iMSCP::Execute 'execute';
use iMSCP::Service;

my $MAIL_HOSTNAME = 'mail.saygoweb.com';
my $LE_DIR        = "/etc/letsencrypt/live/$MAIL_HOSTNAME";
my @SSL_SERVICES  = qw/ courier-imap-ssl courier-pop-ssl /;

my %PEM = (
    '/etc/courier/imapd.pem' => 1,
    '/etc/courier/pop3d.pem' => 1,
);

iMSCP::EventManager->getInstance()->register(
    'afterPoPostinstall',
    sub {
        unless ( -d $LE_DIR ) {
            warning( sprintf(
                "%s not found; leaving IMAPS/POP3S alone", $LE_DIR
            ));
            return 0;
        }

        # Same content as /usr/local/bin/courier-combine-ssl: the private key
        # followed by the full chain, in one file.
        for my $pem ( sort keys %PEM ) {
            my $rs = execute(
                [ '/bin/sh', '-c',
                  "cat '$LE_DIR/privkey.pem' '$LE_DIR/fullchain.pem' > '$pem'"
                ],
                \my $stdout, \my $stderr
            );
            debug( $stdout ) if length $stdout;
            error( $stderr || 'Unknown error' ) if $rs;
            return $rs if $rs;
            chmod 0600, $pem;
        }

        my $service = iMSCP::Service->getInstance();
        for my $svc ( @SSL_SERVICES ) {
            # The Courier installer masks these when SERVICES_SSL_ENABLED is
            # 'no', and a masked unit cannot be enabled or started - so unmask
            # first, every time.
            my $rs = execute(
                [ '/usr/bin/systemctl', 'unmask', $svc ],
                \my $stdout, \my $stderr
            );
            debug( $stdout ) if length $stdout;

            eval {
                $service->enable( $svc );
                $service->restart( $svc );
            };
            if ( $@ ) {
                error( sprintf( "Couldn't bring up %s: %s", $svc, $@ ));
                return 1;
            }
            debug( sprintf( '%s enabled and started', $svc ));
        }

        0;
    },
    -99
);

1;
__END__
