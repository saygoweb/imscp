# Commands

## Install / reinstall — the project's real build step

    perl ./imscp-autoinstall --debug --verbose                              # interactive (dialog)
    perl ./imscp-autoinstall --debug --verbose --noprompt --preseed <file>  # unattended

Reconfigure an already-installed system:

    perl /var/www/imscp/engine/setup/imscp-reconfigure --debug --verbose [--reconfigure <item>]

`--reconfigure` takes an item name such as `local_server`, `primary_ip`, `hostnames`, `all`;
the accepted values appear in the `grep` lists inside each `dialogFor*` sub.

Logs land in `/var/log/imscp/imscp-autoinstall.log`.

## Daemon

    cd daemon && make clean imscp_daemon

Object files and the binary are gitignored; the installer builds in place, as root, so they end
up root-owned in a checkout.

## Dev environments

    docker/imscp <cmd>              # container dev server — see `mem:docker/core`
    cd Vagrant && vagrant up <box>  # VM alternative; boxes listed in Vagrant/README.md

## git / gh

- `origin` = saygoweb/imscp (the fork you work in). `upstream` = i-MSCP/imscp.
- **`gh` resolves to `upstream` by default.** Every `gh pr` / `gh repo` call needs
  `--repo saygoweb/imscp`, otherwise it fails confusingly with
  `No commits between … / Head ref must be a branch`.
- Long-lived branches: `main` and `1.5.3-maintenance-sgw`. As of 2026-09 the maintenance branch is
  an *ancestor* of `main`, so a branch cut from `main` shows ~17 unrelated commits if you target the
  maintenance branch. Run `git merge-base` and pick the base your branch actually descends from.
- Work branch prefixes in use: `feature/`, `fix/`, `chore/`, `pr/`, `migrate/`.
