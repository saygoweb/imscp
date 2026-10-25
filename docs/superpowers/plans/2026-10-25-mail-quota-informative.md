# Informative mail quota under the disk limit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use cjp:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task, wave by wave per the Execution Schedule. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow a mail quota of 0 alongside a disk limit, record each mailbox's size daily, and show clients and resellers graded disk usage information. Nothing is enforced.

**Architecture:** The daily `imscp-dsk-quota` job gains per-mailbox sizes from one `du --max-depth=1` pass per mail domain, using a new pure module, `iMSCP::DiskUsage`. Two columns hold the new data. The GUI gets a handful of pure helpers in `gui/include/Statistics.php` (state, warning text, mailbox text, quota-limit text, measured-at text, summary text) plus one DB helper. The client and reseller pages call these helpers and never compute thresholds themselves.

**Tech Stack:** Perl 5 (engine, `Test::More` with `prove`), PHP 8.4 (GUI, i-MSCP `TemplateEngine`, jQuery DataTables), MariaDB, PHPUnit 11 (new, run in the `composer:2.8` docker image).

**Spec:** `docs/superpowers/specs/2026-10-25-mail-quota-informative-design.md`

## Global Constraints

- No enforcement is added anywhere. Courier and Dovecot still receive `mail_users.quota` unchanged. Quota 0 means unlimited delivery.
- ProFTPD quotatab is untouched.
- Warning thresholds: approaching at ≥ 80% of the limit, over when usage > limit. A limit of 0 is always `ok`.
- Units: `domain.domain_disk_limit` is MiB. `domain.mail_quota`, `domain.domain_disk_*` usage, `mail_users.quota` and `mail_users.mail_disk_usage` are bytes.
- New columns: `mail_users.mail_disk_usage bigint(20) unsigned not null default '0'` and `domain.domain_disk_usage_time int(10) unsigned default null`. Database revision 288.
- Tests live under `test/perl/` and `test/php/`, never in source directories.
- Test workers are capped: PHPUnit runs single-process (its default). Check the load average (`cat /proc/loadavg`, 1-minute figure < 10.0) before docker work.
- Match surrounding code: 4-space indent, i-MSCP PHP style (`tr()`, `tohtml()`, `exec_query()`), Perl style of `engine/quota/imscp-dsk-quota`.

## Review Focus

1. A mailbox on a subdomain (`a@sub.example.com`) must not be matched to the parent domain's directory (`example.com`): `mapMailboxUsage` anchors on `@<domain>`. Pinned in Task 1.
2. When `du` exits non-zero for a mail directory (an unreadable file, for example), the account total still counts what `du` printed, but that directory's mailboxes keep their previous `mail_disk_usage`. Pinned in Task 1 (the script skips the per-mailbox map on `$rs`; the parser test covers partial output).
3. Usage at exactly 100% of the limit is `approaching`, not `over`. Usage of 0 with a limit is `ok`. Pinned in Task 3.
4. Mailbox list sorting must sort by bytes, not by the human text ("900 MiB" vs "1.2 GiB"). Pinned in Task 5 with the `data-order` attribute.
5. An account that has never been measured (`domain_disk_usage_time` null) says "Not measured yet" and does not print 1970. Pinned in Task 3.

## Execution Schedule

| Wave | Tasks | Model | Notes |
|------|-------|-------|-------|
| 1 | Task 1, Task 2, Task 3, Task 4 | sonnet, haiku, sonnet, sonnet | Parallel: disjoint files. Task 3 pulls the `composer:2.8` image; no other task uses docker. |
| CP1 | — | — | base..end of wave 1 — code-review medium + spec check (spec §1, §2, §3 helpers) — must finish before wave 2, which builds on the helpers |
| 2 | Task 5, Task 6 | sonnet, sonnet | Parallel: Task 5 owns `gui/public/client/*` and `gui/themes/default/client/*`; Task 6 owns the reseller and admin pages. Neither edits `Statistics.php`. |
| CP2 | — | — | base..end of wave 2 — code-review medium + spec check (full spec) |
| 3 | Controller | — | Docker stack manual checks (spec "Manual"), `prove`, `test/php/run.sh`, push, PR, CI green, squash merge, cleanup |

---

### Task 1: Engine — per-mailbox sizes in the daily quota job

**Files:**
- Create: `engine/PerlLib/iMSCP/DiskUsage.pm`
- Modify: `engine/quota/imscp-dsk-quota` (`quotaFiles()`)
- Test: `test/perl/iMSCP-DiskUsage.t`

**Interfaces:**
- Consumes: the columns `mail_users.mail_disk_usage` and `domain.domain_disk_usage_time` (Task 2) at run time only.
- Produces: `iMSCP::DiskUsage::parseDuMaxDepth1( $stdout, $domainDir )` → `( $totalBytes, \%bytesByAcc )` and `iMSCP::DiskUsage::mapMailboxUsage( $domainName, \%bytesByAcc, \@mailAddrs )` → `\%bytesByMailAddr`. The job writes `mail_users.mail_disk_usage` and `domain.domain_disk_usage_time`.

- [ ] **Step 1: Write the failing test** — `test/perl/iMSCP-DiskUsage.t`:

