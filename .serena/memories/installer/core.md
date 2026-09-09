# Installer — autoinstaller/ and configs/

## Flow

`imscp-autoinstall` → `autoinstaller::Functions::install()` → `autoinstaller::Adapter::<Distro>Adapter`
(`Debian`, `Devuan`, `Ubuntu`) → `preinstall()`, then the five steps in the adapter's `install()`:

1. `setupInstallFiles` — wipes and re-copies `$ROOT_DIR/{daemon,engine,gui}` (see `mem:engine/core`)
2. `setupBoot`
3. `setupRegisterListeners`
4. `setupDialog`
5. `setupTasks`

Everything is first built under `INST_PREF=/tmp/imscp` (prefix variables in
`autoinstaller/Layout/Debian.xml`), then the whole prefix is rcopied onto `/` and deleted.

`prepareDistFiles()` does `_buildLayout`, `_buildConfigFiles`, `_buildEngineFiles`,
`_buildFrontendFiles`, `_compileDaemon`, `_removeObsoleteFiles`, `_savePersistentData`.
`_compileDaemon` runs `make clean imscp_daemon` **in the source tree**, as root.

## Data files

- `autoinstaller/Packages/<distro>-<codename>.xml` — package sets grouped by service class, with
  `has_alternatives`, `default="1"`, per-`<package>` `post_install_tasks`, and third-party
  repositories (`repository`, `repository_key_uri`, pinning) — sury.org for PHP on Debian.
- `configs/<distro>/<codename>/` overrides `configs/<distro>/default/` per file. Only bullseye,
  bookworm and trixie have codename directories; everything else uses `default` alone.
- `install.xml` declares deployment: `<folders export="NAME">path</folders>` defines a variable,
  `<copy>` copies a path, `mode=` sets permissions. Processed for `engine/`, each of its
  subdirectories, and each directory under the selected config dir.

## Preseeding — the rules that cause silent failures

- `docs/preseed.pl` is the canonical reference for every key and its accepted values.
- **Under `--noprompt`, a dialog the installer cannot skip is a hard error, not a prompt**:
  `iMSCP::Dialog::execute: Invalid configuration or unexpected error`, with the question text dumped
  in the `Context:` block below it. Read that block to see which value was rejected, then read the
  matching `dialogFor*` sub to learn what would have been accepted.
- A blank value means "use the default", which is sometimes the *only* value that works. With
  `BASE_SERVER_IP=0.0.0.0`, `dialogForBaseServerPublicIP()` skips only for a genuinely public
  address, so `BASE_SERVER_PUBLIC_IP` must be left blank to reach the WAN lookup.
- Validated ranges are enforced: the proftpd passive port range must sit inside 32768-60999.
- `DebianAdapter::preinstall` **aborts the install if `apt-get dist-upgrade` still has anything to
  do**. Always fully upgrade first.
- `_updateAptSourceList` prefers deb822 `/etc/apt/sources.list.d/*.sources` when any exist, but
  `_processAptRepositories` still writes third-party repos into `/etc/apt/sources.list` and backs
  that file up first — so the file must exist even on a deb822-only system.

A working unattended preseed, with each container-specific choice explained, is `docker/preseed.pl`;
see `mem:docker/core`.
