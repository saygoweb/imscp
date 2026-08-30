# aws1 migration: Debian 10 (buster) → Debian 13 (trixie)

Moving the i-MSCP control panel from `aws1` to a new Trixie box, keeping the
hostname `aws1.saygoweb.com` and the Elastic IP `34.212.49.11`.

Derived from the old box's `/etc`, and from a second pass taken on aws1
itself. Anything below that could not be read without root is called out where
it appears rather than guessed at.

---

## The shape of it

i-MSCP regenerates every vhost, FPM pool, DNS zone, ProFTPD user and Postfix
map **from the database**. `setupDbTasks()` runs unconditionally at the end of
the installer, marks every entity `tochange` and hands the queue to
`iMSCP::DbTasksProcessor` (`engine/setup/imscp-setup-functions.pl:339-420`).

So this is a data migration, not a config migration. Four things have to arrive
intact, and the installer rebuilds the rest:

1. the **database** (all of it, plus the SQL grants),
2. the **encryption key**, `/etc/imscp/imscp-db-keys`,
3. the **uid/gid map**, and
4. the **data volume**.

Because the public IP follows the box, the generated DNS zones are unchanged —
`PRIMARY_DNS` stays `34.212.49.11` and no NS record moves.

### Scale

| | |
|---|---|
| Sites | 146 directories, 380 vhosts, 192 PHP-FPM pools |
| System users | 144 (`vu2000`–`vu2224`, uid 1003–1196) |
| Mail | 87 domains, Courier + maildrop |
| TLS | 168 certbot lineages |
| Data volume | 199 GB of 252 GB, UUID `958199d3-…` |
| Panel plugins | 1 (`SGW_LetsEncrypt`) |
| `/usr/local` utilities | 12 `server-utils` tools, 2 Go services, 11 loose scripts |
| jailtime | 13 jails, 5 whitelists |

---

## Things that fail silently

### The encryption key is not in the database

Every mailbox password and customer SQL password in `imscp` is Rijndael-CBC
ciphertext keyed on `/etc/imscp/imscp-db-keys`. `iMSCP::Bootstrapper` **silently
generates a new key** if the file is missing or the wrong length
(`Bootstrapper.pm:186-227`). Run the installer once without it and every stored
credential is unrecoverable.

It still decrypts on Trixie: commit `f26d176` dropped `-blocksize` from
`Crypt::CBC->new()` for Crypt::CBC 3.x, and the ciphertext is byte-identical
either way.

### `SYSTEM_USER_MIN_UID` is not a UID floor

It never reaches `useradd`. It is a **username offset**:

```perl
Modules/User.pm:111   $user = $group =
    SYSTEM_USER_PREFIX . ( SYSTEM_USER_MIN_UID + admin_id )
```

`admin_id` 6 → `vu2006`. The numeric uid is whatever `useradd` allocates, read
back at line 133 with `getpwnam()` and stored in `admin.admin_sys_uid`. That is
why aws1 has `SYSTEM_USER_MIN_UID = 2000` while its uids run 1003–1196.

It cannot be preseeded (the modules read `%::imscpConfig` directly, never
`setupGetQuestion`), and it must not be changed — lowering it to 1000 would
*rename* every account, `vu2006` → `vu1006`. It stays 2000.

`30-restore-users.sh` recreates the accounts with their original names and ids
instead. `Modules/User.pm:120` then finds them via `getpwuid(admin_sys_uid)` and
falls through to a no-op `usermod`.

### Customer SQL users are not rebuilt, and their passwords exist in only two places

i-MSCP does **not** store customer SQL passwords. `sql_user` holds `sqlu_name`,
`sqlu_host` and `sqld_id` and nothing else — the `sqlu_pass` column was dropped
(`DatabaseUpdate` `r247`, alongside `ftp_users.rawpasswd`) — and there is no
`Modules/SqlUser.pm` that would recreate the accounts during a rebuild.

So a customer's database password lives in exactly two places:

1. MariaDB's grant tables, as a `mysql_native_password` hash, and
2. the customer's own application config on disk (`wp-config.php` and friends).

Nothing can look one up. If the accounts are not carried across, the only
recovery is resetting each password from the panel and then editing every
application config by hand.

Carrying the **hash** is what makes this transparent: the password itself never
changes, so a `wp-config.php` keeps working untouched. `10-dump-old.sh`
therefore emits two files:

| | |
|---|---|
| `users.sql` | `CREATE USER … IDENTIFIED VIA mysql_native_password USING '<hash>'` |
| `grants.sql` | the privilege statements, from `SHOW GRANTS` |

