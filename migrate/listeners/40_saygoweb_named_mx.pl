# i-MSCP listener: point the MX at the mail server's real name.
#
# Install to /etc/imscp/listeners.d/40_saygoweb_named_mx.pl
#
# WHY THIS EXISTS
#
# The zone templates name the mail exchanger after the zone, so every zone with
# mail hosted here published
#
#   @  IN  MX  10  mail.<domain>.        (and mail.<sub>.<domain>. for subdomains)
#
# while the machine behind it answers as mail.saygoweb.com - that is Postfix's
# myhostname, the PTR for 34.212.49.11, and the only name on the certificate
# (single SAN, no tls_server_sni_maps). A sending MTA validates the certificate
# against the MX hostname, not the recipient domain, so the name it was handed
# never matched the name it got.
#
# Nothing failed on that, because opportunistic STARTTLS does not check names
# at all. It does mean neither MTA-STS nor DANE could ever be turned on: both
# require the MX hostname to be covered by the certificate, and DANE would
# additionally want DNSSEC on whichever zone holds the MX target - one zone if
# it is ours, 146 registrars' worth if it is the customers'. This is the same
# reasoning behind Exchange Online moving its MX records onto mx.microsoft.
#
# So publish the name that is already true everywhere else. One certificate
# covers every domain, and moving the mail host later is one A record.
#
# WHAT IS DELIBERATELY LEFT ALONE
#
# The per-domain mail/imap/pop/pop3/smtp A records stay. They are what customer
# mail clients are configured with, and dropping them would break every one of
# those on the same day - they hit the same certificate mismatch, but on a
# dialog a human sees, and that is a migration to run separately.
#
# Domains on external mail are untouched without needing a check here: their
# MAIL_ENABLED is false, so bind.pm empties the whole mail bloc (bind.pm:945-968
# for zones, bind.pm:341-348 for subdomains) after this listener has run.

package Listener::SayGoWeb::Named::MX;

use strict;
use warnings;
use iMSCP::Debug 'warning';
use iMSCP::EventManager;

# Fully qualified below, so it must resolve on its own and carry the
# certificate this box serves on port 25.
my $MX_TARGET = 'mail.saygoweb.com.';

# '@ IN MX 10 mail' in db.tpl (tab-separated) and db_sub.tpl (space before the
# name), where 'mail' is relative to the zone or subdomain origin.
sub _rewriteMX
{
    my ( $tplFileC, $zone ) = @_;

    return if ${ $tplFileC } =~ s/
        ^ ( \@ [\t ]+ IN [\t ]+ MX [\t ]+ \d+ [\t ]+ )
        mail [\t ]* $
    /$1$MX_TARGET/mx;

    # A template that no longer carries that line is one this listener has not
    # been updated for. Say so and leave the zone to i-MSCP rather than failing
    # the domain outright.
    warning( sprintf(
        "Couldn't rewrite the MX record for %s; leaving it alone", $zone
    ));
}

my $events = iMSCP::EventManager->getInstance();

$events->register( 'beforeNamedAddDmnDb', sub
{
    my ( $tplFileC, $data ) = @_;

    _rewriteMX( $tplFileC, $data->{'DOMAIN_NAME'} );
    0;
} );

# Note the three parameters: the parent zone, then the subdomain entry, which
# is the one holding the MX (bind.pm:316).
$events->register( 'beforeNamedAddSub', sub
{
    my ( undef, $subEntry, $data ) = @_;

    _rewriteMX( $subEntry, $data->{'DOMAIN_NAME'} );
    0;
} );

1;
__END__
