# i-MSCP — Project Core

saygoweb fork of i-MSCP 1.5.3. Shared-hosting control panel: it installs and then keeps
configuring a whole Linux hosting stack (apache2, nginx, postfix, dovecot/courier, proftpd,
bind9, mariadb) on Debian/Devuan/Ubuntu. It is not an application you can run — it is an
installer plus a control panel plus a backend job runner.

## Source map

- `autoinstaller/` — distro adapters, per-distro package sets, install layout. See `mem:installer/core`.
- `engine/` — Perl backend: libraries, per-service server classes, per-entity job modules, setup scripts. See `mem:engine/core`.
- `gui/` — PHP control panel. See `mem:gui/core`.
- `daemon/` — small C daemon (`imscp_daemon`) that takes requests from the panel and runs backend jobs.
- `configs/<distro>/<codename|default>/` — config templates deployed onto the system. See `mem:installer/core`.
- `contrib/Listeners/` — drop-in event listener files; the supported way to alter behaviour without patching.
- `docs/` — per-release errata, per-distro INSTALL, and `docs/preseed.pl`, the canonical preseed reference.
- `Vagrant/`, `docker/` — dev environments. See `mem:docker/core`.
- `i18n/` — panel translation sources.

## Invariants

- Three languages split by directory: Perl (engine + installer), PHP (gui), C (daemon). See `mem:tech_stack`.
- No automated test suite, linter or formatter anywhere in the tree. Verification is behavioural. See `mem:task_completion`.
- Nothing enforces style, so it is carried by convention only — error-handling idioms, the wrapper
  libraries that must be used instead of raw builtins, and commit message form: `mem:conventions`.
- Never configure by editing a deployed file. Change the template under `configs/`, or add a listener
  under `contrib/Listeners/`, then re-install. Deployed files are overwritten on every install.
- Installed layout is `/var/www/imscp/{gui,engine,daemon}` with config `/etc/imscp/imscp.conf`.
  Read paths (`ROOT_DIR`, `GUI_ROOT_DIR`, `ENGINE_ROOT_DIR`, `PLUGINS_DIR`, `CONF_DIR`) from that
  file rather than hardcoding them.
- Which implementation of each service is active (`HTTPD_SERVER`, `MTA_SERVER`, `PO_SERVER`, …) is a
  value in `imscp.conf`, chosen at install time from the distro package file.
- Plugins are separate repositories, not part of this tree. See `mem:plugins/core`.
- Upstream is i-MSCP/imscp; this fork carries the Debian 11/12/13 and PHP 8.x work. See `mem:suggested_commands`
  for the branch layout and the `gh` remote trap.
