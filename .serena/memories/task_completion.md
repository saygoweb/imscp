# Task Completion

**There is no test suite, linter, formatter or type checker in this repository.** There is no
command to run that proves a change is good. Verification is behavioural and depends on what changed.

| Changed | How it is verified |
|---|---|
| `gui/` (PHP) | Load the affected page in a running panel. With `docker/imscp`, a host edit is live on the next request — no restart. |
| `engine/` (Perl) | `perl -c` the module first (add `-I engine/PerlLib -I engine/PerlVendor`), then exercise the path. Backend jobs run through the daemon: `systemctl restart imscp_daemon` to pick up changed code. |
| `configs/`, any `install.xml`, `autoinstaller/Packages/*.xml`, anything generated at install time | Only a real install proves it: `docker/imscp install`. |
| `daemon/` | `cd daemon && make clean imscp_daemon` |
| Plugins | `cd test/backend && sudo perl all.t` where the plugin ships one. See `mem:plugins/core`. |

Rules that hold regardless:

- A change to the installer or to a config template that has not been through a full install has not
  been tested. Reloading a page proves nothing about it.
- Distro-specific changes must be run on the matching release — set `DEBIAN_SUITE` and rebuild; see
  `mem:docker/core`.
- After an install in a dev container, confirm the panel still logs in, not merely that it returns 200:
  a PHP fatal is served with status 200.
- Check `git status` afterwards. The installer runs as root inside the checkout and can leave
  root-owned build output behind; `docker/imscp perms` fixes it.