The accounts are generated explicitly rather than left to `SHOW GRANTS`,
because its syntax for the password differs by version — 10.3 emits
`IDENTIFIED BY PASSWORD`, 10.4+ emits `IDENTIFIED VIA … USING`. Reading the
hash out of `mysql.user` and emitting one canonical form removes that
dependency. On 10.3 a native-password account may carry its hash in `password`
with an empty `plugin`, so whichever column is populated is used.

Accounts *not* on a native password hash cannot be carried this way. They are
written to `users-unportable.txt` and reported by both scripts rather than
being discovered later.

**Verified on MariaDB 11.8.6**, not assumed: a 10.3-style
`GRANT … IDENTIFIED BY PASSWORD '*HASH'`, a `CREATE USER … IDENTIFIED BY
PASSWORD`, and `IDENTIFIED VIA mysql_native_password USING` are all accepted;
the plugin and hash are stored unchanged; and the original plaintext then
authenticates over both TCP and the unix socket. `mysql_native_password` is
still a core plugin in MariaDB 11.x — it is MySQL 8.4, not MariaDB, that
removed it.

### `memory_limit` reverts from 512M to 64M

`/etc/imscp/php/fpm/php.ini` is `<copy_config>` in `install.xml`, and
`_copyConfig()` overwrites unconditionally (`autoinstaller/Functions.pm:911`) —
restoring `/etc/imscp` does not protect it. Fixed in this branch by changing
`configs/debian/default/php/fpm/php.ini` in the fork, so it survives every
future run.

Three other templates are in the same position and were checked by diffing the
old tree against stock:

| File | aws1's change | Decision |
|---|---|---|
| `php/fpm/php.ini` | `memory_limit = 512M` (stock 64M) | **Kept**, in the fork |
| `apache/00_nameserver.conf` | permits TLSv1/1.1 | Dropped — stock disables them |
| `frontend/nginx.nginx` | hardcoded `ssl_protocols` | Dropped — placeholder gives TLSv1.2+1.3 |
| `frontend/00_master_ssl.nginx` | pre-Trixie version | Dropped — stock has the `800eea7` fix |

### Preseeding does not fall back to `imscp.conf`

`setupGetQuestion()` returns the preseed value or the *hardcoded default*; it
never consults `%::imscpConfig` under `--preseed`
(`engine/setup/imscp-setup-functions.pl:625`). Most visibly, a blank
`DATABASE_PASSWORD` silently rotates the master SQL credential. `preseed.pl`
therefore states every value explicitly.

### The custom Postfix config is regenerated

`main.cf` and `master.cf` were hand-edited on aws1 and nothing protected them —
`listeners.d` held only the README. `listeners/10_saygoweb_postfix.pl` puts them
back the supported way, at priority `-99` so it runs after the Courier
installer's own `afterMtaBuildConf` listener and wins.

---

## What changes underneath

Versions confirmed against the box's apt candidates and the Sury index.

| | buster | trixie |
|---|---|---|
| MariaDB | 10.3 | 11.8.6 |
| PHP (customers) | 7.4 | 7.4.33 — still published for debian13 by Sury |
| Postfix | 3.4.14 | 3.10.13 |
| Apache | 2.4.38 | 2.4.68 |
| Nginx (panel) | 1.14.2 | 1.26.3 |
| ProFTPD | 1.3.6 | 1.3.8.c — `proftpd-basic` is now virtual, provided by `proftpd-core` |
| Courier | — | 5.2.11 |
| BIND | 9.11 | 9.20.26 — service is `named` |
| Composer | 1.9.0 | 2.2.29 — forced, never merged from old config |

Do **not** copy aws1's `named.conf.options`: it carries `dnssec-enable no`,
which BIND 9.18+ rejects outright. The Trixie template already drops it.

---

## The rest of the box

The four things above rebuild i-MSCP. They do not rebuild everything that is
*running* on aws1. Three groups have to be carried by hand, and none of them is
on the data volume.

### The panel is a git checkout, with uncommitted edits

`/var/www/imscp/engine` and `/var/www/imscp/gui` are symlinks into
`/var/www/imscp-sgw-git`, a working copy of `saygoweb/imscp` on branch
`feature/DNSUnderscore` at `e9144424` "Allow underscore in DNS name". That
commit is already an ancestor of `migrate/2026-09`, so the branch has nothing
to port. Two files are modified in the working tree and were never committed:

| File | Change | Decision |
|---|---|---|
| `gui/include/Input.php` | `return true;` inserted at the top of `isValidDomainName()`, and the invalid-character `preg_match` commented out | **Dropped.** It disables *all* domain-name validation, not just the underscore, and `e9144424` already allows `_` in the committed regex. |
| `gui/composer.lock` | regenerated by a `composer update` | Dropped — the installer regenerates it. |