```perl
#!/usr/bin/perl

# Unit tests for iMSCP::DiskUsage, the du output parsing behind imscp-dsk-quota.
#
# Run from the repository root:
#
#   prove -Iengine/PerlLib -Iengine/PerlVendor test/perl

use strict;
use warnings;
use Test::More;
use iMSCP::DiskUsage;

my $dir = '/var/mail/virtual/example.com';

subtest 'several mailboxes and the domain total' => sub {
    my $out = "4096\t$dir/john\n1048576\t$dir/john.doe\n12288\t$dir/info\n1069056\t$dir\n";
    my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1( $out, $dir );
    is $total, 1069056, 'total is the line for the domain directory itself';
    is_deeply $byAcc, { john => 4096, 'john.doe' => 1048576, info => 12288 }, 'one entry per mailbox directory';
};

subtest 'trailing slash on the domain directory' => sub {
    my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1( "10\t$dir/a\n20\t$dir\n", "$dir/" );
    is $total, 20;
    is_deeply $byAcc, { a => 10 };
};

subtest 'empty output' => sub {
    my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1( '', $dir );
    is $total, 0;
    is_deeply $byAcc, {};
};

subtest 'partial output from a failed du still yields what was printed' => sub {
    my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1( "10\t$dir/a\n", $dir );
    is $total, 10, 'without a total line, the total is the sum of the children';
    is_deeply $byAcc, { a => 10 };
};

subtest 'lines outside the domain directory are ignored' => sub {
    my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1(
        "5\t/var/mail/virtual/other.com/x\n10\t$dir/a\n10\t$dir\n", $dir
    );
    is $total, 10;
    is_deeply $byAcc, { a => 10 };
};

subtest 'mapping to mail addresses' => sub {
    my $map = iMSCP::DiskUsage::mapMailboxUsage(
        'example.com',
        { john => 4096, 'john.doe' => 1048576, leftover => 999 },
        [ 'john@example.com', 'john.doe@example.com', 'new@example.com', 'a@sub.example.com', 'b@other.com' ]
    );
    is_deeply $map, {
        'john@example.com'     => 4096,
        'john.doe@example.com' => 1048576,
        'new@example.com'      => 0,
    }, 'mailboxes of this domain only; no directory means 0; leftover directories are not mapped';
};

subtest 'mapping ignores case in the domain part' => sub {
    my $map = iMSCP::DiskUsage::mapMailboxUsage( 'Example.com', { a => 1 }, [ 'a@example.COM' ] );
    is_deeply $map, { 'a@example.COM' => 1 };
};

done_testing();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `prove -Iengine/PerlLib -Iengine/PerlVendor test/perl/iMSCP-DiskUsage.t`
Expected: FAIL with "Can't locate iMSCP/DiskUsage.pm".

- [ ] **Step 3: Write the module** — `engine/PerlLib/iMSCP/DiskUsage.pm`:

```perl
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
 Return list ( int $totalBytes, hashref { <mail_acc> => bytes } ). When the
        output has no line for the domain directory itself (du failed part
        way), the total is the sum of the mailbox lines

=cut

