# Mail quota and the disk limit: inform, don't limit — design

Date: 2026-10-25
Status: approved in conversation; awaiting review of this written spec

## Purpose

A customer's disk space limit is a billing threshold, not a cap. When an
account goes over it, the reseller raises the plan or the customer reduces
usage. Nothing should stop working because a figure was crossed.

Today the panel works against that in two ways:

1. When a disk limit is set (say 5 GB), the reseller cannot give the account
   an unlimited mail quota. The account then has to be split into
   per-mailbox quotas, which courier enforces, so mail bounces long before
   the account is anywhere near its limit.
2. Mailbox usage is only visible for mailboxes that have a quota. It is read
   from `maildirsize`, which only exists when a quota is set. Unlimited
   mailboxes show `- / ∞`.

Success: a reseller sets only a disk limit and the client creates
mailboxes without quotas. Both of them can see the account's usage by web,
mail, SQL and by mailbox, and both are told when the account approaches or
passes its limit, early enough to act.

## How it works today (for reference)

- `engine/quota/imscp-dsk-quota` runs `@daily`. It runs `du` on the web
  directory (excluding `backups/` and `logs/`) and each mail domain
  directory, then adds SQL table sizes. The results go into
  `domain.domain_disk_usage` / `_file` / `_mail` / `_sql` and
  `quotatallies.bytes_in_used`.
- The disk limit is only enforced by ProFTPD's quotatab, which refuses FTP
  uploads at the limit. Web, SQL and mail writes are not limited.
- `domain.mail_quota` is the account's mail allowance. Each mailbox's
  `mail_users.quota` is a slice of it: the slices add up to no more than the
  account allowance and each is at least 1 MiB. Courier's authlib gets the
  quota as `concat(quota,'S')`. A quota of 0 means unlimited, and
  `Servers::po::courier` writes no `maildirsize` for it.

## Decisions

| Question | Decision |
|---|---|
| Enforcement | None added. The disk limit stays informational for web, SQL and mail. |
| Meaning of mail quota 0 with a disk limit | "No mail limit of its own." The panel shows it as bounded by the disk limit ("up to 5 GB"). Courier still gets 0, so delivery is unlimited. |
| Explicit per-mailbox quotas | Kept, opt-in, enforced by courier as today. |
| FTP quotatab | Out of scope. Left as it is: it still refuses uploads at the limit. |
| Per-mailbox usage source | Unlimited mailboxes: the daily `du` figure. Mailboxes with a quota: live `maildirsize`, as today. |
| Measurement frequency | Daily, unchanged. |
| Warning thresholds | Approaching at 80% or more, over above 100%. Fixed constants. |
| Notifications | Panel only. No email. |
| Engine refactor | `du` parsing moves out of `imscp-dsk-quota` into a module so that it can be unit tested (approved in conversation). |
| Dovecot | The same panel rules apply. Dovecot 2.4's per-user quota is broken separately: issue #41, not part of this work. |

## 1. Mail quota 0 is allowed with a disk limit

Remove the rule "Mail quota cannot be unlimited. Max value is %d MiB." from
all four places:

- `gui/public/reseller/user_add2.php` (~460-467)
- `gui/public/reseller/hosting_plan_add.php` (~364-367)
- `gui/public/reseller/hosting_plan_edit.php` (~414-417)
- `gui/public/reseller/domain_edit.php` (~759-765)

Keep "Mail quota cannot be bigger than disk space limit" for non-zero
values. Keep the rule that a non-zero account mail quota is at least the
number of mailboxes in MiB (`domain_edit.php`).

Display:

| Account mail quota | Disk limit | Shown as |
|---|---|---|
| 0 | 5 GB | up to 5 GB (account disk limit) |
| 0 | 0 | ∞ |
| 2 GB | any | 2 GB (as today) |

| Mailbox quota | Disk limit | Shown in mailbox list |
|---|---|---|
| 0 | 5 GB | 1.2 GB / 5 GB (account limit) – 24% |
| 0 | 0 | 1.2 GB / ∞ |
| 500 MB | any | live maildirsize figure / 500 MB – n% (as today) |

The percentage for an unlimited mailbox is measured against the disk limit.
This over-states how much room any one mailbox has, which is accepted: the
figure is for information.

Client mailbox add/edit (`client/mail_add.php`, `client/mail_edit.php`):
when the account mail quota is 0 the field already accepts 0. Its label
changes from "Quota in MiB (0 ∞)" to "Quota in MiB (0 = up to the account's
5 GB)" when a disk limit is set. It stays "(0 ∞)" when there is none.

## 2. Data: per-mailbox size and measurement time

### Schema (`r288` in `gui/src/Update/DatabaseUpdate.php`, plus `configs/debian/default/database/database.sql`)

- `mail_users.mail_disk_usage bigint(20) unsigned not null default '0'`:
  bytes, as of the last run.
- `domain.domain_disk_usage_time int(10) unsigned default null`: Unix time
  of the last run for this account. Null means never measured.

### Engine

New module `engine/PerlLib/iMSCP/DiskUsage.pm`, holding pure functions with
no database or filesystem access:

- `parseDuMaxDepth1( $stdout, $domainDir )`: parses the output of
  `du -B1 --max-depth=1 <domainDir>` and returns
  `( $totalBytes, { <mail_acc> => $bytes, ... } )`.
- `mapMailboxUsage( $domainName, \%byAcc, \@mailAddrs )`: returns
  `{ <mail_addr> => $bytes }` for every address in `@mailAddrs`. An address
  with no directory gets 0. Directories with no matching address are left
  out of the per-mailbox map but stay in the total.