Everything else `git status` reports is installer output and comes back on its
own: the four `Package/*/Handler.pm` files, the `gui/public/tools/*` symlinks,
and `gui/vendor` (phpMyAdmin, Roundcube, RainLoop, MonstaFTP).

`/var/www/imscp-20210716` is the tree left behind by the 2021 upgrade. Nothing
references it; it does not migrate.

### One plugin

`gui/plugins/` holds exactly one: **SGW_LetsEncrypt 2.0.1**, its own checkout of
`saygoweb/imscp-letsencrypt` on `master` at `0dcf723`. (`info.php` still names
the repo by its older `imscp-plugin-letsencrypt` URL; cosmetic.)

- `sql/001_create_letsencrypt_table.php` creates its table inside the `imscp`
  schema, so the database dump carries the plugin's state.
- The `plugin` table row arrives with that dump but **the files do not**. Clone
  the plugin into `gui/plugins/` at the same commit before the first panel
  login, or the panel finds a registered plugin with no code behind it.
- `backend/SGW_LetsEncrypt.pm` shells out to `certbot certonly --apache
  --no-bootstrap --non-interactive -d <name>`, and its `letsencryptInstall()`
  runs `snap install --classic certbot` and writes a `certbot renew` cron. So
  **snapd is a dependency**: aws1's certbot is the snap (5.7.0), and
  `/usr/local/bin/certbot` is a wrapper around it, not certbot itself.

### /usr/local

Nothing under `/usr/local` is packaged.

**`server-utils`.** `/usr/local/bin/server-utils` is a checkout, with twelve
symlinks into it from `/usr/local/bin`:

`apacheinipset` · `certbot` · `cidr-block` · `cipwhois` · `f2b-net-banned` ·
`install-wordpress` · `ipinipset` · `iptocidr` · `php-fpm-site` ·
`prefix-dates` · `whitelist-from-api` · `wordpress-replace`

`cipwhois-offsite` and `mail-copy-folder` are in the repo but not linked.

Its origin is `/home/cambell/src/sgw/server-utils.git`, a bare repo on aws1
itself. Whether that is the only copy needs confirming: it is not among the 30
repositories visible under `github.com/saygoweb`, but a private one would not
be. If aws1 really does hold the only copy, push it somewhere off the box
before it is decommissioned.

The tools are Python 3 and import `ipwhois`, `dnspython`,
`mysql-connector-python`, `requests` and `defusedxml`, installed on aws1 with
pip straight into `/usr/local/lib/python3.7/dist-packages`. Trixie's python3.13
is PEP 668 externally-managed, so that install refuses; use the repo's own
`.venv` (its tests already expect one) or `--break-system-packages`.

Three config files in `/etc` belong to them and are easy to miss:
`cipwhois.conf`, `iptocidr.conf`, and `php-fpm-site.conf` — which pins
`version=7.4`.

`/usr/local/bin/certbot` is **not** certbot. It is
`server-utils/certbot-wrapper/certbot`, a shell wrapper that brackets
`certonly` with `iptables -I INPUT -p tcp --dport 80 -j ACCEPT` / `-D`, then
calls `/snap/bin/certbot`. The plugin and the renewal cron both go through it,
so port 80 is closed by default on aws1 and that has to stay true.

**Go services**, in `/usr/local/sbin`:

| | Source | Config | Unit |
|---|---|---|---|
| `blockhandler` | `github.com/saygoweb/blockhandler` (private; the bare repo on aws1 is a clone, not the origin) | `/etc/blockhandler/config.yml` | `blockhandler.service` |
| `snivirtualproxy` | `github.com/saygoweb/snivirtualproxy` | `/etc/snivirtualproxy/config.yml` | `snivirtualproxy.service` |

Both are go1.26.2 builds. `/etc/logrotate.d/blockhandler` rotates both logs and
restarts both units. `/usr/local/sbin/unblock` still calls `fail2ban-client set
~whitelist-blockhandler banip` — fail2ban is deconfigured (`rc`), so the script
is already dead. Rewrite it against jailtime or drop it.

**Reinstall rather than copy:** composer 2.7.1 (and the kept `composer_1.x`),
`wp-cli` 2.11.0, `imapsync` 2.178, and `ipwhois_cli` / `ipwhois_utils_cli`,
which are pip entry points that return with the `ipwhois` install.

**Loose scripts with no repo.** Carry them as files — but several name ipsets
and paths that no longer exist:

