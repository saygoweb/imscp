# imscp/phpmyadmin (in-tree)

The i-MSCP glue for the PhpMyAdmin SQL administration tool, carried in-tree
and wired into `gui/composer.json` as a `path` repository.

## Why this exists

It was published as `imscp/phpmyadmin` from the i-MSCP/phpmyadmin repository,
which is gone. Packagist still lists its releases, so Composer resolves them and
then fails to download them (HTTP 404 on the dist, authentication failure on
the clone), and the whole install stops in `iMSCP::Composer`.

The package itself never contained PhpMyAdmin. It is three files, used by
`Package::SqlAdminTools::PhpMyAdmin`:

- **`src/Handler.pm`** — the package handler, copied into the engine at
  preinstall: builds `config.inc.php`, points PhpMyAdmin's temporary directory
  at the panel's one, creates the `<imscp>_pma` configuration storage database
  and its control user, installs the nginx snippet and links
  `public/tools/phpmyadmin`.
- **`src/config.inc.php`** — the PhpMyAdmin configuration template.
- **`src/nginx.conf`** — the `/phpmyadmin/` location for the panel vhost.

## What changed from 1.0.5

The version is `2.0.0`, so that it sorts above every release Packagist still
advertises.

- PhpMyAdmin 4.9 is replaced by **5.2.3**, whose bundled dependencies require
  PHP >= 7.2.5, so it runs on the panel's PHP 7.4.
- PhpMyAdmin is installed from the official release archive
  (files.phpmyadmin.net), declared as a `package` repository in
  `gui/composer.json`, rather than from Packagist. The Packagist package
  declares an autoload file under its own `vendor/`, which does not exist once
  it is a dependency, and that breaks the panel's autoloader. The release
  archive carries its own `vendor/`, so PhpMyAdmin keeps its dependencies to
  itself. Update both version strings together.
- The handler rewrites the 5.x `libraries/vendor_config.php` (an array, not
  `define()` calls), and fails if a setting cannot be found.
- The nginx snippet also denies PhpMyAdmin's internal directories.
