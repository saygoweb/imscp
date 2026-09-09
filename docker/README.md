# i-MSCP development server in Docker

A complete i-MSCP server — nginx, apache2, php-fpm, postfix, dovecot, proftpd,
bind9, MariaDB and the i-MSCP daemon, all under systemd — running in one
container, installed from *this* checkout and then linked back to it, so that
editing `gui/` or `engine/` on the host changes what the running server does.

It is the same thing the `../Vagrant` boxes give you, minus the virtual machine:
same preseeded unattended install, same distribution packages, roughly a tenth
of the disk and a much faster boot.

```shell
docker/imscp init          # pick host ports that are free on this machine
docker/imscp up --build    # build, boot, install i-MSCP  (20-40 min first time)
docker/imscp info          # where it is and how to log in
```

Then open the control panel at the URL `info` prints and log in with the
credentials it prints. Run `docker/imscp help` for everything else.

## Requirements

- Docker Engine with the `compose` plugin (v2).
- A cgroup v2 host — every current Linux distribution. Check with
  `stat -fc %T /sys/fs/cgroup`; it should say `cgroup2fs`.
- About 4 GB of disk for the installed image, and an hour of patience the first
  time.

The container runs privileged. It has to: systemd needs a writable cgroup tree,
the traffic logger installs iptables rules, and i-MSCP bind-mounts customer web
directories. This is a development tool for your own machine, not something to
expose.

## How the development tree is wired up

This checkout is bind-mounted at `/var/www/imscp-git`, and the installer is run
straight out of it — so what gets installed is exactly what you have committed
and uncommitted. Afterwards `docker/imscp link` (which `up` runs for you)
replaces the installed code with symlinks back to it:

```
/var/www/imscp/engine             -> /var/www/imscp-git/engine
/var/www/imscp/gui                -> /var/www/imscp-git/gui
/var/www/imscp/gui/plugins/<Name> -> /var/www/imscp-plugins/<checkout>
```

Editing `gui/` on the host changes what the panel serves on the next request.

### Generated files land in your checkout

`link` also moves what the installer produced — `gui/vendor/`, `gui/library/`,
`gui/bin/composer.phar`, the tool links under `gui/public/tools/`, and the state
under `gui/data/` — into the checkout, beside the source.

That is not tidiness; it is required. `gui/include/imscp-lib.php` reaches its
autoloader with

```php
include __DIR__ . '/../vendor/autoload.php';
```

and PHP's `__DIR__` is always the *resolved* path. Link only the source
directories and leave `vendor/` in the installation, and `__DIR__` becomes
`/var/www/imscp-git/gui/include`, so the panel looks for the autoloader inside
the checkout and dies with `Class 'iMSCP\Application' not found`. Source and
generated content have to sit in the same tree, because the code reaches from
one to the other by relative path — which is also why `gui/` is one link rather
than a link per entry.

The repository already expects this: `gui/vendor/`, `gui/library/` and
`gui/data/*` were gitignored long before this stack existed, so that a checkout
can be run in place. The docker stack adds ignores for `gui/bin/composer.phar`,
`gui/public/tools/*` and `gui/plugins/*`. `git status` stays clean.

`link` hands all of it back to your uid and opens the modes the panel needs —
read on `vendor/`, write on `data/` — so you can still index `vendor/` in an
editor and still `git clean` the tree.

### open_basedir

The panel's PHP-FPM pool pins `open_basedir` to the installed tree, and PHP
tests resolved paths, so `link` adds `/var/www/imscp-git/` and
`/var/www/imscp-plugins/` to it in `/usr/local/etc/imscp_panel/php-fpm.conf` and
restarts `imscp_panel`. If you reconfigure the frontend by hand and the panel
starts throwing `open_basedir restriction in effect`, run `docker/imscp link`
again.

### Ownership

Nothing chowns through a link: `iMSCP::Rights::setRights` walks with `File::Find`
without `follow` and uses `lchown`, so a recursive permission fix retags the
symlink and stops there.

One thing does write into the checkout as root, by design: the installer builds
the daemon in place (`make clean imscp_daemon` in `daemon/`), so `daemon/*.o`
and `daemon/imscp_daemon` come back owned by root. They are gitignored, but a
`make clean` run from the host will fail on them. `docker/imscp perms` hands the
whole checkout back to you, and is the answer whenever anything else gets
through too.

## Plugins

Plugins are developed in sibling checkouts. The directory holding them — by
default the one this repository sits in — is mounted whole at
`/var/www/imscp-plugins`. Which of those checkouts are actually plugins is a
separate question, answered in `docker/.env`:

```shell
IMSCP_PLUGINS="imscp-php-version imscp-letsencrypt"
```

Each named checkout is linked into `gui/plugins/<Name>`, where `<Name>` is the
name the plugin gives itself in its `makefile.json` — so `../imscp-php-version`
arrives as `/var/www/imscp/gui/plugins/SGW_PhpVersion`, which is what the panel
expects. `docker/imscp plugins` shows what will be linked, and
`docker/imscp link` applies a change to the list.

Those links land in `gui/plugins/` inside your checkout, since `gui/` *is* the
checkout; `.gitignore` covers them. The plugin sources stay outside it, under
`/var/www/imscp-plugins`, so each remains its own repository.