| Script | Note |
|---|---|
| `panel-combine-ssl` | Concatenates the LE privkey+fullchain into `/etc/imscp/my.saygoweb.com.pem` and restarts nginx. **This is the missing renewal hook** — see "Still open". |
| `courier-combine-ssl` | The same for `/etc/courier/{imapd,pop3d}.pem`; uses `/etc/init.d/courier-*-ssl restart`, so move it to `systemctl`. |
| `badnetworks-country.sh`, `blockcidr-country.sh`, `blockcidr-country2.sh` | ipset→country reports against `f2b-bad-networks` and `f2b-block_cidr`. jailtime names its sets `jt_<jail>`, so these read nothing today. Repoint at `jt_bad-networks` / `jt_block-cidr`. |
| `whitelist-ip-country.sh` | The same report, already updated to `jt_whitelist-blockhandler`. |
| `ipset-add-cidr` | Feeds `date time cidr` lines into `f2b-block_cidr` — same stale name. |
| `update-php-fpm-pool` | Hardcodes `/etc/php/7.4/fpm/pool.d`. |
| `set-cpu-quota.sh`, `log-php-cpu.sh`, `mkpark`, `htop-filter` | Carry as they are. |
| `postanalyze` | **Python 2**, which Trixie does not have. Superseded by `saygoweb/postfix-analyzer` (checked out at `/home/cambell/postfix-analyzer`). Drop. |
| `authprogs` | **Do not drop.** An earlier pass recorded this as unreferenced; it is not. authprogs gates root SSH on aws1 right now — confirmed by connecting: `hostname` and `uptime` succeed and everything else returns *"You're not allowed to run …"*. That reading was made without root, so `/root/.ssh/authorized_keys` was not visible. It is **Perl**, so Trixie runs it unchanged. See *Root SSH access* below. |

### Root SSH access, and automating the dump

Root SSH on aws1 is gated by **authprogs** (Bri Hatch, 2003) via a
`command="…"` wrapper in `/root/.ssh/authorized_keys`, reading
`/root/.ssh/authprogs.conf`. The format is a bracketed list of source IPs
followed by one allowed command per line:

```
[ ALL ]
    hostname
    uptime
```

Matching is **exact** — no regex, no shell metacharacters. That single
constraint decides the whole design of the automation below.

**Two wrappers, not three tool allowlists.** `migrate/authprogs.conf.snippet`
adds exactly two commands, both no-argument scripts:

| Command | What it does |
|---|---|
| `/root/mig/dump-for-migration` | runs `10-dump-old.sh`, then writes `MANIFEST.sha256` inside the payload |
| `/root/mig/send-migration-tar` | streams `/root/mig` to stdout as a tar |

Install them on aws1 first:

```sh
cd /home/cambell/imscp/migrate/scripts
sudo install -m 0700 -o root -g root aws1-dump-for-migration /root/mig/dump-for-migration
sudo install -m 0700 -o root -g root aws1-send-migration-tar /root/mig/send-migration-tar
```

Then from the new box, `15-pull-from-aws1.sh` drives both ends:
`--check` proves the channel and reports which commands are still denied,
the default runs the dump and pulls it, and `--pull-only` re-fetches without
re-dumping. It verifies the manifest after extraction and refuses to declare
success on a checksum mismatch.

**Why not allowlist `mysql`, `mysqldump` and `rsync` directly.** `mysql -e
'<sql>'` is arbitrary SQL as root — every customer database, readable and
writable. `mysqldump`'s `--result-file` writes anywhere as root. And `rsync`
cannot be pinned safely at all under exact matching: rsync over ssh asks the
far end to run `rsync --server --sender -<flags> . <path>`, where the flag blob
encodes both the client's options and its version. Measured against aws1,
`-aHz` produces `-lHogDtprze.iLsfxCIvu` and `-az` produces
`-logDtprze.iLsfxCIvu`. An exact-match entry would work until either side's
rsync is upgraded, then fail inside a cutover window. A no-argument command
streaming a tar has one spelling, permanently.

**On the new box.** authprogs is Perl, so it carries across as-is — Trixie
ships perl 5.40. Copy the script, `/root/.ssh/authprogs.conf` and the
`command="…"` wrapper in `/root/.ssh/authorized_keys` together; none of the
three is any use without the other two. Remove the two migration rules once the
migration is done.

### jailtime

jailtime is **not a Debian package** — `dpkg -l` knows nothing about it. It was
installed by hand, and every piece has to be placed by hand again.

**Binaries.** `/usr/sbin/jailtime` and `/usr/sbin/jailtimed`, v1.0.5, go1.26.2,
module `github.com/sgw/jailtime`, `vcs.revision
624866fe41a22556f7890b10a3378307f8b8a4d8`.

The source is **not** on aws1, but it is not lost either — it is at
`git@github.com:saygoweb/jailtime.git`. Clone it and build against the Trixie
toolchain rather than copying the buster binaries across.

Note the recorded module path (`github.com/sgw/jailtime`) is an older name than
the repository's current one, so do not assume `master` is what aws1 is
running: check out the revision matching
`624866fe41a22556f7890b10a3378307f8b8a4d8` if you want to reproduce it exactly,
and take anything newer deliberately rather than by accident.

