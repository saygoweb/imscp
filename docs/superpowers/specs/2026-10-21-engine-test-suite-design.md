# Engine test suite — design

Date: 2026-10-21
Status: approved in conversation; awaiting review of this written spec

## Purpose

i-MSCP is maintained here as a fork that keeps changing: bug fixes (#30, #31),
Debian and PHP moves, plugin work. The engine (`engine/PerlLib`, 143 modules,
about 53k lines) has two regression tests and no CI that runs them. This spec
sets up a test suite that lets the engine be changed with confidence, and the
order in which it grows to cover the engine.

Success: every pull request runs the engine's unit tests, and every engine
change runs integration tests against an installed server on the Debian
release production uses (trixie). A regression in any system fails the job.

## Decisions

| Question | Decision |
|---|---|
| Where tests live | Outside the source tree: `test/perl/…` now, `test/php/…` later. Never `engine/t` and the like. |
| Which comes first | The engine. The GUI (`test/php`) is a later, separate effort. |
| Kinds of test | Both. Unit tests carry the detail (edge cases, regressions) and are fast. Integration tests are broad and green-path, with at least one per system, against a real database and real templates. |
| Where integration tests run | Throwaway CI containers only. Never the long-lived development stack. |
| How unit tests reach collaborators | Test the code as it stands, through a shared stub kit. Engine source is not refactored for testability unless a specific case is put to the user and approved. |
| Alternative implementations | Integration tests run only on what the image installs. They assert behaviour, never which implementation is installed, so a matrix of image variants can be added later. Alternatives get unit tests. |
| How integration tests drive the engine | Through the real request pipeline: panel-shaped rows queued, `imscp-rqst-mngr` run, results asserted. |
| Where unit tests run in CI | Inside the published CI image, without booting it, so library versions match production. |
| Debian release | Trixie replaces bookworm as the image built, tested and published. Production is on trixie. |

## Layout

```
test/
  run.sh                       single entry point
  perl/
    README.md                  per-module coverage status
    lib/iMSCPTest/
      Guard.pm                 scope guard behind every stub
      Stub.pm                  unit kit: the one import, `use iMSCPTest::Stub qw/ :all /`
      Stub/{Symbol,Execute,DB,Config,Env}.pm   the kit's parts
      Fixture.pm               integration: panel-shaped rows
      Engine.pm                integration: run the engine, assert statuses
    unit/<Module-Path>.t       e.g. unit/iMSCP-File-copyFile.t
    integration/<system>.t     e.g. integration/named.t
  panel-sweep.sh               existing; unchanged
docker/ci/engine-test.sh       boot the image, run integration tests
```

The two existing tests, `test/perl/iMSCP-File-copyFile.t` and
`test/perl/Servers-named-bind-subdomain.t`, move to `test/perl/unit/`.

## Unit kit: `iMSCPTest::Stub`

Shaped by three facts about the engine:

- `execute()` is imported into each module's namespace by `use iMSCP::Execute`,
  so redefining `iMSCP::Execute::execute` misses the copies. `stub_execute()`
  walks the symbol table and replaces every alias of the real sub. It records
  each call. Responses are `qr/…/ => [ exit, stdout, stderr ]` or `qr/…/ => sub {…}`
  pairs, and a catch-all is `qr/^/ => sub {…}`. A command that matches nothing fails the test, so nothing
  reaches the real shell.
- Singletons (`Common::SingletonClass`, 61 classes) hold their instance in
  `${"Class::_instance"}`. `stub_singleton( Class => $obj )` sets that variable
  and restores the previous value when the scope ends.
- `iMSCP::Database::factory` caches its adapter in a `state` variable, which
  cannot be reset. `stub_db()` redefines `factory` to return a fake adapter whose
  `getRawDb()` is a recording handle. The handle answers `selectrow_*`,
  `selectall_*`, `prepare` and `execute` from `qr/SQL/ => rows` pairs and
  records every statement with its bind values.

Also:

| Helper | Does |
|---|---|
| `stub_config( %over )` | `%main::imscpConfig` from the shipped `configs/debian/<suite>/imscp.conf` (suite `trixie`, falling back to `default`), plus overrides |
| `server_config( 'bind', %over )` | a server's `$self->{'config'}`, from its shipped `configs/debian/<suite>/<server>/<server>.data.dist`, with the same fallback |
| `config_path( 'bind/parts/db.tpl' )` | the shipped template or config file for the suite, with the same fallback |
| `stub_events( fail => $event )` | an `iMSCP::EventManager` stand-in that records `trigger` and returns 0, or 1 for `$event` |
| `sandbox()` / `sandbox_path( $real )` | a temp dir, cleaned up even after a test removed a directory's permissions; real paths mapped into it |
| `new_server( $class, %fields )` | a blessed instance with the fields the caller passes, `config` defaulting to `{}`, and the event stub wired in |
| `debug_messages()` | what went through `iMSCP::Debug::error`, to assert why a call returned 1 |

Every stub is restored when its enclosing scope or the test file ends.

Unit tests need no root, network or database, and write only under
`sandbox()`. A unit test that reaches outside fails; it does not skip.

The kit has its own tests: `test/perl/unit/iMSCPTest-*.t`.

## Integration: `iMSCPTest::Fixture` and `iMSCPTest::Engine`

`iMSCP::DbTasksProcessor` processes all pending rows in a fixed order: adds
first (Plugin, ServerIP, SSL, User, Domain, Subdomain, Alias, SubAlias,
CustomDNS, FtpUser, Mail, Htpasswd, Htgroup, Htaccess), deletes last in reverse.
A test queues a whole scenario, then runs the engine once, as the panel does.

The panel has no reusable function for creating a customer
(`reseller/user_add4.php` does it inline). So the fixtures write the rows the
panel writes:

| Helper | Queues |
|---|---|
| `reseller()` | a reseller under the installer's admin; created once per container, reused |
| `customer( %over )` | `admin` (`admin_type = 'user'`, `admin_status = 'toadd'`) and its `domain` (`domain_status = 'toadd'`) with the panel's props (PHP, CGI, mail and FTP limits) |
| `subdomain`, `alias`, `subalias` | the rows, `toadd` |
| `mail( $dmn, 'normal'\|'forward' )`, `ftp_user`, `custom_dns`, `htaccess`, `sql_db` | the rows, `toadd` |
| `schedule( $obj, 'todelete'\|'tochange'\|'todisable' )` | sets the object's status column |

- Names are `<label>-<pid>.test`, under a TLD that never resolves outside the
  container.
- Each fixture checks its column list against `SHOW COLUMNS` the first time it
  is used, and fails on a mismatch instead of inserting silently.

`iMSCPTest::Engine`:

- `run_engine()` runs the real `engine/imscp-rqst-mngr` as a subprocess and
  fails with its output on a non-zero exit.
- `is_ok( $obj )` fails on any status other than `ok`, and shows it: i-MSCP
  writes the error text there.
- `is_gone( $obj )` asserts that a deleted object's row is gone.

Assertions go through the service where they can. Any file paths come from the
installed server's own config (`$server->{'config'}`), never hard-coded, so
the tests hold for whichever implementation is installed.

| System | Green path |
|---|---|
| named | `dig @127.0.0.1` answers the domain's and the subdomain's A records; after delete, NXDOMAIN and no zone file |
| httpd | an HTTP request with `Host:` to 127.0.0.1 serves the default index; PHP executes |
| mta, po | SMTP to the new mailbox is accepted and the message is read back over IMAP; a forward forwards |
| ftpd | FTP login as the new user; an upload lands in the web directory |
| sqld | the new SQL user connects and creates a table |
| cron | the customer's crontab exists when the plan allows cron |

Clients come from Perl modules already on the image: `Net::DNS`, core
`Net::SMTP` and `Net::FTP`, and a minimal IMAP exchange over `IO::Socket`.

Integration files run one at a time (no `prove -j`), since `run_engine`
processes every pending row in the system. Each file creates its own customer
and ends by deleting it, which also exercises the delete path.

## Runner and CI

### `test/run.sh`

```
test/run.sh unit [--cover] [files…]     anywhere, any user
test/run.sh integration [files…]        CI image only, as root
test/run.sh ci                          the tests of the CI scripts (test/ci)
test/run.sh all                         unit, then integration
```

- Unit tests add `-Iengine/PerlLib -Iengine/PerlVendor -Itest/perl/lib`.
  Integration tests use the installed engine's `PerlLib` and `PerlVendor`
  (`${IMSCP_ENGINE_DIR:-/var/www/imscp/engine}`), which is the checkout only
  under `engine-test.sh --link`. Both add `--timer` and pass `PROVE_ARGS`
  through. Unit tests run with `-j4`; integration tests
  run serially.
- `--cover` runs the unit tests under `Devel::Cover` (`libdevel-cover-perl`).
- `integration` refuses to run unless `/etc/imscp/ci-image` exists.
  `docker/ci/build-image.sh` writes that marker before committing the image.
  The development stack never has it.

### `docker/ci/engine-test.sh`

```
docker/ci/engine-test.sh [--image <ref>] [--link] [--keep] [-- test/run.sh args]
```

- It boots the image with `ci_boot`, mounts the checkout, and runs
  `test/run.sh integration` as root.
- `--link` replaces the installed `engine/` with the checkout's, as
  `docker/imscp link` does, for a quick local loop on engine-only changes.
- `--keep` leaves the container running.
- CI calls this same script. The default image is `:trixie`.

### Workflows

| Workflow | Job | When | Against |
|---|---|---|---|
| `test.yml` (new) | unit | every PR, forks included; every push to main | the PR's checkout mounted into `:trixie`, not booted; HTML coverage report uploaded as an artifact |
| `ci-image.yml` `build` | integration, a step after the smoke test and before push | whenever the image is rebuilt: same-repo PRs touching `engine/`, `configs/`, `gui/`…, main, weekly | the image just built. A build that fails is not pushed, so `:trixie` is never a broken engine. |
| `test.yml` | integration | PRs that change only `test/**` | `:trixie` with `--link` |

Fork PRs get unit tests only, as `ci-image.yml` already builds nothing for
them. A failing weekly rebuild holds `:trixie` at its previous version until
it is fixed.

### Trixie replaces bookworm

- `ci-image.yml` builds with `DEBIAN_SUITE=trixie` and publishes `:trixie` and
  `:trixie-<sha>` from main, `:pr-<n>` for PRs, and `:trixie` weekly.
- The default becomes trixie in `build-image.sh`, `plugin-test.sh`,
  `plugin-test.yml` (the `image` input), `engine-test.sh`,
  `docker/docker-compose.yml` and `docker/imscp`.
- `prune-images.sh` recognises `<suite>-<sha>` for any suite, keeps the newest
  three per suite, and never deletes a bare suite tag. The old `:bookworm` stays
  protected as an unrecognised tag: frozen, not deleted.
- Plugins calling `plugin-test.yml@main` without an `image` move to trixie when
  this merges. Each plugin's CI is run against `:pr-<n>` before the merge.
- `docker/README.md` and the comments in `ci-image.yml` are updated to match.

## Rollout

Each phase gets its own implementation plan. The first plan covers phases 0
and 1.

| Phase | Delivers | Done when |
|---|---|---|
| 0. Trixie CI image | the section above | `:trixie` is published from main; the plugins are green on it |
| 1. Harness | the kit and its self-tests; `run.sh`; `engine-test.sh`; the marker; the unit job; the integration step; the existing tests moved to `unit/` and onto the kit (the bind test reads trixie templates through `config_path`); `integration/named.t` (customer → domain → subdomain → dig → delete) | CI runs both kinds of test on a PR |
| 2. Integration per system | `httpd.t`, `mta-po.t`, `ftpd.t`, `sqld.t`, `cron.t`, and `lifecycle.t` (disable and enable, a `tochange` of PHP settings, alias, subalias, custom DNS, htaccess) | every system in the green-path table has a file |
| 3. Core unit tests | roughly in dependency order: `iMSCP::File`, `Dir`, `TemplateParser`, `Config`, `EventManager`, `Debug`, `Execute` (escaping and exit codes), `Net`, `Crypt`, `OpenSSL`, `Database::*`, `DbTasksProcessor` (order and selection), `Service`, `Provider::Service::Systemd`, `Mount`, `Ext2Attributes` | each module is done (below) |
| 4. Runtime servers and modules | `Servers::named::bind`, `httpd::apache_php_fpm`, `mta::postfix`, `po::dovecot`, `ftpd::proftpd`, `sqld::*` (the mysql and mariadb runtime), `cron::cron`, then each `Modules::*` (`_getData` and its action dispatch) | each module is done |
| 5. The rest | `apache_itk`, `apache_fcgid`, `vsftpd`, `courier`, `percona`, `remote` (unit only), then `Package::*`, `FrontEnd` first | each module is done |

Out of scope:

- Installers, uninstallers and `iMSCP::Dialog`, about 9k lines. Every image
  build runs a full unattended install, and the smoke test checks the result:
  that is their integration test. They get unit tests only when one of their
  bugs is fixed.
- The GUI.

### What "done" means for a module

Every public sub, and every documented error return, has at least one test.
Coverage from `Devel::Cover` is reported but not gated, since a threshold
rewards padding. `test/perl/README.md` lists each module as none, partial or
done, with a link to its test file.

### A test that finds a bug

The failing case goes in as a `TODO` test that cites an issue. The fix goes in
its own PR, which removes the `TODO`, one bug per PR as in #30 and #31. The
exception is a bug that blocks a green path an integration test needs: its fix
lands first.

### Asking before refactoring

If a module cannot be tested sensibly with the stub kit, for example because
its paths come from constants with no config hook, the work stops and the user
is asked. The question proposes the seam it would add.
