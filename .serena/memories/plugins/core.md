# Plugin development

Plugins are **separate repositories**, checked out beside this one: `../imscp-php-version`,
`../imscp-letsencrypt`, `../imscp-apache-cache`, `../imscp-dns-external`, `../imscp-postfix-auth`,
`../imscp-graphql`, `../imscp-trixie-fixes`.

## Layout of a plugin checkout

    <Name>.php            entry class, extends iMSCP\Plugin\AbstractPlugin
    info.php              version/author metadata shown in the panel
    config.php            default configuration
    backend/<Name>.pm     Perl backend half
    frontend/             panel pages
    l10n/  themes/  sql/  tools/  test/
    makefile.json         build metadata

- **`makefile.json` `variables.name` is the installed directory name** (`SGW_PhpVersion`), which is
  not the checkout name (`imscp-php-version`). Anything wiring a checkout into an installation must
  read it from there.
- Installed at `PLUGINS_DIR` = `/var/www/imscp/gui/plugins/<Name>`; PSR-4 `iMSCP\Plugin\` maps there.
- `iMSCP::Plugins` globs `$PLUGINS_DIR/*/backend/*.pm` and loads a backend **only when the plugin
  directory name equals the `.pm` basename** — `<Name>/backend/<Name>.pm` exactly.
- The backend half is executed by the daemon through `Modules::Plugin`.

## AbstractPlugin lifecycle (`gui/src/Plugin/AbstractPlugin.php`)

`install`, `uninstall`, `update`, `enable`, `disable`, `delete`; plus `register` (event listeners),
`getRoutes`, `getServiceProvider`, `migrateDb`, `changeItemStatus`, `getItemWithErrorStatus`,
`getCountRequests`, and the `getConfig*` / `getInfo*` accessors.

## Working with them

- The panel discovers plugins from the directory. `admin/settings_plugins.php?sync=1` rescans and
  inserts rows into the `plugin` table; a newly discovered plugin starts as `uninstalled` and is then
  installed/enabled from *System tools → Plugin management*.
- To develop against a live server, use the container: `IMSCP_PLUGINS` in `docker/.env` links sibling
  checkouts into the panel without a reinstall. See `mem:docker/core`.
- Backend tests, where a plugin ships them: `cd test/backend && sudo perl all.t`
  (the `test` target in `makefile.json`).
- Release packaging: the `package` target tars the checkout as `<Name>.tgz` with the paths rewritten
  to `<Name>/`, honouring `upload-exclude.txt`.