jailtime, `blockhandler` and `snivirtualproxy` all live under
`github.com/saygoweb`, so none of them needs rescuing before aws1 is
decommissioned — `server-utils` is the only one still in question.

**Everything it owns:**

| Path | What |
|---|---|
| `/usr/sbin/jailtime`, `/usr/sbin/jailtimed` | CLI and daemon |
| `/usr/local/lib/jailtime/*.sh` | seven wrappers — `ipset-ensure`, `ipset-flush`, `ipset-add-cidr`, `ipset-test-cidr`, `iptables-ensure`, `iptables-remove`, `cidrlog` |
| `/usr/share/doc/jailtime/` | `README.md`, five sample jails, the six upstream tool scripts |
| `/etc/systemd/system/jailtimed.service` | `ExecStart=/usr/sbin/jailtimed --config /etc/jailtime/jail.yaml` |
| `/etc/systemd/system/jailtimed.service.d/override.conf` | `CPUAccounting=yes` and `ProtectHome=false` — see below |
| `/etc/jailtime/jail.yaml` | main config: logging to the journal, control socket, `watcher_mode: auto`, and the `on_start`/`on_stop` chain setup |
| `/etc/jailtime/jails.d/*.yaml` | 13 jails |
| `/etc/jailtime/whitelists.d/*.yaml` | 5 whitelists |
| `/etc/jailtime/blocklist/` | `cidr-block.txt`, `dshield-block.txt` |
| `/etc/jailtime/whitelist/` | `cloudflare.txt`, `elijah.txt`, `local.txt`, `stripe.txt`, `uptimerobot.txt` |

The unit also declares `RuntimeDirectory=jailtime` (`/run/jailtime`, holding
`jailtimed.sock`), `CacheDirectory=whois_cache` (`/var/cache/whois_cache`,
~208 MB, shared with `cipwhois`) and `LogsDirectory=intrusion`
(`/var/log/intrusion`, group `intrusion`). That group is gid 1002, inside the
1001–1196 range `30-restore-users.sh` already recreates, so it arrives for
free — but the admin login `cambell` (uid 1001, primary group `staff`) is
outside that range and is not created by any script here.

**The jails.**

| Jail | Reads | Window | What it does |
|---|---|---|---|
| `dshield-block` | `blocklist/dshield-block.txt` | static, permanent | bans each row as a `/24`; DROP, all ports |
| `block-cidr` | `blocklist/cidr-block.txt` | static, permanent | DROP, all ports |
| `apache-sgw-bounce-cidr` | `/var/log/apache2/*/access.log` | 1 hit / 30m → 24h | resolves the IP to its `/24` via `iptocidr`, then **NAT-redirects** 443 → 8081 |
| `apache-sgw-bounce-ip` | ″ | 1 hit / 30m → 168h | two sets — `…-nat` redirects 443 → 8081, the other DROPs 80,443 |
| `apache-sgw-notfound` | ″ | 20 hits / 1h → 24h | DROP 80,443 |
| `apache-sgw-badbots` | ″ | 1 hit / 4h → 168h | DROP 80,443,8081,8082 |
| `postfix-rbl` | `/var/log/mail.log` | 1 hit / 4h → 168h | DROP 25,465,587,143,993,110,995 |
| `postfix-sasl` | ″ | 4 hits / 30m → 5m | ″ |
| `postfix` | ″ | 3 hits / 20m → 20m | DROP 25,465,587 |
| `courierauth` | ″ | 3 hits / 20m → 20m | DROP 25,465,587,143,993,110,995 |
| `blockhandler` | `/var/log/blockhandler.log` | 8 hits / 20m → 4h | DROP 8081,8082, and appends the offender's `/24` to `bad-networks.log` |
| `bad-networks` | `/var/log/intrusion/bad-networks.log` | 3 hits / 2h → 169h | CIDR set, DROP 80,443,8081,8082 |
| `sshd` | `/var/log/auth.log` | 2 hits / 20m → 24h | DROP 22 |

Ports 8081 and 8082 are `snivirtualproxy` and `blockhandler`: the two Apache
"bounce" jails do not drop traffic, they redirect it there, which is what makes
the self-service unblock page reachable by an IP that is otherwise jailed.

**And five whitelists**, which feed the `JT_WHITELIST` chain ahead of every
jail: `cloudflare` and `whitelist-cidr` (static CIDR files), `whitelist-ip`
(static IP files), `customer-ip` (learns from `mail.log` — 4 successful
authentications in an hour buys 24h) and `whitelist-blockhandler` (learns from
`blockhandler.log` — 1 hit in 5m buys a week; this is the self-service unblock
path).