sub parseDuMaxDepth1
{
    my ( $stdout, $domainDir ) = @_;

    $domainDir =~ s%/+$%%;
    my ( $total, %byAcc );

    for my $line ( split /\n/, $stdout // '' ) {
        next unless $line =~ /^(\d+)\t(.+)$/;
        my ( $bytes, $path ) = ( $1, $2 );
        $path =~ s%/+$%%;

        if ( $path eq $domainDir ) {
            $total = $bytes;
        } elsif ( index( $path, "$domainDir/" ) == 0 ) {
            my $acc = substr( $path, length( $domainDir ) + 1 );
            $byAcc{$acc} = $bytes unless index( $acc, '/' ) >= 0;
        }
    }

    unless ( defined $total ) {
        $total = 0;
        $total += $_ for values %byAcc;
    }

    ( $total, \%byAcc );
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `prove -Iengine/PerlLib -Iengine/PerlVendor test/perl/iMSCP-DiskUsage.t`
Expected: PASS (7 subtests).

- [ ] **Step 5: Use the module in `engine/quota/imscp-dsk-quota`**

Add `use iMSCP::DiskUsage;` after `use iMSCP::Debug ...;`.

In `quotaFiles()`, replace the `@items` construction so each mail item carries its domain name:

```perl
            my @items = (
                { webdir => "$::imscpConfig{'USER_WEB_DIR'}/$dmnData->{'domain_name'}" },
                {
                    maildir => "$virtualMailDir/$dmnData->{'domain_name'}",
                    domain  => $dmnData->{'domain_name'}
                }
            );
```

and the push for child domains:

```perl
                push @items, { maildir => "$virtualMailDir/$_", domain => $_ } for keys %{$rows2};
```

After the `$rows2` block and before `for( @items )`, load the account's mailboxes:

```perl
            my %mailboxUsage;
            my $mailAddrs = eval {
                $dbh->selectcol_arrayref(
                    "SELECT mail_addr FROM mail_users WHERE domain_id = ? AND mail_type LIKE '%\\_mail%'",
                    undef, $dmnId
                );
            };
            if ( $@ ) {
                error( $@ );
                $mailAddrs = [];
            }
```

Replace the whole `for( @items ) { ... }` loop with:

```perl
            for( @items ) {
                if ( exists $_->{'webdir'} ) {
                    my $dir = $_->{'webdir'};
                    next unless -d $dir;

                    my $rs = execute(
                        [ 'du', '--exclude=backups/*', '--exclude=logs/*', '-s', '-B1', $dir ], \ my $stdout,
                        \ my $stderr
                    );
                    error( $stderr || 'Unknown error' ) if $rs;
                    $webDiskUsage = $1 if $stdout && $stdout =~ /^(\d+)/;
                    next;
                }

                my ( $dir, $domain ) = @{$_}{qw/ maildir domain /};

                unless ( -d $dir ) {
                    # No mail directory yet: none of this domain's mailboxes holds anything
                    my $map = iMSCP::DiskUsage::mapMailboxUsage( $domain, {}, $mailAddrs );
                    @mailboxUsage{keys %{$map}} = values %{$map};
                    next;
                }

                my $rs = execute( [ 'du', '-B1', '--max-depth=1', $dir ], \ my $stdout, \ my $stderr );
                error( $stderr || 'Unknown error' ) if $rs;

                my ( $total, $byAcc ) = iMSCP::DiskUsage::parseDuMaxDepth1( $stdout, $dir );
                $mailDiskUsage += $total;

                # A failed du leaves these mailboxes at their previous figures
                next if $rs;

                my $map = iMSCP::DiskUsage::mapMailboxUsage( $domain, $byAcc, $mailAddrs );
                @mailboxUsage{keys %{$map}} = values %{$map};
            }
```

In the transaction, replace the `UPDATE domain` statement and add the mailbox updates:

```perl
                $dbh->do(
                    '
                        UPDATE domain
                        SET domain_disk_usage = ?, domain_disk_file = ?, domain_disk_mail = ?,
                            domain_disk_usage_time = UNIX_TIMESTAMP()
                        WHERE domain_id = ?
                    ',
                    undef, $totalDiskUsage, $webDiskUsage, $mailDiskUsage, $dmnId
                );
                $dbh->do(
                    'UPDATE mail_users SET mail_disk_usage = ? WHERE mail_addr = ?', undef, $mailboxUsage{$_}, $_
                ) for keys %mailboxUsage;
```

Leave the `quotatallies` update and `quotaSql()` unchanged.

- [ ] **Step 6: Syntax-check the script and rerun all Perl tests**

Run: `perl -Iengine/PerlLib -Iengine/PerlVendor -c engine/quota/imscp-dsk-quota`
Expected: `engine/quota/imscp-dsk-quota syntax OK`. If it fails only because a production-only module is missing on this host (not on `iMSCP::DiskUsage` or a syntax error), record that and rely on the controller's docker check.

Run: `prove -Iengine/PerlLib -Iengine/PerlVendor test/perl`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add engine/PerlLib/iMSCP/DiskUsage.pm engine/quota/imscp-dsk-quota test/perl/iMSCP-DiskUsage.t
git commit -m "engine: record each mailbox's size in the daily disk quota job"
```

---

### Task 2: Database — new usage columns (revision 288)

**Files:**
- Modify: `gui/src/Update/DatabaseUpdate.php` (`$lastUpdate`, new `r288()` after `r287()`)
- Modify: `configs/debian/default/database/database.sql` (domain table, mail_users table, `DATABASE_REVISION`)

**Interfaces:**
- Produces: `mail_users.mail_disk_usage` and `domain.domain_disk_usage_time`, as in Global Constraints.

- [ ] **Step 1: Add the update** — in `gui/src/Update/DatabaseUpdate.php`, set `protected $lastUpdate = 288;` and add after `r287()`:

```php
    /**
     * Add per-mailbox disk usage and the time an account's disk usage was measured
     *
     * @return array SQL statements to be executed
     */
    protected function r288()
    {
        return [
            $this->addColumn(
                'mail_users', 'mail_disk_usage', "bigint(20) unsigned NOT NULL DEFAULT '0' AFTER quota"
            ),
            $this->addColumn(
                'domain', 'domain_disk_usage_time', 'int(10) unsigned DEFAULT NULL AFTER domain_disk_sql'
            )
        ];
    }
```

- [ ] **Step 2: Update the fresh-install schema** — in `configs/debian/default/database/database.sql`:
  - change `('DATABASE_REVISION', '287');` to `('DATABASE_REVISION', '288');`
  - after `` `domain_disk_sql` bigint(20) unsigned not null default '0',`` add `` `domain_disk_usage_time` int(10) unsigned default null,``
  - in `mail_users`, after `` `quota` bigint(20) unsigned not null default '0',`` add `` `mail_disk_usage` bigint(20) unsigned not null default '0',``

- [ ] **Step 3: Check the PHP parses**

Run: `php -l gui/src/Update/DatabaseUpdate.php`
Expected: `No syntax errors detected`.

- [ ] **Step 4: Commit**

```bash
git add gui/src/Update/DatabaseUpdate.php configs/debian/default/database/database.sql
git commit -m "db: add mailbox disk usage and disk usage measurement time (r288)"
```

---

### Task 3: GUI helpers and the PHP test harness

**Files:**
- Create: `test/php/composer.json`, `test/php/composer.lock` (generated), `test/php/phpunit.xml`, `test/php/bootstrap.php`, `test/php/run.sh`, `test/php/README.md`, `test/php/StatisticsTest.php`
- Modify: `gui/include/Statistics.php` (append helpers)
- Modify: `.gitignore` (add `test/php/vendor/` and `test/php/.phpunit.cache/`)

**Interfaces:**
- Produces (all in `gui/include/Statistics.php`, loaded on every page by composer `files` autoload):
  - constant `DISK_USAGE_APPROACHING_PERCENT` = 80
  - `getDiskUsageState($usageBytes, $limitBytes)` → `['state' => 'ok'|'approaching'|'over', 'percent' => int]`
  - `getDiskUsageWarning($usageBytes, $limitBytes)` → string, `''` when ok
  - `formatMailQuotaLimit($mailQuotaBytes, $diskLimitBytes)` → string
  - `formatMailboxUsage($usageBytes, $quotaBytes, $diskLimitBytes)` → string. `$usageBytes` NULL means unknown.
  - `formatDiskUsageMeasuredAt($timestamp, $dateFormat)` → string
  - `getDiskUsageSummaryMessage($overCount, $approachingCount)` → string, `''` when both are 0
  - `getResellerDiskUsageStates($resellerId)` → `[adminId => ['state' => ..., 'percent' => int], ...]` for customers not `ok` (DB)

- [ ] **Step 1: Harness files**

`test/php/composer.json`:

```json
{
  "name": "imscp/gui-tests",
  "description": "Unit tests for pure GUI helpers",
  "type": "project",
  "license": "LGPL-2.1-only",
  "require-dev": {
    "phpunit/phpunit": "^11.5"
  },
  "config": {
    "sort-packages": true
  }
}
```

`test/php/phpunit.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<phpunit xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:noNamespaceSchemaLocation="vendor/phpunit/phpunit/phpunit.xsd"
         bootstrap="bootstrap.php"
         cacheDirectory=".phpunit.cache"
         colors="true">
    <testsuites>
        <testsuite name="gui">
            <directory suffix="Test.php">.</directory>
            <exclude>vendor</exclude>
        </testsuite>
    </testsuites>
</phpunit>
```

`test/php/bootstrap.php`:

```php
<?php
// Unit tests load only the GUI's helper files: no application boot, database
// or session. tr() normally lives in gui/include/Intl.php, which needs the
// translator; without one it only substitutes its arguments, which is what
// this stand-in does.

if (!function_exists('tr')) {
    function tr($messageId, $substitution = NULL)
    {
        if ($substitution === NULL) {
            return $messageId;
        }

        $argv = func_get_args();
        unset($argv[0]);
        return vsprintf($messageId, $argv);
    }
}

require __DIR__ . '/../../gui/include/Shared.php';
require __DIR__ . '/../../gui/include/Statistics.php';

date_default_timezone_set('UTC');
```

`test/php/run.sh` (mode 0755):

```sh
#!/bin/sh
# Runs the GUI unit tests in the composer image, whose PHP has the extensions
# PHPUnit needs (dom, mbstring), whatever the host has.
#
#   test/php/run.sh [phpunit arguments]
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)

exec docker run --rm \
    -u "$(id -u):$(id -g)" \
    -e COMPOSER_HOME=/tmp/composer \
    -v "$root:/src" \
    -w /src/test/php \
    composer:2.8 \
    sh -c 'composer install --no-interaction --no-progress --quiet && vendor/bin/phpunit "$@"' sh "$@"
```

`test/php/README.md`:

```markdown
# GUI unit tests

Unit tests for the GUI's pure helper functions: no application boot, database
or session. `bootstrap.php` loads only the include files under test.

    test/php/run.sh

