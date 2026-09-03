# i-MSCP listener: put the arkwebhost name servers in every zone.
#
# Install to /etc/imscp/listeners.d/30_saygoweb_named_ns.pl
#
# WHY THIS EXISTS
#
# i-MSCP names the servers after the zone it is writing. Servers/named/bind.pm
# walks [ domain IP, SECONDARY_DNS ] and numbers them off, so every zone comes
# out with
#
#   @  IN  SOA  ns1.<domain>. hostmaster.<domain>. (...)
#   @  IN  NS   ns1              ns1  IN  A  <domain IP>
#   @  IN  NS   ns2              ns2  IN  A  52.35.134.194
#
# but nothing is delegated to those names. The registrar entries point at
# ns4.arkwebhost.net (this box, 34.212.49.11) and ns3.arkwebhost.net (aws2,
# 52.35.134.194) - checked against the TLD servers for all 189 zones, 156 of
# which delegate to exactly that pair and none of which delegate to
# ns1.<its own domain>. So the child NS RRset has disagreed with the parent all
# along, and the ns1/ns2 glue serves nothing.
#
# This listener replaces both, and moves the SOA MNAME to ns4 so the primary
# named in the zone is the box that actually holds it.
#
# HOW IT TURNS OFF THE BUILT-IN GENERATOR
#
# beforeNamedAddDmnDb fires before bind.pm reads its NS and glue blocs
# (bind.pm:891-905). replaceBloc drops the marker comments along with the
# content, so the getBloc calls that follow come back empty and the ns<N> loop
# is skipped entirely. Nothing here has to fight it afterwards.
#
# NO GLUE RECORDS
#
# The bloc is emptied rather than filled. ns1-ns4.arkwebhost.net are custom DNS
# records in the panel (domain_dns, TTL 3600), which is where their addresses
# have always come from - a custom RR overrides a default RR of the same
# name/type (bind.pm:530-560), so the template's glue was being discarded in
# that zone anyway. Every other zone is out-of-zone for these names and must
# not carry glue for them.
#
# arkwebhost.net is skipped. Its own delegation in .net still lists ns1 and ns2
# alongside ns3 and ns4, so that zone gets changed deliberately, not as a side
# effect of a panel edit.

package Listener::SayGoWeb::Named::NS;

use strict;
use warnings;
use iMSCP::Debug 'warning';
use iMSCP::EventManager;
use iMSCP::TemplateParser qw/ getBloc process replaceBloc /;

# Authoritative servers for every zone this box writes, in order. The first is
# also used as the SOA MNAME, so it must be the master (this box).
my @NAME_SERVERS = qw/ ns4.arkwebhost.net ns3.arkwebhost.net /;

# Zones left with the stock ns1/ns2 naming. Punycode for IDNs.
my @SKIP_ZONES = qw/ arkwebhost.net /;

my $NS_BLOC_BEGIN   = "; domain NS records BEGIN\n";
my $NS_BLOC_ENDING  = "; domain NS records ENDING\n";
my $GLUE_BLOC_BEGIN = "; domain NS GLUE records BEGIN\n";
my $GLUE_BLOC_END   = "; domain NS GLUE records ENDING\n";

iMSCP::EventManager->getInstance()->register(
    'beforeNamedAddDmnDb',
    sub {
        my ( $tplFileC, $data ) = @_;

        return 0 if grep { $_ eq $data->{'DOMAIN_NAME'} } @SKIP_ZONES;

        my $nsTpl = getBloc( $NS_BLOC_BEGIN, $NS_BLOC_ENDING, ${ $tplFileC } );

        # A template that no longer carries the blocs is one this listener has
        # not been updated for. Say so and leave the zone to i-MSCP rather than
        # failing the domain outright.
        unless ( length $nsTpl ) {
            warning( sprintf(
                "No '%s' bloc in the zone template for %s; leaving the NS "
                    . "records alone",
                'domain NS records', $data->{'DOMAIN_NAME'}
            ));
            return 0;
        }

        my $mname = $NAME_SERVERS[0] . '.';
        unless ( ${ $tplFileC } =~ s/
            ^ ( \@ \s+ IN \s+ SOA \s+ )
            \S+ \Q.{DOMAIN_NAME}.\E
            ( \s )
        /$1$mname$2/mox ) {
            warning( sprintf(
                "Couldn't rewrite the SOA MNAME for %s; leaving it alone",
                $data->{'DOMAIN_NAME'}
            ));
        }

        my $nsRRs = '';
        $nsRRs .= process( { NS_NAME => $_ . '.' }, $nsTpl ) for @NAME_SERVERS;

        ${ $tplFileC } = replaceBloc(
            $NS_BLOC_BEGIN, $NS_BLOC_ENDING, $nsRRs, ${ $tplFileC }
        );
        ${ $tplFileC } = replaceBloc(
            $GLUE_BLOC_BEGIN, $GLUE_BLOC_END, '', ${ $tplFileC }
        );
        0;
    }
);

1;
__END__