Each whitelist owns a `jt_<name>` set too, ACCEPTs it from `JT_WHITELIST` and
adds a `RETURN` in nat `PREROUTING` so a whitelisted address is not bounced to
the block page. `cloudflare` is additionally named in the four Apache jails'
`ignore_sets`, so a Cloudflare egress IP is never entered into a jail at all.

`bad-networks.log` is not written by any service: the `blockhandler` jail's
`on_add` produces it, piping `iptocidr {{ .IP }}` through
`/usr/local/lib/jailtime/cidrlog.sh`. So `iptocidr` must be on `PATH` before
jailtime starts, which puts `server-utils` ahead of jailtime in the build order.

**Firewall model.** `on_start` creates the `JT_WHITELIST` and `JT_BLOCKLIST`
chains and inserts them at `INPUT` positions 2 and 3; each jail owns an ipset
named `jt_<jail>`. No ipset or iptables persistence package is installed, so
after a reboot the static sets rebuild from the files and dynamic bans are
simply lost. That is the existing behaviour — nothing under `/var/lib` has to
migrate.

On Trixie `iptables` is nft-backed. The wrappers rely on `iptables -C/-I/-D`
and `-m set --match-set`, which `iptables-nft` supports through `xt_set`.
Verify that early rather than at cutover: a jailtime that cannot build its
chains fails at `on_start` and silently protects nothing.

**Dependencies:** `ipset`, `iptables`, `jq` (the country reports), `iptocidr`
on `PATH`, `blockhandler`, `fs.inotify.max_user_watches = 65535` (aws1's
`/etc/sysctl.d/99-sysctl.conf`), and rsyslog writing `mail.log` and `auth.log`.

**The `/home/cambell/jailtime` question.** There is a full working copy of the
config tree at `/home/cambell/jailtime`, and it is the copy actually being
edited — its `jails.d` files carry mtimes days later than the `/etc` snapshot
they were taken from. Its own `jail.yaml` uses *relative* includes
(`jails.d/*.yaml`), which would resolve under `/etc`; but the unit's
`ProtectHome=false` override only makes sense if the live
`/etc/jailtime/jail.yaml` includes the `/home` path. `/etc/jailtime` is
`root:root 0750` and this could not be settled from an unprivileged session.
**Read the real `jail.yaml` during the dump** — `10-dump-old.sh` runs as root
and archives `/etc/jailtime` whole — reconcile it against the working copy,
and on the new box install the tree at `/etc/jailtime` only, with relative
includes and `ProtectHome=true`.

**Not migrating.** fail2ban is `rc`: deconfigured, its `/etc` left behind,
replaced by jailtime. crowdsec 1.4.3 and `crowdsec-firewall-bouncer-iptables`
are still installed and unit-enabled but are not running. Install neither.
`/etc/fail2ban` survives on aws1 only because `cidr-block`'s
`DEFAULT_BLOCKLIST_FILE` still points at
`/etc/fail2ban/blocklist/cidr-block.txt` while jailtime reads
`/etc/jailtime/blocklist/cidr-block.txt`. Repoint the tool, then drop
`/etc/fail2ban`.

---

## Order of work

Phases 1–5 run while aws1 stays live. Phase 6 is the first irreversible step.
Phase 9 is the cutover.

| # | Step | Where |
|---|---|---|
| 1 | `scripts/00-preflight.sh` | new box, read-only |
| 2 | `scripts/10-dump-old.sh`, or `scripts/15-pull-from-aws1.sh` to drive it remotely | **aws1** / new box |
| 3 | `scripts/20-mount-data.sh` | new box |
| 4 | `scripts/30-restore-users.sh` | new box |
| 5 | `scripts/40-restore-imscp-identity.sh` + `50-restore-db.sh` | new box |
| 6 | run the installer with `preseed.pl` | new box |
| 7 | rebuild `/usr/local`, jailtime and the Go services | new box, by hand |
| 8 | `scripts/60-verify.sh` + `scripts/70-test-services.sh` | new box |
| 9 | move the Elastic IP | AWS |

Every script honours `DRY_RUN=1` to preview and `MIGRATE_YES=1` to skip
prompts.

### 1. Preflight

```sh
cd migrate/scripts && ./00-preflight.sh
```

Checks the distribution, that i-MSCP is not already installed, that aws1's
`/etc` and the db-keys are readable, that the data volume is attached, that no
uid/gid in 999 or 1001–1196 collides, disk space, and that apt can resolve
every package the chosen alternatives need.

### 2. Capture aws1

On the old box:

```sh
./10-dump-old.sh /root/mig
rsync -aHz /root/mig/ newbox:/root/mig/
```