runs them in the `composer:2.8` docker image, which installs PHPUnit into
`test/php/vendor/` on first use. Pass PHPUnit arguments through, for example
`test/php/run.sh --filter getDiskUsageState`.
```

Append to `.gitignore`:

```
# test/php: PHPUnit installed by test/php/run.sh
test/php/vendor/
test/php/.phpunit.cache/
```

- [ ] **Step 2: Write the failing tests** — `test/php/StatisticsTest.php`:

```php
<?php

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class StatisticsTest extends TestCase
{
    private const MIB = 1048576;
    private const GIB = 1073741824;

    public static function stateCases(): array
    {
        return [
            'unlimited'          => [5 * self::GIB, 0, 'ok', 0],
            'empty account'      => [0, 1000, 'ok', 0],
            '79 percent'         => [790, 1000, 'ok', 79],
            '80 percent'         => [800, 1000, 'approaching', 80],
            'exactly the limit'  => [1000, 1000, 'approaching', 100],
            'one byte over'      => [1001, 1000, 'over', 100],
            '110 percent'        => [1100, 1000, 'over', 110],
        ];
    }

    #[DataProvider('stateCases')]
    public function testGetDiskUsageState($usage, $limit, $state, $percent): void
    {
        $this->assertSame(['state' => $state, 'percent' => $percent], getDiskUsageState($usage, $limit));
    }

    public function testGetDiskUsageWarning(): void
    {
        $this->assertSame('', getDiskUsageWarning(1 * self::GIB, 5 * self::GIB));
        $this->assertSame('', getDiskUsageWarning(9 * self::GIB, 0));
        $this->assertSame(
            'You have used 4.50 GiB of your 5.00 GiB disk space (90%). Consider reducing usage or contact your reseller to upgrade your plan.',
            getDiskUsageWarning(4.5 * self::GIB, 5 * self::GIB)
        );
        $this->assertSame(
            'You are using 6.00 GiB of your 5.00 GiB disk space. Your plan may be upgraded. Reduce usage or contact your reseller.',
            getDiskUsageWarning(6 * self::GIB, 5 * self::GIB)
        );
    }

    public function testFormatMailQuotaLimit(): void
    {
        $this->assertSame('up to 5.00 GiB (account disk limit)', formatMailQuotaLimit(0, 5 * self::GIB));
        $this->assertSame('∞', formatMailQuotaLimit(0, 0));
        $this->assertSame('2.00 GiB', formatMailQuotaLimit(2 * self::GIB, 5 * self::GIB));
        $this->assertSame('2.00 GiB', formatMailQuotaLimit(2 * self::GIB, 0));
    }

    public function testFormatMailboxUsage(): void
    {
        // Unlimited mailbox, account with a disk limit
        $this->assertSame(
            '1.20 GiB / 5.00 GiB (account limit) – 24%', formatMailboxUsage(1.2 * self::GIB, 0, 5 * self::GIB)
        );
        // Unlimited mailbox, unlimited account
        $this->assertSame('1.20 GiB / ∞', formatMailboxUsage(1.2 * self::GIB, 0, 0));
        // Mailbox with a quota (as mail_accounts.php showed it before)
        $this->assertSame('250.00 MiB / 500.00 MiB (50%)', formatMailboxUsage(250 * self::MIB, 500 * self::MIB, 0));
        $this->assertSame('600.00 MiB / 500.00 MiB (100%)', formatMailboxUsage(600 * self::MIB, 500 * self::MIB, 0));
        // Mailbox with a quota but no maildirsize yet
        $this->assertSame('- / 500.00 MiB', formatMailboxUsage(NULL, 500 * self::MIB, 5 * self::GIB));
        // Never measured, unlimited
        $this->assertSame('0.00 B / ∞', formatMailboxUsage(0, 0, 0));
    }

    public function testFormatDiskUsageMeasuredAt(): void
    {
        $this->assertSame('Not measured yet', formatDiskUsageMeasuredAt(NULL, 'd.m.Y'));
        $this->assertSame('Not measured yet', formatDiskUsageMeasuredAt(0, 'd.m.Y'));
        $this->assertSame('Measured 25.10.2026 03:00', formatDiskUsageMeasuredAt(1792897200, 'd.m.Y'));
    }

    public function testGetDiskUsageSummaryMessage(): void
    {
        $this->assertSame('', getDiskUsageSummaryMessage(0, 0));
        $this->assertSame(
            '3 customers over their disk limit, 5 approaching', getDiskUsageSummaryMessage(3, 5)
        );
        $this->assertSame(
            '0 customers over their disk limit, 1 approaching', getDiskUsageSummaryMessage(0, 1)
        );
    }
}
```

Note for the implementer: confirm `1792897200` is 2026-10-25 03:00:00 UTC with `php -r 'echo gmdate("d.m.Y H:i", 1792897200);'`. If it isn't, use the timestamp that is (`php -r 'echo gmmktime(3,0,0,10,25,2026);'`). The `bytesHuman()` strings were checked against the real function (`0.00 B`, `1.20 GiB`, `600.00 MiB`).

- [ ] **Step 3: Run the tests to verify they fail**

Run: `test/php/run.sh` (check `cat /proc/loadavg` first, 1-minute < 10)
Expected: errors "Call to undefined function getDiskUsageState()" and similar.

- [ ] **Step 4: Implement the helpers** — append to `gui/include/Statistics.php`:

```php
/**
 * Disk usage at or above this percentage of the limit is reported as approaching it
 */
define('DISK_USAGE_APPROACHING_PERCENT', 80);

/**
 * Grade disk usage against a disk limit
 *
 * The disk limit is informational: nothing is enforced. Usage above the
 * limit is over it; at or above DISK_USAGE_APPROACHING_PERCENT it is
 * approaching it.
 *
 * @param int|float $usageBytes Disk usage in bytes
 * @param int|float $limitBytes Disk limit in bytes (0 = unlimited)
 * @return array ['state' => 'ok'|'approaching'|'over', 'percent' => int]
 */
function getDiskUsageState($usageBytes, $limitBytes)
{
    if ($limitBytes <= 0) {
        return ['state' => 'ok', 'percent' => 0];
    }

    $percent = (int)floor($usageBytes / $limitBytes * 100);

    if ($usageBytes > $limitBytes) {
        $state = 'over';
    } elseif ($usageBytes * 100 >= $limitBytes * DISK_USAGE_APPROACHING_PERCENT) {
        $state = 'approaching';
    } else {
        $state = 'ok';
    }

    return ['state' => $state, 'percent' => $percent];
}

/**
 * Get the message telling a customer their disk usage approaches or exceeds their disk limit
 *
 * @param int|float $usageBytes Disk usage in bytes
 * @param int|float $limitBytes Disk limit in bytes (0 = unlimited)
 * @return string Message, empty when usage is within the limit
 */
function getDiskUsageWarning($usageBytes, $limitBytes)
{
    $usage = getDiskUsageState($usageBytes, $limitBytes);

    switch ($usage['state']) {
        case 'approaching':
            return tr(
                'You have used %s of your %s disk space (%d%%). Consider reducing usage or contact your reseller to upgrade your plan.',
                bytesHuman($usageBytes), bytesHuman($limitBytes), $usage['percent']
            );
        case 'over':
            return tr(
                'You are using %s of your %s disk space. Your plan may be upgraded. Reduce usage or contact your reseller.',
                bytesHuman($usageBytes), bytesHuman($limitBytes)
            );
        default:
            return '';
    }
}