The split between one fixed mount and a list resolved at link time is what makes
that last sentence true. A bind mount per plugin would put the list into the
service definition, and Docker's answer to a changed service definition is to
recreate the container — which here means discarding the installed server and
spending another half hour reinstalling it, because a plugin was added to a
list. With the mount fixed, adding a plugin costs a symlink.

Set `IMSCP_PLUGINS_ROOT` if your plugin checkouts live somewhere other than
beside this one; it is what gets mounted, so keep it as narrow as you can.

Installing and activating a plugin is still done in the panel, under
*System tools → Plugin management*: hit the update/sync action there and the
linked plugins appear, ready to install, exactly as on a real server.

## Everyday use

| | |
|---|---|
| `docker/imscp up` | boot, and install i-MSCP if it isn't yet |
| `docker/imscp up --recreate` | start over from a clean container (discards the installation) |
| `docker/imscp stop` / `start` | stop and start, keeping the installation |
| `docker/imscp destroy` | throw the whole server away |
| `docker/imscp shell` | root shell, in `/var/www/imscp-git` |
| `docker/imscp logs panel` | follow the panel log |
| `docker/imscp logs install` | follow `imscp-autoinstall.log` |
| `docker/imscp journal -u imscp_daemon` | journalctl inside the container |
| `docker/imscp services` | what is running |
| `docker/imscp mysql` | mysql client as root |
| `docker/imscp reconfigure` | `imscp-reconfigure`, unlinking and relinking around it |

Editing `gui/` on the host takes effect on the next request. Editing `engine/`
takes effect on the next backend run; `docker/imscp exec systemctl restart
imscp_daemon` if you want it sooner.

After changing anything the installer generates — a template under `configs/`,
an `install.xml`, the package lists — you need a real install rather than a
reload: `docker/imscp install`.

## Settings

`docker/imscp init` writes `docker/.env` with host ports that are free on your
machine. Everything else that can go in that file is listed, commented, in
`.env.example`: the Debian release (`DEBIAN_SUITE`, `bookworm` or `trixie`), the
server's host name, the panel credentials, the plugin list, and the install-time
choices passed through to `preseed.pl`.

`preseed.pl` here is tracked and needs no editing — unlike `../Vagrant/preseed.pl`
it reads its values from the environment. It differs from a production preseed
in ways a container forces or a development box wants: services listen on
`0.0.0.0` because Docker assigns the address; bind9 is installed but is not made
the local resolver, since Docker owns `/etc/resolv.conf`; SSL is off, because a
self-signed certificate on `localhost:8880` only adds a click-through; and the
optional package sets (AWStats, webmail, rootkit scanners) default to off
because they add minutes to an install you will re-run. The header of the file
explains each choice.

## Ports

The container's ports are published on the host, remapped where the real port is
privileged or likely to be taken:

| Service | In the container | On the host (default) |
|---|---|---|
| Control panel | 8880 / 8443 | `PANEL_HTTP_PORT` 8880 / `PANEL_HTTPS_PORT` 8443 |
| Client web sites | 80 / 443 | `HTTP_PORT` 8080 / `HTTPS_PORT` 8444 |
| FTP | 21 | `FTP_PORT` 2121 |
| FTP passive | 32768-32777 | the same, unchanged |
| SMTP / submission | 25 / 587 | `SMTP_PORT` 2525 / `SUBMISSION_PORT` 5587 |
| IMAP / IMAPS | 143 / 993 | `IMAP_PORT` 1143 / `IMAPS_PORT` 9993 |
| POP3 / POP3S | 110 / 995 | `POP3_PORT` 1110 / `POP3S_PORT` 9995 |
| DNS | 53 | `DNS_PORT` 15353 |

The FTP passive range is the one exception that cannot be remapped: proftpd
tells the client which port to connect to, so host and container have to agree.

Client web sites are name-based, so reaching one through `HTTP_PORT` means
sending the right `Host:` header — either add the name to your `/etc/hosts`
pointing at `127.0.0.1`, or `curl -H 'Host: example.com' http://localhost:8080/`.
The control panel is the default vhost and answers to any name.

## Troubleshooting

**The install fails at "Your distribution is not up to date".** The installer
refuses to run when `apt-get dist-upgrade` still has work to do. `install-imscp.sh`
upgrades first, so this means the upgrade itself failed — look above it in the
output.

**systemd never finishes booting.** Check `stat -fc %T /sys/fs/cgroup` says
`cgroup2fs`, then `docker/imscp logs boot`.

**The panel returns `open_basedir restriction in effect`.** Run
`docker/imscp link`; see the open_basedir note above.

**A port is already in use.** `docker/imscp init --force` re-probes and rewrites
the port block in `docker/.env`, keeping anything else you put there.

**A settings change did not take effect.** Ports, host name and the Debian
release are baked into the container, and `up` deliberately will not recreate an
installed one — that would throw the server away. `docker/imscp up --recreate`
does it, and reinstalls from scratch. The plugin list is the exception: it is
applied by `docker/imscp link` and needs no recreation.

**Several checkouts at once.** Each gets its own container, named after its
directory, as long as each has run `docker/imscp init` so their host ports do
not collide.
