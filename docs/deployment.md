# How aws1 deploys i-MSCP

`aws1` does not run an installed copy of i-MSCP. It runs **this checkout**, at
`/var/www/imscp-git`, with the two directories i-MSCP actually executes symlinked
at the paths it expects:

```
/var/www/imscp/engine -> /var/www/imscp-git/engine
/var/www/imscp/gui    -> /var/www/imscp-git/gui
/var/www/imscp/daemon    real directory (compiled C, built by the installer)
/var/www/imscp/backups   real directory
```

The deployed branch is `migrate/2026-09`. `main` is merged *into* it, never the
other way: `saygoweb/imscp` is a public fork and the site-local values —
`memory_limit = 512M`, `BIND_SITE_CONF_FILE`, `BIND_ALLOW_TRANSFER_EXTRA`, the
Vagrantfile mounts — belong to this branch alone.

## Upgrading

```sh
sudo git -C /var/www/imscp-git pull
sudo perl /var/www/imscp/engine/setup/imscp-reconfigure -dv
```

Pull **as root**. Root executes `engine/` from cron (`imscp-rqst-mngr`, backup,
quota, traffic), so the checkout must never be writable by an unprivileged user.

### The boundary rule

A pull is enough only while the incoming diff stays inside `engine/` and `gui/`.
If it touches **`configs/`, `autoinstaller/`, `daemon/` or
`engine/setup/imscp-update-db.php`**, those are installed *into* `/etc/imscp`,
`/var/www/imscp/daemon` and the database by the autoinstaller, and a pull moves
nothing. Then:

```sh
sudo perl /var/www/imscp-git/autoinstaller/imscp-autoinstall -dv
# setupInstallFiles() removes and re-creates gui/ and engine/ as real
# directories, destroying both symlinks. Put them back:
sudo rm -rf /var/www/imscp/gui /var/www/imscp/engine
sudo ln -s /var/www/imscp-git/gui    /var/www/imscp/gui
sudo ln -s /var/www/imscp-git/engine /var/www/imscp/engine
```

Forgetting this is the failure mode to fear: everything keeps working, but from
a real directory, and every later `git pull` silently stops taking effect.

## Why this is safe

- `engine/` and `gui/` are installed by **verbatim copy** — `<copy>` in
  `engine/install.xml`, a bare `rcopy` in `_buildFrontendFiles()`. No variable
  substitution, so a checkout is code-equivalent to an install.
- `imscp-reconfigure` runs `setupTasks()` only — it has **no `setupInstallFiles`
  step** — so it preserves the symlinks and re-runs every server installer
  against the pulled code.
- `iMSCP::Dir::remove` → `File::Path::remove_tree`, which on a symlink-to-directory
  unlinks the symlink and leaves the target untouched. A full autoinstall can
  never eat the checkout; it only removes the links.
- `setRights(..., recursive => 1)` uses `File::Find` **without `follow`**, so on a
  symlinked `engine`/`gui` it visits only the link and `lchown`s it.

That last point is the one with teeth: **i-MSCP no longer maintains ownership or
modes inside the checkout.** It will neither repair nor clobber them. They are
yours to keep right.

## What lives in the checkout but is not in git

Generated at install time, and excluded via `.git/info/exclude`:

| Path | What it is |
|---|---|
| `gui/vendor/` (229 MB), `gui/library/`, `gui/data/` | composer output and runtime state — already gitignored |
| `gui/plugins/` | three plugin git checkouts (`SGW_ApacheCache`, `SGW_LetsEncrypt`, `SGW_PhpVersion`) |
| `gui/public/tools/{phpmyadmin,rainloop,roundcube,monstaftp}` | symlinks into `gui/vendor` |
| `gui/bin/composer.phar` | the composer binary |
| `engine/PerlLib/Package/*/*/Handler.pm` (×4) | written by the package handlers |

Two **tracked** files are rewritten in place by composer and are held with
`git update-index --skip-worktree`:

- `gui/composer.lock`
- `gui/composer.json` — the deployed copy is composer-reformatted and carries
  four extra requires (`imscp/monsta-ftp`, `imscp/phpmyadmin`, `imscp/rainloop`,
  `imscp/roundcube:dev-1.3.x-sgw`) added by those same four `Handler.pm` files.
  It must stay in step with `gui/vendor/`, so the *deployed* copy wins, not the
  branch's.

`core.fileMode false` is set in the checkout and in each plugin repo: i-MSCP owns
the modes (`engine` a blanket 0750, `gui` 0750/0640), and git must not fight it.

## Ownership and modes

```
/var/www/imscp-git          root:root      0755   (traversable, so the links resolve)
/var/www/imscp-git/engine   root:imscp     0750   blanket, per set-engine-permissions.pl
/var/www/imscp-git/gui      vu2000:vu2000  dirs 0750 / files 0640
```

but **do not apply that as a blanket rule.** Several paths are deliberately
tighter than `setGuiPermissions` would leave them, because the engine writes them
as root *after* the permission pass:

- `gui/data/certs/` — `root:root 0750`, holding ~155 `*.pem` **SSL private keys**
  at `root:root 0600`. A blanket `chown -R vu2000` here hands every site's private
  key to the panel user.
- `engine/PerlLib/Package/AntiRootkits/Rkhunter/Cron.pl` and
  `.../WebStatistics/AWStats/Scripts/awstats_updateall.pl` — `root:root 0700`.

After anything that rewrites ownership wholesale, compare against a known-good
tree rather than trusting the rule:

```sh
find /var/www/imscp-git/gui -printf '%m %u:%g %y %p\n' | sort -k4
```

Note also that i-MSCP's `filemode => 0640` pass strips `+x` from the dev and test
scripts inside the plugin repos. `core.fileMode false` keeps that out of
`git status`; `git checkout -- .` in the plugin restores the bits if you need them.

## Rebuilding the checkout from nothing

```sh
sudo git clone --branch migrate/2026-09 https://github.com/saygoweb/imscp.git /var/www/imscp-git
sudo rsync -a --ignore-existing /var/www/imscp/engine/ /var/www/imscp-git/engine/
sudo rsync -a --ignore-existing /var/www/imscp/gui/    /var/www/imscp-git/gui/
```

`--ignore-existing` is not optional. A plain `rsync -a` copies the *older
deployed* tree over the checkout and silently reverts every code change you just
pulled.

Then take `composer.json`/`composer.lock` from the deployment, replay the
ownership and modes from it, set `core.fileMode false`, `skip-worktree` the two
composer files, write `.git/info/exclude`, and only then swap the symlinks in.