/**
 * Format an account's mail quota limit
 *
 * A mail quota of 0 has no limit of its own; with a disk limit it is bounded by it.
 *
 * @param int|float $mailQuotaBytes Account mail quota in bytes (0 = none of its own)
 * @param int|float $diskLimitBytes Account disk limit in bytes (0 = unlimited)
 * @return string
 */
function formatMailQuotaLimit($mailQuotaBytes, $diskLimitBytes)
{
    if ($mailQuotaBytes > 0) {
        return bytesHuman($mailQuotaBytes);
    }

    if ($diskLimitBytes > 0) {
        return tr('up to %s (account disk limit)', bytesHuman($diskLimitBytes));
    }

    return '∞';
}

/**
 * Format a mailbox's usage for the mailbox list
 *
 * @param int|float|null $usageBytes Mailbox usage in bytes, NULL if unknown
 * @param int|float $quotaBytes Mailbox quota in bytes (0 = unlimited)
 * @param int|float $diskLimitBytes Account disk limit in bytes (0 = unlimited)
 * @return string
 */
function formatMailboxUsage($usageBytes, $quotaBytes, $diskLimitBytes)
{
    if ($quotaBytes > 0) {
        if (NULL === $usageBytes) {
            return '- / ' . bytesHuman($quotaBytes);
        }

        return sprintf(
            '%s / %s (%.0f%%)',
            bytesHuman($usageBytes),
            bytesHuman($quotaBytes),
            min(100, round($usageBytes / $quotaBytes * 100))
        );
    }

    if (NULL === $usageBytes) {
        $usageBytes = 0;
    }

    if ($diskLimitBytes > 0) {
        return tr(
            '%s / %s (account limit) – %d%%',
            bytesHuman($usageBytes), bytesHuman($diskLimitBytes), floor($usageBytes / $diskLimitBytes * 100)
        );
    }

    return bytesHuman($usageBytes) . ' / ∞';
}

/**
 * Say when an account's disk usage was last measured
 *
 * @param int|null $timestamp Unix time of the last measurement, NULL if never
 * @param string $dateFormat Date format (config DATE_FORMAT)
 * @return string
 */
function formatDiskUsageMeasuredAt($timestamp, $dateFormat)
{
    if (empty($timestamp)) {
        return tr('Not measured yet');
    }

    return tr('Measured %s', date($dateFormat . ' H:i', (int)$timestamp));
}

/**
 * Get the summary line of customers over or approaching their disk limit
 *
 * @param int $overCount Customers over their disk limit
 * @param int $approachingCount Customers approaching their disk limit
 * @return string Summary, empty when both counts are 0
 */
function getDiskUsageSummaryMessage($overCount, $approachingCount)
{
    if ($overCount == 0 && $approachingCount == 0) {
        return '';
    }

    return tr('%d customers over their disk limit, %d approaching', $overCount, $approachingCount);
}

/**
 * Get the reseller's customers that are over or approaching their disk limit
 *
 * @param int $resellerId Reseller unique identifier
 * @return array [customer admin ID => ['state' => 'approaching'|'over', 'percent' => int]]
 */
