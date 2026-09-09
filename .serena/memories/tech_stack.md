# Tech Stack

- **Perl 5** — `engine/`, `autoinstaller/`, `imscp-autoinstall`. Vendored modules in
  `engine/PerlVendor/`; everything else is installed as distro packages by the installer, never cpan.
- **PHP** — the control panel. `gui/composer.json` pins `php >=7.3 <7.4`. The panel's own PHP version
  is independent of the PHP versions offered to customers (the package file installs 5.6 through 8.5).
- **C** — `daemon/`, plain `make`, no autotools.
- **Composer 2** for the panel. `imscp/composer-installers` drops bundled tools (phpmyadmin, roundcube,
  rainloop, monsta-ftp) into `gui/vendor/{vendor}/{name}`.
- Panel libraries: **Zend Framework 1** (patched at install time via cweagans/composer-patches — patches
  live in `gui/patches/`), Slim 3, phpseclib 2, league/flysystem 1, algo26-matthias/idna-convert.
- **XML** carries installer data, not just config:
  - `autoinstaller/Packages/<distro>-<codename>.xml` — package sets, service alternatives, defaults,
    per-package `post_install_tasks`, third-party repositories.
  - `install.xml` (in `engine/`, its subdirs, and each `configs/.../` dir) — what gets deployed where.
  - `autoinstaller/Layout/Debian.xml` — the install prefix variables.
- **No linter, formatter, type checker, or style config exists** — no phpcs, phpstan, perlcritic,
  editorconfig or equivalent. Match surrounding code by eye.

## Supported distributions

`autoinstaller/Packages/` is authoritative: debian stretch/buster/bullseye/bookworm/trixie,
devuan ascii, ubuntu xenial/bionic. sury.org supplies the PHP packages on Debian.
`configs/debian/` has codename dirs only for bullseye, bookworm and trixie; every other release
falls back to `configs/debian/default/`.
