# docker/ — containerised dev server

A Debian container running **systemd as PID 1**, into which the preseeded installer builds a whole
i-MSCP server from this checkout, which is then symlinked back so host edits are live.
Driven by `docker/imscp` (the counterpart of `docker/anorm` / `docker/sgw` in sibling repos).
Full prose in `docker/README.md`; this memory records only what is expensive to rediscover.

    docker/imscp init            # write docker/.env with free host ports
    docker/imscp up --build      # build, boot, install (20-40 min first time)
    docker/imscp link            # re-point the installed tree at the checkout
    docker/imscp shell | logs | journal | services | mysql | perms | destroy

## Shape

- One privileged container, no second service: i-MSCP installs and manages its own MariaDB, nginx,
  apache2, postfix, dovecot, proftpd, bind9. Privileged because systemd needs a writable cgroup tree
  and the installer sets up iptables rules and bind mounts.
- The installer runs **inside the running container**, not at image build time — it needs the
  services up in order to configure them. The image holds only the cacheable part.
- State lives in the container's writable layer: `stop`/`start` preserve the installation,
  `destroy` discards it. `up` refuses to recreate an existing container unless given `--recreate`,
  because recreation silently throws away a half-hour install.
- Preseed values are passed per-run with `docker compose exec -e`, never set in `docker-compose.yml`:
  a container's environment is fixed at creation, so baking them in would make an edited
  `docker/.env` silently ineffective.

## How the checkout is wired in

    /var/www/imscp/engine             -> /var/www/imscp-git/engine
    /var/www/imscp/gui                -> /var/www/imscp-git/gui
    /var/www/imscp/gui/plugins/<Name> -> /var/www/imscp-plugins/<checkout>

`gui/` is linked **whole**, and `scripts/link-dev-tree.sh` moves `vendor/`, `library/`,
`bin/composer.phar`, `public/tools/` and `data/` into the checkout beside the source. This is forced,
not stylistic: the panel reaches from source to generated content by relative path and PHP resolves
`__DIR__` through symlinks (see `mem:gui/core`). Linking only the source directories makes the panel
look for the autoloader inside the checkout and die.

- The link step hands the moved files back to the invoking uid and opens the modes the panel needs
  (read on `vendor/`, write on `data/`), so the tree stays readable and `git clean`-able.
- `open_basedir` in the panel pool is patched to include `/var/www/imscp-git/` and
  `/var/www/imscp-plugins/`. Re-run `link` if the panel starts refusing includes.
- `unlink` restores real copies, and runs automatically before an install, because
  `setupInstallFiles()` wipes `gui/`/`engine/` wholesale.

## Plugins

The directory holding the plugin checkouts (default: this repo's parent) is one **fixed** mount at
`/var/www/imscp-plugins`; `IMSCP_PLUGINS` in `docker/.env` selects which of them get linked in, and
the name comes from each plugin's `makefile.json`. A bind mount per plugin would put the list in the
service definition, so changing it would recreate the container and destroy the server.

## Debian-container faults the image works around

Each of these was a failed install; all four fixes are in `docker/Dockerfile` with comments.

| Symptom | Cause |
|---|---|
| `Couldn't copy '/etc/apt/sources.list'` | Debian's Docker images are deb822-only and ship no `sources.list`, which `_processAptRepositories` backs up unconditionally |
| `Can't connect to local server through socket '/run/mysqld/mysqld.sock'` | `/usr/sbin/policy-rc.d` returning 101 leaves every installed service enabled but dead |
| `Sub-process /usr/bin/dpkg returned an error code (1)` on `resolvconf` | its postinst replaces `/etc/resolv.conf` with a symlink, impossible on a file Docker bind-mounts; answered via `resolvconf/linkify-resolvconf=false` plus the `linkified` marker |
| systemd never finishes booting | udev and other units that cannot work in a container must be masked |

Also: host port 5353 is normally taken by mDNS, and a TCP-only probe cannot see a UDP listener —
`docker/imscp init` consults `ss -lntu`.