function getResellerDiskUsageStates($resellerId)
{
    $stmt = exec_query(
        '
            SELECT t1.domain_admin_id, t1.domain_disk_usage, t1.domain_disk_limit
            FROM domain AS t1
            JOIN admin AS t2 ON(t2.admin_id = t1.domain_admin_id)
            WHERE t2.created_by = ?
        ',
        [$resellerId]
    );

    $states = [];
    while ($row = $stmt->fetchRow(PDO::FETCH_ASSOC)) {
        $usage = getDiskUsageState($row['domain_disk_usage'], $row['domain_disk_limit'] * 1048576);

        if ($usage['state'] != 'ok') {
            $states[$row['domain_admin_id']] = $usage;
        }
    }

    return $states;
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `test/php/run.sh`
Expected: OK (6 tests). `php -l gui/include/Statistics.php` reports no syntax errors.

- [ ] **Step 6: Commit** (include the generated `test/php/composer.lock`)

```bash
git add .gitignore gui/include/Statistics.php test/php
git commit -m "gui: add disk usage helpers and a PHPUnit harness for pure GUI helpers"
```

---

### Task 4: Reseller forms accept mail quota 0 with a disk limit

**Files:**
- Modify: `gui/public/reseller/user_add2.php` (~455-473)
- Modify: `gui/public/reseller/hosting_plan_add.php` (~359-369)
- Modify: `gui/public/reseller/hosting_plan_edit.php` (~409-419)
- Modify: `gui/public/reseller/domain_edit.php` (~755-765)
- Modify: `gui/themes/default/reseller/user_add2.tpl`, `hosting_plan_add.tpl`, `hosting_plan_edit.tpl`, `domain_edit.tpl` (the disk-limit keyup handler)

**Interfaces:** none (self-contained).

- [ ] **Step 1: Remove the server-side rule.** In each of the four PHP files, delete the `elseif` branch that sets "Mail quota cannot be unlimited. Max value is %d MiB." together with its `$errFieldsStack[]` line. Keep the preceding "Mail quota cannot be bigger than disk space limit." branch.

`user_add2.php`: the branch is

```php
    } elseif ($diskspace != '0' && $mailQuota == '0') {
        set_page_message(
            tohtml(tr(
                'Mail quota cannot be unlimited. Max value is %d MiB.',
                $diskspace
            )),
            'error'
        );
        $errFieldsStack[] = 'nreseller_mail_quota';
    }
```

so the `if/elseif` chain ends with `$errFieldsStack[] = 'nreseller_mail_quota';\n    }` after the "bigger than" branch.

`hosting_plan_add.php` and `hosting_plan_edit.php`: delete

```php
        } elseif ($diskSpace != 0 && $mailQuota == 0) {
            set_page_message(tr('Mail quota cannot be unlimited. Max value is %d MiB.', $diskSpace), 'error');
            $errFieldsStack[] = 'mail_quota';
```

`domain_edit.php`: delete

```php
            } elseif ($data['domain_disk_limit'] != 0 && $data['mail_quota'] == 0) {
                set_page_message(
                    tr('Mail quota cannot be unlimited. Max value is %d MiB.', $data['domain_disk_limit']), 'error'
                );
                $errFieldsStack[] = 'mail_quota';
```

so that `} else { $mailData = getMailData(...` follows the "bigger than" branch directly.

- [ ] **Step 2: Remove the client-side rule.** In each of the four templates, in the disk-limit `on("keyup mouseup paste copy cut")` handler, change

```js
                $mailQuotaField.attr("min", 1).attr("max", storageQuotaLimit);
```

to

```js
                $mailQuotaField.attr("min", 0).attr("max", storageQuotaLimit);
```

(`domain_edit.tpl` has one more level of indentation; keep it.)

- [ ] **Step 3: Verify**

Run: `for f in user_add2 hosting_plan_add hosting_plan_edit domain_edit; do php -l gui/public/reseller/$f.php; done`
Expected: no syntax errors.

Run: `grep -rn "cannot be unlimited. Max value" gui/public/reseller; grep -n 'attr("min", 1)' gui/themes/default/reseller/{user_add2,hosting_plan_add,hosting_plan_edit,domain_edit}.tpl`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add gui/public/reseller/{user_add2,hosting_plan_add,hosting_plan_edit,domain_edit}.php gui/themes/default/reseller/{user_add2,hosting_plan_add,hosting_plan_edit,domain_edit}.tpl
git commit -m "gui: allow an unlimited mail quota alongside a disk limit"
```

---

### Task 5: Client pages — dashboard, mailbox list, mailbox add/edit

**Files:**
- Modify: `gui/public/client/index.php` (`gen_mail_quota_limit_mgs`, `client_generateDiskUsageBar`, the main assign)
- Modify: `gui/themes/default/client/index.tpl` (disk section)
- Modify: `gui/public/client/mail_accounts.php` (mailbox loop)
- Modify: `gui/themes/default/client/mail_accounts.phtml` (quota cell)
- Modify: `gui/public/client/mail_add.php` (`generatePage`, unlimited branch)
- Modify: `gui/public/client/mail_edit.php` (`generatePage`, unlimited branch)

**Interfaces:**
- Consumes: `getDiskUsageWarning`, `formatMailQuotaLimit`, `formatMailboxUsage`, `formatDiskUsageMeasuredAt` (Task 3). Columns `mail_users.mail_disk_usage` and `domain.domain_disk_usage_time` (Task 2). `get_domain_default_props()` returns `SELECT *` from `domain`, so the new column is included.

- [ ] **Step 1: Dashboard warning.** In `client/index.php`, replace the body of `client_generateDiskUsageBar` after the `$tpl->assign([...])` with:

```php
    $warning = getDiskUsageWarning($usage, $maxUsage);

    if ($warning !== '') {
        $tpl->assign('TR_DISK_WARNING', tohtml($warning));
    } else {
        $tpl->assign('DISK_WARNING', '');
    }
```

- [ ] **Step 2: Dashboard mail quota line.** In `gen_mail_quota_limit_mgs()`, replace the two returns with:

```php
    return bytesHuman($mailQuota) . ' / '
        . formatMailQuotaLimit($domainProps['mail_quota'], $domainProps['domain_disk_limit'] * 1048576);
```

- [ ] **Step 3: Measured-at line.** In the main `$tpl->assign([...])` of `client/index.php`, add:

```php
    'DISK_USAGE_MEASURED'                      => tohtml(
        formatDiskUsageMeasuredAt($domainProperties['domain_disk_usage_time'], $cfg['DATE_FORMAT'])
    ),
```

In `gui/themes/default/client/index.tpl`, directly after the closing `</table>` of the "Disk usage detail" table, add:

```html
<p>{DISK_USAGE_MEASURED}</p>
```

- [ ] **Step 4: Mailbox list data.** In `client/mail_accounts.php`, in the function that builds the list:
  - add `mail_disk_usage` to the `SELECT` column list
  - before the `while` loop add:

```php
    $mainDmnProps = get_domain_default_props($_SESSION['user_id']);
    $diskLimitBytes = $mainDmnProps['domain_disk_limit'] * 1048576;
    $hasUnlimitedMailboxes = false;
```

  - at the top of the `while` body, next to `$mailQuotaInfo = '-';`, add `$mailSizeSort = -1;`
  - replace the block from `$maildirsize = ($row['quota'])` through the `$mailQuotaInfo = sprintf(...);` statement with:

```php
            if (!$row['quota']) {
                // No quota of its own: show the daily figure against the account's disk limit
                $hasUnlimitedMailboxes = true;
                $mailSizeSort = (int)$row['mail_disk_usage'];
                $mailQuotaInfo = formatMailboxUsage($row['mail_disk_usage'], 0, $diskLimitBytes);
                continue;
            }

            $maildirsize = parseMaildirsize(
                utils_normalizePath($postfixConfig['MTA_VIRTUAL_MAIL_DIR'] . "/$domain/$user/maildirsize"),
                $syncQuotaInfo
            );

            if ($maildirsize === false) {
                $mailQuotaInfo = formatMailboxUsage(NULL, $row['quota'], $diskLimitBytes);
                continue;
            }

            $quotaPercent = min(100, round(($maildirsize['byte_count'] / max(1, $maildirsize['quota_bytes'])) * 100));

            if (!$overQuota && $quotaPercent >= 100) {
                $overQuota = true;
            }

            $mailSizeSort = (int)$maildirsize['byte_count'];
            $mailQuotaInfo = formatMailboxUsage(
                $maildirsize['byte_count'], $maildirsize['quota_bytes'], $diskLimitBytes
            );
```

  - in the per-row `$tpl->assign([...])`, add `'MAIL_ACCOUNT_SIZE_SORT' => tohtml($mailSizeSort, 'htmlAttr'),`
  - after the `if ($overQuota) {...}` block, add:

```php
    if ($hasUnlimitedMailboxes) {
        set_page_message(
            empty($mainDmnProps['domain_disk_usage_time'])
                ? tr('Sizes of mailboxes without a quota have not been measured yet.')
                : tr(
                    'Sizes of mailboxes without a quota were measured %s.',
                    date(Registry::get('config')['DATE_FORMAT'] . ' H:i', $mainDmnProps['domain_disk_usage_time'])
                ),
            'static_info'
        );
    }
```

  (`Registry` is already imported in this file if `Registry::get('config')` appears above. Otherwise add `use iMSCP\Registry;` beside the other `use` lines.)

- [ ] **Step 5: Mailbox list sorting.** In `gui/themes/default/client/mail_accounts.phtml`, change the opening `<td>` of the quota cell (the one containing `<!-- BDP: mail_account_no_quota_warning -->`) to:

```html
            <td data-order="{MAIL_ACCOUNT_SIZE_SORT}">
```

DataTables uses `data-order` to sort that column by bytes. Forward-only rows sort first, at -1.

- [ ] **Step 6: Mailbox add/edit label and default.** In `client/mail_add.php` `generatePage`, in the `if ($customerEmailQuotaLimitBytes < 1)` branch, replace the `TR_QUOTA` and `QUOTA` entries with:

```php
            'TR_QUOTA'  => tohtml($mainDmnProps['domain_disk_limit'] > 0
                ? tr("Quota in MiB (0 = up to the account's %s)", bytesHuman($mainDmnProps['domain_disk_limit'] * 1048576))
                : tr('Quota in MiB (0 ∞)')),
```

```php
            'QUOTA'     => isset($_POST['quota']) ? tohtml(filter_digits($_POST['quota']), 'htmlAttr') : 0
```

(A new mailbox defaults to no quota of its own, in place of the old 10 MiB.)

In `client/mail_edit.php` `generatePage`, in the `if ($customerEmailQuotaLimitBytes < 1)` branch, replace only the `TR_QUOTA` entry with the same expression (`$mainDmnProps` is already defined in that function; check, and fetch it with `get_domain_default_props($_SESSION['user_id'])` if not).

- [ ] **Step 7: Verify**

Run: `for f in index mail_accounts mail_add mail_edit; do php -l gui/public/client/$f.php; done`
Expected: no syntax errors.
Run: `test/php/run.sh`
Expected: still OK.

- [ ] **Step 8: Commit**

```bash
git add gui/public/client/{index,mail_accounts,mail_add,mail_edit}.php gui/themes/default/client/index.tpl gui/themes/default/client/mail_accounts.phtml
git commit -m "gui: show clients graded disk usage and every mailbox's size"
```

---

### Task 6: Reseller and admin pages — statistics, dashboard, customer details

**Files:**
- Modify: `gui/public/reseller/user_statistics.php`, `gui/themes/default/reseller/user_statistics.tpl`
- Modify: `gui/public/reseller/index.php`, `gui/themes/default/reseller/index.tpl`
- Modify: `gui/public/reseller/domain_details.php`, `gui/themes/default/reseller/domain_details.tpl`
- Modify: `gui/public/admin/domain_details.php`, `gui/themes/default/admin/domain_details.tpl`

**Interfaces:**
- Consumes: `getDiskUsageState`, `getDiskUsageSummaryMessage`, `getResellerDiskUsageStates`, `formatDiskUsageMeasuredAt`, `formatMailQuotaLimit` (Task 3). Column `domain.domain_disk_usage_time` (Task 2).

- [ ] **Step 1: Statistics page — marker, filter, summary.** In `reseller/user_statistics.php`:

  - `generatePage(TemplateEngine $tpl)` becomes:

```php
function generatePage(TemplateEngine $tpl)
{
    $diskStates = getResellerDiskUsageStates($_SESSION['user_id']);
    $counts = array_count_values(array_column($diskStates, 'state')) + ['over' => 0, 'approaching' => 0];
    $summary = getDiskUsageSummaryMessage($counts['over'], $counts['approaching']);
    $filterDisk = isset($_GET['filter']) && $_GET['filter'] == 'disk';

    if ($summary !== '') {
        $tpl->assign('DISK_USAGE_SUMMARY', tohtml($summary));
    } else {
        $tpl->assign('DISK_USAGE_SUMMARY_BLOCK', '');
    }

    $tpl->assign([
        'TR_FILTER_ALL'  => tohtml(tr('All customers')),
        'TR_FILTER_DISK' => tohtml(tr('Approaching or over disk limit')),
        // A filtered view is ordered by disk usage, ignoring the saved table state
        'DT_STATE_SAVE'  => $filterDisk ? 'false' : 'true',
        'DT_ORDER'       => $filterDisk ? '[[1, "desc"]]' : '[[0, "asc"]]'
    ]);

    $stmt = exec_query('SELECT admin_id FROM admin WHERE created_by = ?', $_SESSION['user_id']);

    while ($row = $stmt->fetchRow(PDO::FETCH_ASSOC)) {
        if ($filterDisk && !isset($diskStates[$row['admin_id']])) {
            continue;
        }

        _generateUserStatistics($tpl, $row['admin_id']);
        $tpl->parse('USER_STATISTICS_ENTRY_BLOCK', '.user_statistics_entry_block');
    }
}
```

  - in `_generateUserStatistics`, after `$diskPercent = ...`, add:

```php
    $diskState = getDiskUsageState($diskUsage, $diskLimit);
```

    and add to its `$tpl->assign([...])`:

```php
        'DISK_STATE'            => tohtml($diskState['state'] == 'over'
            ? tr('Over limit') : ($diskState['state'] == 'approaching' ? tr('Approaching limit') : '')),
        'DISK_STATE_CLASS'      => tohtml('disk_' . $diskState['state'], 'htmlAttr'),
        'DISK_SORT'             => tohtml($diskLimit > 0 ? $diskUsage / $diskLimit : 0, 'htmlAttr'),
```

  - in `define_dynamic`, add `'disk_usage_summary_block' => 'page',`.

  In `gui/themes/default/reseller/user_statistics.tpl`:
  - change the dataTable init to:

```js
        $('.datatable').dataTable({
            language: imscp_i18n.core.dataTable,
            stateSave: {DT_STATE_SAVE},
            order: {DT_ORDER},
            pagingType: "simple"
        });
```

  - directly after `</script>`, add:

```html
<!-- BDP: disk_usage_summary_block -->
<div class="warning">{DISK_USAGE_SUMMARY}</div>
<!-- EDP: disk_usage_summary_block -->
<p>
    <a href="user_statistics.php">{TR_FILTER_ALL}</a> |
    <a href="user_statistics.php?filter=disk">{TR_FILTER_DISK}</a>
</p>
```

  - change the disk `<td>` of the entry block to:

```html
        <td data-order="{DISK_SORT}">
            <div class="graph">
                <span style="width:{DISK_PERCENT_WIDTH}%"></span>
                <strong>{DISK_PERCENT}%</strong>
            </div>
            {DISK_MSG}
            <br><strong class="{DISK_STATE_CLASS}">{DISK_STATE}</strong>
        </td>
```

  Then add the colours to the theme's stylesheet. Find the file with `grep -rln "\.warning" gui/public/themes/default/assets/css/ | head -1` and append:

```css
.disk_over { color: #ca1d11; }
.disk_approaching { color: #c87f0a; }
```

  (Add that CSS file to this task's commit.)

- [ ] **Step 2: Reseller dashboard summary.** In `reseller/index.php` `generatePage`, after the disk warning `if/else`, add:

```php
    $diskStates = getResellerDiskUsageStates($resellerId);
    $counts = array_count_values(array_column($diskStates, 'state')) + ['over' => 0, 'approaching' => 0];
    $summary = getDiskUsageSummaryMessage($counts['over'], $counts['approaching']);

    if ($summary !== '') {
        $tpl->assign([
            'CUSTOMERS_DISK_SUMMARY'    => tohtml($summary),
            'TR_CUSTOMERS_DISK_DETAILS' => tohtml(tr('Show these customers'))
        ]);
    } else {
        $tpl->assign('CUSTOMERS_DISK_SUMMARY_MESSAGE', '');
    }
```

  Use the reseller id variable that `generatePage` already receives (its signature is `generatePage($tpl, $resellerId, $resellerName)`; check the parameter name and use it). Add `'customers_disk_summary_message' => 'page'` to `define_dynamic`.

  In `gui/themes/default/reseller/index.tpl`, after the disk usage `.graph` div that follows `{DISK_USAGE_DATA}`, add:

```html
<!-- BDP: customers_disk_summary_message -->
<div class="warning">{CUSTOMERS_DISK_SUMMARY} – <a href="user_statistics.php?filter=disk">{TR_CUSTOMERS_DISK_DETAILS}</a></div>
<!-- EDP: customers_disk_summary_message -->
```

- [ ] **Step 3: Customer details (reseller and admin).** In both `reseller/domain_details.php` and `admin/domain_details.php` `generatePage`:

  - after `$diskspaceUsagePercent = ...`, add:

```php
    $diskState = getDiskUsageState($domainData['domain_disk_usage'], $diskspaceLimitBytes);
```

  - add to the `$tpl->assign([...])`:

```php
        'VL_DISK_LIMIT'              => $diskspaceLimitBytes > 0 ? bytesHuman($diskspaceLimitBytes) : '∞',
        'VL_DISK_STATE'              => tohtml($diskState['state'] == 'over'
            ? tr('Over limit') : ($diskState['state'] == 'approaching' ? tr('Approaching limit') : '')),
        'VL_DISK_STATE_CLASS'        => tohtml('disk_' . $diskState['state'], 'htmlAttr'),
        'VL_DISK_MEASURED'           => tohtml(formatDiskUsageMeasuredAt(
            $domainData['domain_disk_usage_time'], Registry::get('config')['DATE_FORMAT']
        )),
        'VL_DISK_FILE'               => bytesHuman($domainData['domain_disk_file']),
        'VL_DISK_MAIL'               => bytesHuman($domainData['domain_disk_mail']),
        'VL_DISK_SQL'                => bytesHuman($domainData['domain_disk_sql']),
```

    (This replaces the existing `VL_DISK_LIMIT` entry, which showed "0 B" for unlimited. Add `use iMSCP\Registry;` if the file lacks it.)

  - in the mail quota limit helper (`reseller_gen_mail_quota_limit_mgs` / `admin_gen_mail_quota_limit_mgs`), replace the limit expression `($domainProps['mail_quota'] == 0) ? '∞' : bytesHuman($domainProps['mail_quota'])` with:

```php
formatMailQuotaLimit($domainProps['mail_quota'], $domainProps['domain_disk_limit'] * 1048576)
```

  - add to the page-level `$tpl->assign([...])` that holds the `TR_*` labels:

```php
    'TR_DISK_FILE_USAGE'   => tr('File usage'),
    'TR_DISK_MAIL_USAGE'   => tr('Mail usage'),
    'TR_DISK_SQL_USAGE'    => tr('Database usage'),
```

  In both `gui/themes/default/reseller/domain_details.tpl` and `gui/themes/default/admin/domain_details.tpl`, replace the disk row with:

```html
    <tr>
        <td>{TR_DISK}</td>
        <td>
            <div class="graph"><span style="width:{VL_DISK_PERCENT}%">&nbsp;</span></div>
            {VL_DISK_USED} / {VL_DISK_LIMIT}
            <strong class="{VL_DISK_STATE_CLASS}">{VL_DISK_STATE}</strong>
            <br>{TR_DISK_FILE_USAGE}: {VL_DISK_FILE}, {TR_DISK_MAIL_USAGE}: {VL_DISK_MAIL}, {TR_DISK_SQL_USAGE}: {VL_DISK_SQL}
            <br><small>{VL_DISK_MEASURED}</small>
        </td>
    </tr>
```

- [ ] **Step 4: Verify**

Run: `for f in reseller/user_statistics reseller/index reseller/domain_details admin/domain_details; do php -l gui/public/$f.php; done`
Expected: no syntax errors.

Run: `grep -n "{[A-Z_]*}" gui/themes/default/reseller/user_statistics.tpl | grep -o "{[A-Z_]*}" | sort -u` and check every placeholder is assigned in `user_statistics.php`. Do the same for `reseller/index.tpl` and both `domain_details.tpl` files. Unassigned placeholders render literally.

- [ ] **Step 5: Commit**

```bash
git add gui/public/reseller/{user_statistics,index,domain_details}.php gui/public/admin/domain_details.php gui/themes/default/reseller/{user_statistics,index,domain_details}.tpl gui/themes/default/admin/domain_details.tpl gui/public/themes/default/assets/css
git commit -m "gui: show resellers which customers approach or exceed their disk limit"
```

---

### Wave 3 (controller): verification, PR, merge

- [ ] `prove -Iengine/PerlLib -Iengine/PerlVendor test/perl` and `test/php/run.sh`: all pass.
- [ ] Check `cat /proc/loadavg` (< 10). Then bring up the worktree's docker stack (`docker/imscp init`, `docker/imscp up --build`) and run the spec's manual checks:
  - Reseller: set a customer's disk limit to 5 GiB and mail quota to 0 in `domain_edit`, a new hosting plan, an edited hosting plan and `user_add2`. All are accepted.
  - Create unlimited mailboxes, put a few MB of mail in one, run `perl /var/www/imscp/engine/quota/imscp-dsk-quota`, and check `mail_users.mail_disk_usage` and `domain.domain_disk_usage_time` in MariaDB.
  - Seed `domain_disk_usage` at 50%, 85% and 110% of the limit. Check the client dashboard, mailbox list (text, sort order, measured-at message), reseller statistics (marker, filter, summary), reseller dashboard and both details pages.
  - With the account at 110%, send mail to an unlimited mailbox and confirm it is delivered (the stack runs Dovecot. Courier delivery is reasoned from `concat(quota,'S')` = `0S` and is noted in the PR as untested).
- [ ] Push `feature/mail-quota-informative`, open the PR on `saygoweb/imscp`, wait for CI to go green, then squash-merge (`gh pr merge --admin --squash`) and clean up per `merge-when-green`.
