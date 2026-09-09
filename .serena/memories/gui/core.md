# gui/ — PHP control panel

## Runtime shape (non-obvious)

- The panel is served by **nginx**, not apache2 (`FRONTEND_SERVER=nginx`). Template:
  `configs/debian/default/frontend/00_master.nginx`. The panel vhost is declared `default_server`,
  so it answers on any Host header — handy for reaching it as `localhost`.
- The panel runs under **its own PHP-FPM master**, `imscp_panel.service`, with config at
  `/usr/local/etc/imscp_panel/php-fpm.conf` (template `configs/debian/default/frontend/php-fpm.conf`).
  This is *not* the distribution php-fpm; restarting `phpX.Y-fpm` does nothing for the panel.
- That pool pins `php_admin_value[open_basedir]` to the installed gui tree. PHP tests **resolved**
  paths, so anything the panel must read has to be inside that tree or explicitly named in the pool.
- Customer sites are served by apache2 with per-site PHP-FPM pools — a separate mechanism entirely.

## Bootstrap

`gui/public/*.php` → `gui/include/imscp-lib.php`, which does

    include __DIR__ . '/../vendor/autoload.php';
    new iMSCP\Application( $autoloader, APPLICATION_ENV );

`__DIR__` is the **resolved** path. Source and `gui/vendor/` therefore have to live in the same tree;
linking part of `gui/` somewhere else makes the panel hunt for the autoloader beside the source and
die with `Class 'iMSCP\Application' not found`. This constrains how a checkout can be wired into an
installation — see `mem:docker/core`.

## Source vs generated

Committed: `src/` (OO code), `include/` (procedural libraries, loaded by Composer `files` autoload),
`public/` (one script per page), `themes/`, `i18n/`, `resources/`, `patches/`, `composer-packages/`,
`composer.json`, `composer.lock`.

Generated into `gui/` at install time: `vendor/`, `library/`, `bin/composer.phar`,
`public/tools/<tool>` (links into `vendor/`), and `data/**` (cache, sessions, logs, tmp, uploads,
certs, persistent). `.gitignore` covers these because a checkout is meant to be runnable in place.

- `gui/data/persistent/` is preserved across installs by `_savePersistentData()`; the rest of `data/`
  is disposable. Uploaded ISP logos go to `data/persistent/ispLogos`, never to `themes/`.
- Compiled `.mo` translations are **committed** under `gui/i18n/locales/`; nothing compiles them at
  install time.
- Composer runs during install as the panel user with
  `COMPOSER_HOME=<GUI_ROOT_DIR>/data/persistent/.composer`.

Plugin API and layout: `mem:plugins/core`.
