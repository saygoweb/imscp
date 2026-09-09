# engine/ — Perl backend

## Layout

- `PerlLib/iMSCP/` — libraries. Notable: `Service.pm` (+ `Provider/Service/{Systemd,SysVinit,Upstart,Debian/*}`),
  `Dir.pm`, `File.pm`, `Rights.pm`, `Mount.pm`, `Execute.pm`, `EventManager.pm`, `Getopt.pm`,
  `Dialog.pm` (+ `Dialog/NonInteractive.pm`, `Dialog/InputValidation.pm`), `Bootstrapper.pm`,
  `Database.pm`, `DbTasksProcessor.pm`, `Composer.pm`, `LockFile.pm`, `Net.pm`, `Requirements.pm`,
  `Plugins.pm`, `Provider/Networking/*`.
- `PerlLib/Servers/<class>/` — one directory per service class: `httpd`, `mta`, `po`, `named`, `ftpd`,
  `sqld`, `cron`, `php`, `server`. Each holds the implementations (e.g. `httpd/apache_php_fpm/`,
  `po/dovecot/`, `po/courier/`), each with `installer.pm` and `uninstaller.pm`. `noserver.pm` is the
  null implementation. The active one comes from `imscp.conf` (`HTTPD_SERVER`, `PO_SERVER`, …).
- `PerlLib/Package/` — optional add-ons: `FrontEnd`, `AntiRootkits`, `SqlAdminTools`, `WebmailClients`,
  `WebFtpClients`, `WebStatistics`, `BackupFeature`, `AltUrlsFeature`, `ServicesSSL`.
- `PerlLib/Modules/` — per-entity work units the daemon runs: `Domain`, `Alias`, `Subdomain`,
  `SubAlias`, `Mail`, `FtpUser`, `Htaccess`, `Htgroup`, `Htpasswd`, `CustomDNS`, `SSLcertificate`,
  `User`, `ServerIP`, `Plugin`. Each processes rows carrying a `*_status` column.
- `setup/` — `imscp-setup-functions.pl` (the install steps), `imscp-reconfigure`,
  `imscp-uninstaller`, `set-engine-permissions.pl`, `set-gui-permissions.pl`, `imscp-update-db.php`.
- `backup/`, `messenger/`, `quota/`, `traffic/`, `tools/` — cron-driven scripts.
- `PerlVendor/` — vendored CPAN modules, shipped rather than installed.

## Behaviours that will bite you

- **`setupInstallFiles()` (`setup/imscp-setup-functions.pl`) removes `$ROOT_DIR/{daemon,engine,gui}`
  outright** at the start of every install *and* every reconfigure, then rcopies the freshly built
  tree from `INST_PREF` onto `/`. Anything left in those directories is destroyed, and a directory
  holding a live bind mount cannot be removed at all.
- `iMSCP::Rights::setRights` with `recursive` walks via `File::Find` **without `follow`** and uses
  `lchown`: symlinks are retagged in place, never followed, and `chmod` is skipped for them. So a
  recursive permission fix cannot reach through a symlink into another tree.
- `iMSCP::Dir::remove` uses `File::Path::remove_tree`, which **unlinks a symlink rather than
  descending** into it.
- `iMSCP::File::save` opens with `>` and truncates in place — it does not write-and-rename, so it
  works on files that are bind mounts (Docker's `/etc/hosts`, `/etc/resolv.conf`).
- `iMSCP::Service::_init` decides the init system by `-d '/run/systemd/system'`.
- `iMSCP::Plugins` finds backends by globbing `$PLUGINS_DIR/*/backend/*.pm` and loads one **only when
  the plugin directory name equals the `.pm` basename**.
- Engine scripts and the daemon run as root; the panel runs as its own unprivileged user.

Installer flow and the preseed/dialog rules are in `mem:installer/core`.
