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

package Listener::SayGoWeb::Courier;

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

#
## authmysqlrc must keep the markers courier-authlib ships
#
# Debian 13's courier-authlib (0.72.4) refuses a configuration file that has
# lost its ##NAME: markers, logging
#
#   marker line not found in /etc/courier/authmysqlrc
#   (probably forgot to run sysconftool after an upgrade)
#
# and then rejecting EVERY login - authmysql returns "REJECT - try next
# module", and with authmysql the only module, all mail authentication fails.
# Buster's 0.68 did not enforce this, which is why aws1 is unaffected.
#
# i-MSCP writes the file from its own bare template, so the markers are gone
# after the first install. Merge its values into the packaged file's structure
# instead, keeping a pristine copy the first time we see one - after that first
# overwrite there is nothing left on disk to learn the structure from.

my $AUTHMYSQLRC = '/etc/courier/authmysqlrc';
my $PRISTINE    = '/etc/courier/authmysqlrc.imscp-pristine';

iMSCP::EventManager->getInstance()->register(
    'afterPoBuildConf',
    sub {
        my ( $cfgTpl, $conffile ) = @_;
        return 0 unless defined $conffile && $conffile eq 'authmysqlrc';
        return 0 unless defined $cfgTpl && defined ${ $cfgTpl };

        # Already marker-bearing? Nothing to do.
        return 0 if ${ $cfgTpl } =~ /^##NAME:/m;

        my $base;
        for my $candidate ( $PRISTINE, $AUTHMYSQLRC ) {
            next unless -f $candidate;
            open my $fh, '<', $candidate or next;
            local $/;
            my $content = <$fh>;
            close $fh;
            next unless defined $content && $content =~ /^##NAME:/m;
            $base = $content;

            unless ( -f $PRISTINE ) {
                if ( open my $out, '>', $PRISTINE ) {
                    print {$out} $content;
                    close $out;
                    chmod 0640, $PRISTINE;
                    debug( "Kept a marker-bearing authmysqlrc at $PRISTINE" );
                }
            }
            last;
        }

        unless ( defined $base ) {
            warning(
                'No marker-bearing authmysqlrc found to merge into; '
                . 'courier-authlib 0.72+ will reject this file and all mail '
                . 'logins will fail. Reinstall courier-authlib-mysql to '
                . 'restore the packaged file, then re-run the installer.'
            );
            return 0;
        }

        # Collect what i-MSCP generated, then set those values in the packaged
        # file, leaving every ## line intact.
        my %want;
        for my $line ( split /\n/, ${ $cfgTpl } ) {
            next if $line =~ /^\s*(?:#|$)/;
            my ( $k, $v ) = $line =~ /^(\S+)\s+(.*)$/ or next;
            $want{$k} = $v;
        }

        my ( @out, %seen );
        for my $line ( split /\n/, $base ) {
            if ( my ( $k ) = $line =~ /^(\w+)\s+/ ) {
                if ( exists $want{$k} ) {
                    push @out, "$k\t\t$want{$k}";
                    $seen{$k} = 1;
                    next;
                }
            }
            push @out, $line;
        }

        my @missing = grep { !$seen{$_} } sort keys %want;
        if ( @missing ) {
            push @out, '', '# Added by i-MSCP';
            push @out, map { "$_\t\t$want{$_}" } @missing;
        }

        debug( sprintf(
            'Merged %d i-MSCP setting(s) into the packaged authmysqlrc (%d appended)',
            scalar keys %seen, scalar @missing
        ));

        ${ $cfgTpl } = join( "\n", @out ) . "\n";
        0;
    },
    -99
);

1;
__END__