Dumps each database separately (the `mysql` schema cannot be carried from 10.3
to 11.8), captures the SQL accounts and their password hashes, the grants,
`imscp-db-keys`, `imscp.conf`, the Postfix support files, `passwd`/`group`,
Let's Encrypt, the jailtime tree, all of `/usr/local`, the `jailtimed`,
`blockhandler` and `snivirtualproxy` units, the loose `/etc` configs those
tools read, root's crontab, and the two bare git repos that exist nowhere
else.

Take a rehearsal copy now and **run it again during the cutover window** with
mail and web stopped. That matters for more than freshness:
`--single-transaction` only gives a consistent snapshot for InnoDB, so any
MyISAM tables are dumped unlocked.

A failed dump deletes its own partial `.sql.gz` and stops the script rather
than leaving truncated data to be restored later.

aws1 runs with `event_scheduler=DISABLED`, which makes `mysqldump --events`
fail with `ERROR 1577`. The script probes for this and drops `--events` when it
cannot be used, reporting whether anything is actually lost by reading
`mysql.event` directly — that table is readable whatever the scheduler is
doing. On aws1 it is empty, so nothing is.

### 3–5. Prepare the new box

```sh
./20-mount-data.sh              # volume by UUID + /var/mail/virtual symlink
./30-restore-users.sh           # 146 groups, 146 users, exact ids
./40-restore-imscp-identity.sh  # db-keys, imscp.conf, DQ key, certs, listener
./50-restore-db.sh              # MariaDB, dumps, grants, mariadb-upgrade
```

`/var/mail/virtual` is a symlink into the data volume, as on aws1:

```
virtual -> /var/www/virtual/_mail/virtual
```

### 6. Install

```sh
export IMSCP_MASTER_SQL_PASSWORD='...'      # see "Secrets" below
cd /home/cambell/imscp
perl imscp-autoinstall -d --preseed "$PWD/migrate/preseed.pl" 2>&1 \
  | tee /root/mig/install.log
```

`loadConfig()` sees the restored `imscp.conf` and treats this as an upgrade,
merging aws1's values over the Trixie defaults (holding back `Build`,
`Version`, `CodeName`, `PluginApi`, `THEME_ASSETS_VERSION`, `COMPOSER_VERSION`;
`DISTRO_*` is re-derived from LSB). The tail of the run rebuilds all 380
vhosts, 192 pools, the zones and the Postfix maps.

At this scale that queue is the long pole, and a few entities finishing in an
error status rather than `ok` is normal. Fix the cause and re-run:

```sh
perl /var/www/imscp/engine/setup/imscp-reconfigure -dv
```

### 7. The rest of the box

No script does this part; work through *The rest of the box* above, in this
order, because each step is a dependency of the next:

1. clone `server-utils` — from `github.com/saygoweb` if it is there, otherwise
   from the bare-repo archive `10-dump-old.sh` takes, pushing it somewhere off
   aws1 while you are at it;
2. lay down `/usr/local/bin/server-utils` and its twelve symlinks, install the
   Python dependencies into the repo's `.venv`, and restore `cipwhois.conf`,
   `iptocidr.conf` and `php-fpm-site.conf` — `iptocidr` has to resolve on
   `PATH` before jailtime starts;
3. build and install `blockhandler` and `snivirtualproxy` with their configs,
   units and the shared logrotate entry;
4. clone jailtime from `git@github.com:saygoweb/jailtime.git` and build it for
   Trixie, then install the binaries, the
   `/usr/local/lib/jailtime` wrappers, the unit and its drop-in, and the
   reconciled `/etc/jailtime` tree; then confirm `iptables-nft` really does
   accept `-m set --match-set` before trusting it;
5. clone `SGW_LetsEncrypt` into `gui/plugins/`, install the certbot snap, and
   add `panel-combine-ssl` as a certbot deploy hook.

### 8. Verify

Two scripts, checking different things. `60-verify.sh` inspects the box's
internal state — files, database rows, units. `70-test-services.sh` checks
that the services actually answer correctly over the network.

```sh
./60-verify.sh
./70-test-services.sh --target <new box IP> --roundtrip
```

**`--target` is not optional before cutover.** DNS still points at aws1, so
without it every check passes by testing the old box. With it, connections go
to the given address while SNI and `Host` still carry the real names.

`70-test-services.sh` covers:

- TLS on 25, 587, 465, 993, 995, 443 (mail and main) and the panel on 8443,
  checking the handshake, that the certificate's SAN covers the name it was
  asked for, and how many days it has left.
- The SMTP capability set, which is a direct regression test of the Postfix
  listener: port 25 must **not** advertise `AUTH` while 587 and 465 must. The
  Courier installer sets `smtpd_sasl_auth_enable` to `yes` and the listener
  overrides it back at priority −99; if that ordering ever breaks, port 25
  starts advertising AUTH and this catches it.
