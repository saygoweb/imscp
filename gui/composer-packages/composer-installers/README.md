# imscp/composer-installers (vendored, Composer 2 compatible)

This is a local copy of [i-MSCP/composer-installers][upstream], carried in-tree
and wired into `gui/composer.json` as a `path` repository.

## Why this exists

Packagist shut down its Composer 1 API on 2025-09-01. i-MSCP pinned
`COMPOSER_VERSION = 1.9.0`, so the frontend dependency install started failing
with every `imscp/*` package reported as "could not be found in any version".

Moving to Composer 2 is the fix, but it could not be done on its own: upstream
`imscp/composer-installers` has exactly one published release (1.0.0) and it
requires `composer-plugin-api: ^1.1`. Composer 2 provides plugin-api 2.x, so
that constraint can never be satisfied, and every `imscp/*` package depends on
this plugin. Resolution therefore failed no matter which Composer 2 release was
pinned.

Since upstream is unmaintained, the plugin is vendored here with the minimum
changes needed to run under Composer 2. The version is `1.0.1` so it satisfies
the `^1.0` constraints the `imscp/*` packages declare while sorting above the
unusable 1.0.0 on Packagist, rather than depending on repository precedence.

## What was changed

Only three things differ from upstream; the other source files are verbatim.

- **`composer.json`** — `composer-plugin-api` widened to `^1.1 || ^2.0`, an
  explicit `version` added (path repositories have no VCS tags to infer one
  from), and `require-dev`/`scripts` dropped as irrelevant to a vendored copy.
- **`src/Plugin.php`** — added `deactivate()` and `uninstall()`. Composer 2
  added both to `PluginInterface` and they are not optional; without them PHP
  fatals when the class is loaded.
- **`src/Installer.php`** — `uninstall()` now defers its report onto the
  promise Composer 2 returns. Composer 1 deleted synchronously, so the original
  could call `file_exists()` immediately; under Composer 2 that check would run
  before the deletion completed and always report "not deleted".

## Known upstream issue, left as-is

`AbstractInstaller::mapCustomInstallPaths()` declares a `string` return type but
returns `false` when no custom path matches. Without `strict_types` that coerces
to `""`, and the caller's `!== false` test then treats it as a real path. It is
unreachable in practice — every package that reaches it is listed under
`extra.installer-paths` in `gui/composer.json` — so it is left untouched rather
than changing behaviour beyond the Composer 2 port.

[upstream]: https://github.com/i-MSCP/composer-installers
