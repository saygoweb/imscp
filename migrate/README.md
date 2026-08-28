# aws1 migration: Debian 10 (buster) → Debian 13 (trixie)

Moving the i-MSCP control panel from `aws1` to a new Trixie box, keeping the
hostname `aws1.saygoweb.com` and the Elastic IP `34.212.49.11`.

Derived from the old box's `/etc`, copied to `/home/cambell/etc`.

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

### Customer SQL users are not rebuilt

There is no `Modules/SqlUser.pm`. The `sql_user` table is panel metadata only —
the actual MySQL users exist solely in the grant tables. Without `grants.sql`
every customer application loses its database login while the panel still shows
the user as present.

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

## Order of work

Phases 1–5 run while aws1 stays live. Phase 6 is the first irreversible step.
Phase 8 is the cutover.

| # | Step | Where |
|---|---|---|
| 1 | `scripts/00-preflight.sh` | new box, read-only |
| 2 | `scripts/10-dump-old.sh` | **aws1** |
| 3 | `scripts/20-mount-data.sh` | new box |
| 4 | `scripts/30-restore-users.sh` | new box |
| 5 | `scripts/40-restore-imscp-identity.sh` + `50-restore-db.sh` | new box |
| 6 | run the installer with `preseed.pl` | new box |
| 7 | `scripts/60-verify.sh` | new box |
| 8 | move the Elastic IP | AWS |

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
to 11.8), captures the grants, `imscp-db-keys`, `imscp.conf`, the Postfix
support files, `passwd`/`group`, Let's Encrypt and the jailtime tree.

Take a rehearsal copy now and **run it again during the cutover window** with
mail and web stopped.

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

### 7. Verify

```sh
./60-verify.sh
```

Everything it checks can be checked with aws1 still serving, by pointing a
hosts file at the new box. Also worth doing by hand:

- log into the panel at `https://my.saygoweb.com:8443`
- open a customer and read a mailbox password — proves the key survived
- IMAP login against a real mailbox; send mail into an existing maildir
- `postconf -n` diffed against `/root/mig/etc/postfix-postconf-n.txt`
- a sample of sites, not just one

### 8. Cutover

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
  **2026-10-28**; worth adding a renewal hook.
- **PHP 7.4** is end-of-life. All 192 pools come across as they are, but plan a
  per-site move to 8.x from the panel afterwards.
- **`rsyslog`** must stay installed and writing `/var/log/mail.log`: two
  jailtime jails read it, and so does i-MSCP's traffic accounting
  (`MAIL_TRAFF_LOG = mail.log`).
- **jailtime** replaces fail2ban and CrowdSec, both of which were also enabled
  on aws1. `jail.yaml` includes `/home/cambell/jailtime/jails.d/*.yaml` — a
  development path; point it at `/etc/jailtime/org/jails.d/` on the new box.
  `fs.inotify.max_user_watches = 65535` from aws1's `sysctl.d` is needed by its
  watchers.
