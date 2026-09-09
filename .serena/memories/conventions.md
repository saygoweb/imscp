# Conventions

## Perl (engine/, autoinstaller/)

- 4-space indent, no tabs. POD `=item` block above each sub documenting `Param` and `Return`.
- `use iMSCP::Boolean;` supplies `TRUE`/`FALSE`.
- **Two error idioms coexist — match the surrounding file.** Older: return int, `0` = success, and
  call `error()` from `iMSCP::Debug` first. Newer: `eval { … }; if ( $@ ) { error( $@ ); return 1; }`.
- Never use raw filesystem builtins. Go through `iMSCP::File`, `iMSCP::Dir`,
  `iMSCP::Rights::setRights`, `iMSCP::Mount`. Their symlink and ownership behaviour is relied upon
  elsewhere (see `mem:engine/core`).
- Never call `systemctl`/`service` directly — use `iMSCP::Service`, which picks the
  Systemd / SysVinit / Upstart provider for the running system.
- Run commands via `iMSCP::Execute::execute` / `executeNoWait` so they are logged through `iMSCP::Debug`.
- Extension points are events: `iMSCP::EventManager` `trigger` / `register` / `registerOne`, named
  `beforeX` / `afterX`. Prefer adding an event over adding a branch.
- Config is `%::imscpConfig` (from `/etc/imscp/imscp.conf`); preseed/dialog answers are
  `%::questions` via `::setupGetQuestion` / `::setupSetQuestion`.

## PHP (gui/)

- PSR-4: `iMSCP\` → `gui/src/`, `iMSCP\Plugin\` → `gui/plugins/`.
- `gui/src/` is the OO code. `gui/include/*.php` are procedural function libraries pulled in by
  Composer's `files` autoload — that is why they are global functions, not a lapse.
- One script per page under `gui/public/{admin,reseller,client,shared}/`.

## Commit messages

`<area>: <lowercase sentence saying what the change does>` — describe the effect, not the edit:

    courier: three faults that break all mail authentication on Debian 12+
    bind: stop replacing the distribution's named.service, and repair one we did
    iMSCP::File: never install a file through a symlink

Area is a component (`bind`, `postfix`, `courier`, `docker`, `CustomDNS`, `iMSCP::File`) or a
distribution (`Debian 13 (Trixie):`).
