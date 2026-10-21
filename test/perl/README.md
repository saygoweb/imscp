# Engine tests

The design is in `docs/superpowers/specs/2026-10-21-engine-test-suite-design.md`.

```
test/run.sh unit [--cover] [files…]     anywhere, as anyone
test/run.sh integration [files…]        on the throwaway CI image only, as root
docker/ci/engine-test.sh [--link]       boots the CI image and runs the integration tests in it
```

## Unit tests: `unit/<Module-Path>.t`

These run the checkout's engine code with its edges stubbed. They need no root,
no network and no database, and write only under `sandbox()`. Name each file
after the module it tests: `iMSCP::File` → `unit/iMSCP-File-copyFile.t` (one
file per behaviour is fine).

`use iMSCPTest::Stub qw/ :all /` gives you:

| Stub | Replaces |
|---|---|
| `stub_execute( qr/…/ => [ exit, stdout, stderr ], … )` | every imported copy of `execute()` / `executeNoWait()`; an unmatched command fails |
| `stub_db( qr/SQL/ => rows \| count \| sub, … )` | `iMSCP::Database->factory()`; an unmatched statement fails and dies |
| `stub_singleton( Class => $obj )` | what `Class->getInstance()` returns |
| `stub_method( Class, method => sub { … } )` | one sub; load the class first |
| `stub_config( %over )` / `server_config( 'bind', %over )` / `config_path( 'bind/parts' )` | the shipped trixie configuration, falling back to `default` |
| `stub_events( fail => $event )` | the event manager; records what is triggered |
| `sandbox()` / `sandbox_path( '/etc/x' )` | the filesystem: one temp dir per test file |
| `debug_messages()` | what went to `iMSCP::Debug::error` |
| `new_server( $class, %fields )` | an instance without `_init()`; needs `stub_events()` |

Every stub returns a guard: keep it in a lexical (`my $db = stub_db( … );`) for
as long as the stub should last. When the guard goes, the stub is undone.

## Integration tests: `integration/<system>.t`

These run as root on a booted CI image (`/etc/imscp/ci-image` marks it). They
queue panel-shaped rows with `iMSCPTest::Fixture`, run the real request manager
with `iMSCPTest::Engine::run_engine()`, and check the results through the
services. Each file creates its own customer and deletes it again.

## Coverage

`test/run.sh unit --cover` writes `cover_db/html/coverage.html`. Coverage is
reported, not gated. A module is **done** when every public sub, and every
documented error return, has at least one test.

| Module | Status | Tests |
|---|---|---|
| `iMSCP::File` | partial | [unit/iMSCP-File-copyFile.t](unit/iMSCP-File-copyFile.t) |
| `Servers::named::bind` | partial | [unit/Servers-named-bind-subdomain.t](unit/Servers-named-bind-subdomain.t), [integration/named.t](integration/named.t) |

A test that finds a bug goes in as a `TODO` test that cites an issue; the fix
goes in its own pull request, which removes the `TODO`.
