=head1 NAME

 iMSCP::DiskUsage - Parse disk usage figures for imscp-dsk-quota

=cut

package iMSCP::DiskUsage;

use strict;
use warnings;

=head1 DESCRIPTION

 Pure functions, with no database or filesystem access, that turn the output
 of `du -B1 --max-depth=1 <maildomain dir>` into an account total and
 per-mailbox sizes.

=head1 PUBLIC FUNCTIONS

=over 4

=item parseDuMaxDepth1( $stdout, $domainDir )

 Parse du output for a mail domain directory

 Param string $stdout Output of du -B1 --max-depth=1 $domainDir
 Param string $domainDir Mail domain directory
 Return list ( int $totalBytes, hashref { <mail_acc> => bytes }, bool $complete ).
        $complete is true when the output has the line for the domain directory
        itself, which du prints last: the scan finished, even if du exited
        non-zero because files vanished meanwhile. Without that line (du died
        part way), the total is the sum of the mailbox lines

=cut

sub parseDuMaxDepth1
{
    my ( $stdout, $domainDir ) = @_;

    $domainDir =~ s%/+$%%;
    my ( $total, %byAcc );
    my $complete = 0;

    for my $line ( split /\n/, $stdout // '' ) {
        next unless $line =~ /^(\d+)\t(.+)$/;
        my ( $bytes, $path ) = ( $1, $2 );
        $path =~ s%/+$%%;

        if ( $path eq $domainDir ) {
            $total = $bytes;
            $complete = 1;
        } elsif ( index( $path, "$domainDir/" ) == 0 ) {
            my $acc = substr( $path, length( $domainDir ) + 1 );
            $byAcc{$acc} = $bytes unless index( $acc, '/' ) >= 0;
        }
    }

    unless ( defined $total ) {
        $total = 0;
        $total += $_ for values %byAcc;
    }

    ( $total, \%byAcc, $complete );
}

=item mapMailboxUsage( $domainName, \%bytesByAcc, \@mailAddrs )

 Map mailbox directory sizes to mail addresses of the given domain

 Param string $domainName Domain name of the mail directory
 Param hashref \%bytesByAcc Sizes by mailbox directory name (mail_acc)
 Param arrayref \@mailAddrs Mail addresses of the account, all domains
 Return hashref { <mail_addr> => bytes } for every address of $domainName; an
        address without a directory gets 0

=cut

sub mapMailboxUsage
{
    my ( $domainName, $byAcc, $mailAddrs ) = @_;

    my %usage;
    for my $addr ( @{ $mailAddrs } ) {
        next unless $addr =~ /^(.+)\@\Q$domainName\E$/i;
        $usage{$addr} = $byAcc->{$1} // 0;
    }

    \%usage;
}

=back

=cut

1;
__END__