- The Courier IMAP and POP3 greetings.
- `https://arketec.com` (no WordPress) and `https://elijahshort.co.nz`
  (WordPress). The second asserts WordPress markers are present in the rendered
  HTML, which proves PHP-FPM ran rather than Apache just returning a file.
- With `--roundtrip`, a full mail cycle through `test@inthefish.com`: submit on
  587 with STARTTLS and AUTH, then poll IMAP until the message arrives. That
  exercises submission, delivery into the migrated maildir
  (`inthefish.com/test/` on the data volume) and IMAP retrieval in one go. The
  password is prompted for, or taken from `TEST_MAIL_PASS`, and is passed to
  curl through `--config` so it never appears in `ps`.

Take a baseline from aws1 while it is still live, and compare:

```sh
./70-test-services.sh --baseline > /root/mig/baseline.txt
```

In baseline mode an unexpected HTTP status is recorded rather than failed,
since the point is to capture what is true today.

**One thing the baseline already showed:** `saygoweb.com` is proxied through
Cloudflare, so a request to it never reaches Apache — a managed challenge comes
back as 403. The script detects this and says so rather than reporting a
failure. Only `--target` tests that origin. `arketec.com`,
`elijahshort.co.nz`, `mail.saygoweb.com` and the panel are all direct.

Also worth doing by hand:

- log into the panel at `https://my.saygoweb.com:8443`
- open a customer and read a mailbox password — proves the key survived
- IMAP login against a real mailbox; send mail into an existing maildir
- `postconf -n` diffed against `/root/mig/etc/postfix-postconf-n.txt`
- a sample of sites, not just one

### 9. Cutover

Lower DNS TTLs ahead of time. Then: stop mail and web on aws1, re-run
`10-dump-old.sh`, reload, re-verify, move the Elastic IP.

Rollback is free until the IP moves — aws1 is untouched. The one genuinely
destructive act is detaching the data volume from aws1, so **snapshot it
first**.

---

## Secrets

Nothing secret is committed. `.gitignore` covers `secrets.sh`,
`preseed.local.pl` and any dumps.

- **Master SQL password** — `preseed.pl` reads `IMSCP_MASTER_SQL_PASSWORD` and
  dies with an explanation if unset. The base64 string in aws1's `imscp.conf`
  is Rijndael-CBC ciphertext under `imscp-db-keys`, *not* the password; the
  installer encrypts the cleartext itself
  (`Servers/sqld/mysql/installer.pm:452`).
- **Spamhaus DQ key** — a paid Data Query credential. Extracted from aws1's
  `main.cf` by `40-restore-imscp-identity.sh` into `/etc/postfix/dq-key`
  (mode 0600) and read from there at runtime. Without it the listener falls
  back to the free public zen/dbl zones.

---

## Still open

- **Panel certificate renewal.** `00_master_ssl.nginx` reads a combined
  `/etc/imscp/my.saygoweb.com.pem` that the installer assembles from the
  `PANEL_SSL_*` inputs. Certbot renewing the source files does not rebuild that
  pem, and aws1 had no deploy hook that did. The current cert expires
  **2026-10-28**. `/usr/local/bin/panel-combine-ssl` does exactly the right
  thing and is simply never called — wire it in as a certbot `--deploy-hook`
  on the new box, and `courier-combine-ssl` alongside it.
- **PHP 7.4** is end-of-life. All 192 pools come across as they are, but plan a
  per-site move to 8.x from the panel afterwards. `php-fpm-site.conf` pins
  `version=7.4` and moves with them.
- **`rsyslog`** must stay installed and writing `/var/log/mail.log` and
  `/var/log/auth.log`: four jailtime jails and one whitelist read the first,
  one jail reads the second,
  and i-MSCP's traffic accounting also reads `mail.log`
  (`MAIL_TRAFF_LOG = mail.log`).
- **Who refreshes the blocklists?** `dshield-block.txt` and `cidr-block.txt`
  are described in their jail comments as "updated weekly via API", but no
  job in `/etc/cron.d` does it and root's crontab is not readable from an
  unprivileged session. `10-dump-old.sh` now captures it; whatever is in there
  has to come across too, or both lists go stale.
- **Which `jail.yaml` is live.** See *The rest of the box* — the `/etc` copy
  could not be read here, and the `/home/cambell/jailtime` working copy has
  been edited since it was taken. Settle it from the root dump.
- **Is `server-utils` backed up anywhere?** `blockhandler`, `snivirtualproxy`
  and `jailtime` are all under `github.com/saygoweb`. `server-utils` is not
  among the 30 repositories visible there, though a private one would not be
  either. It is the last candidate for existing only as a bare repo on aws1, so
  confirm before the box is destroyed. `10-dump-old.sh` archives it meanwhile.