`engine/quota/imscp-dsk-quota`, `quotaFiles()`:

- For each mail directory, run `du -B1 --max-depth=1` in place of
  `du -s -B1`. The total feeds `$mailDiskUsage` exactly as before, so
  `domain_disk_mail`, `domain_disk_usage` and `quotatallies` are unchanged.
- Load the account's mailboxes once per account:
  `SELECT mail_addr FROM mail_users WHERE domain_id = ? AND mail_type LIKE '%_mail%'`.
  This covers the main domain, aliases and subdomains. For each mail
  directory (one per domain name), map its usage with `mapMailboxUsage`,
  which only considers addresses ending in `@<that domain name>`.
- In the existing per-domain transaction, also run
  `UPDATE mail_users SET mail_disk_usage = ? WHERE mail_addr = ?` for each
  mailbox, and set `domain.domain_disk_usage_time = UNIX_TIMESTAMP()`.
- If `du` fails for a mail directory, log the error as now and leave that
  directory's mailboxes at their previous values (do not zero them).

`quotaSql()` adds SQL sizes to `domain_disk_usage` as now. It does not touch
the new columns.

## 3. Display

### Shared helper (`gui/include/Statistics.php`, next to `getPercentUsage`)

`getDiskUsageState($usageBytes, $limitBytes)` returns
`['state' => 'ok'|'approaching'|'over', 'percent' => int]`:

- limit 0: `ok` (unlimited)
- usage > limit: `over`
- usage ≥ 80% of limit: `approaching`
- otherwise `ok`

`formatMailboxUsage($usageBytes, $quotaBytes, $diskLimitBytes)` returns the
mailbox list text from the table in section 1.

Every page below uses these helpers. No page computes its own thresholds.

### Client dashboard (`gui/public/client/index.php`, `client_generateDiskUsageBar`, `client/index.tpl`)

- The bar is unchanged.
- The single "You are exceeding your disk space limit." message becomes:
  - approaching: "You have used %s of your %s disk space (%d%%). Consider
    reducing usage or contact your reseller to upgrade your plan."
  - over: "You are using %s of your %s disk space. Your plan may be
    upgraded. Reduce usage or contact your reseller."
- Under the existing web / mail / SQL breakdown: "Measured %s" (from
  `domain_disk_usage_time`), or "Not measured yet" when it is null.
- The mail line uses the account mail quota display from section 1.

### Client mailbox list (`gui/public/client/mail_accounts.php`)

- Each normal mailbox shows `formatMailboxUsage(...)`. A mailbox with a
  quota uses `maildirsize` (live, as today). An unlimited mailbox uses
  `mail_disk_usage`.
- The page shows "Sizes of mailboxes without a quota measured %s" when any
  unlimited mailbox is listed.
- The table can be sorted by size. Use the page's existing table sorting if
  it has one; otherwise sort by size, largest first, with a column header
  link.
- The existing "At least one of your mailboxes is over quota." warning
  stays. Only mailboxes with a quota can trigger it.

### Reseller customer statistics (`gui/public/reseller/user_statistics.php`)

- Each customer row shows an "approaching" or "over" marker next to the
  disk bar.
- A filter, "Approaching or over disk limit", that lists only those
  customers, sorted by disk % descending.
- A summary line above the table: "%d customers over their disk limit, %d
  approaching". It is hidden when both counts are 0.

### Reseller dashboard (`gui/public/reseller/index.php`)

- The same summary line for the reseller's customers, linked to the
  filtered statistics view. Hidden when both counts are 0.

### Customer details (`gui/public/reseller/domain_details.php`, `gui/public/admin/domain_details.php`)

- The disk row shows the graded state and "Measured %s".
- The web / mail / SQL breakdown is shown if not already present.

## Out of scope

- Any enforcement, including a soft cap at delivery or a Postfix policy
  check.
- Changes to ProFTPD quotatab.
- Email notifications.
- Measuring more often than daily.
- The Dovecot 2.4 `quota_rule` problem (#41).

## Testing

Perl (`test/perl/`):

- `iMSCP-DiskUsage.t` uses recorded `du --max-depth=1` output and covers:
  several mailboxes; a leftover directory with no account; an account with
  no directory (0); a mailbox name containing dots; a trailing domain-total
  line; empty output.

PHP: no `test/php/` harness exists yet. This work adds the minimum needed
for its pure helpers:

- `test/php/bootstrap.php` loads only `gui/include/Statistics.php` and the
  formatting functions it needs (no database, no session).
- `test/php/StatisticsTest.php` (PHPUnit) covers `getDiskUsageState`
  (limit 0; 79%, 80%, 100%, 101%; usage 0) and `formatMailboxUsage` (the
  rows of the section 1 tables).
- `test/php/README.md` gives the command that runs it.

The tests do not touch pages or the database. Wiring PHP tests into CI is
left to the test-suite effort.

Manual, in the docker stack:

- Set a customer's disk limit to 5 GB and mail quota to 0. Check the four
  reseller forms accept it.
- Create unlimited mailboxes and run `imscp-dsk-quota`. Check
  `mail_users.mail_disk_usage` and `domain_disk_usage_time`.
- Seed usage at 50%, 85% and 110%. Check the client dashboard, mailbox
  list, reseller statistics (marker, filter, summary), reseller dashboard
  and both details pages.
- Send mail to an unlimited mailbox while the account is over its limit.
  Check that it is delivered.
