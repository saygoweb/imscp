#!/bin/sh
# Point the installed i-MSCP tree at the bind-mounted git checkout.
#
# Runs inside the container, after the installer has finished. Idempotent, so
# `docker/imscp link` can be repeated at will.
#
#   /var/www/imscp/engine            -> /var/www/imscp-git/engine
#   /var/www/imscp/gui               -> /var/www/imscp-git/gui
#   .../gui/plugins/<Name>           -> /var/www/imscp-plugins/<checkout>
#
#
# WHY THE WHOLE OF gui/, AND NOT ITS SOURCE ENTRIES ONE BY ONE
# ------------------------------------------------------------
# Linking only the source entries — src/, include/, themes/ — and leaving the
# generated ones (vendor/, library/, data/) in the installation looks tidier and
# does not work. gui/include/imscp-lib.php reaches its autoloader with
#
#   include __DIR__ . '/../vendor/autoload.php';
#
# and PHP's __DIR__ is always the *resolved* path. Through a link on include/
# alone it becomes /var/www/imscp-git/gui/include, so the panel looks for the
# Composer autoloader at /var/www/imscp-git/gui/vendor — inside the checkout,
# which would not have one — and dies with
#
#   Fatal error: Uncaught Error: Class 'iMSCP\Application' not found
#
# Source and generated content have to sit in the same tree, because the code
# reaches from one to the other by relative path. So the whole of gui/ becomes
# the checkout, and what the installer generated is moved in alongside it by
# _migrate_generated below. The repository's .gitignore already expects this:
# gui/vendor/, gui/library/ and gui/data/* are ignored precisely so that a
# checkout can be run in place.
#
#
# OWNERSHIP
# ---------
# Nothing chowns through a link: iMSCP::Rights::setRights walks with File::Find
# (no `follow`) and uses lchown, so a recursive permission fix retags the link
# and stops there. That also means the panel's own permissions never reach
# gui/data/, which the panel must be able to write to — hence the chmod at the
# end. `docker/imscp perms` hands the checkout back if anything does get
# through.

set -eu

GIT_ROOT="${IMSCP_GIT_ROOT:-/var/www/imscp-git}"
PLUGIN_MOUNT_ROOT="${IMSCP_PLUGIN_MOUNT_ROOT:-/var/www/imscp-plugins}"
IMSCP_CONF="${IMSCP_CONF:-/etc/imscp/imscp.conf}"

# What the installer and Composer produce inside gui/ that the checkout has no
# copy of. Moved into the checkout before gui/ is replaced with the link,
# newest-wins: the tree that has just been installed is the current one.
GENERATED='vendor library bin/composer.phar'

log() { printf '\033[36m==>\033[0m link-dev-tree: %s\n' "$*"; }
warn() { printf '\033[33m==>\033[0m link-dev-tree: %s\n' "$*" >&2; }
die() { printf 'link-dev-tree: %s\n' "$*" >&2; exit 1; }

conf_get() {
    # imscp.conf is "KEY = value", one per line.
    sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$IMSCP_CONF" | head -n 1
}

# Move the generated parts of the freshly installed gui/ into the checkout, so
# that they are still beside the source once gui/ becomes a link to it.
#
# Nothing to do when gui/ is already the link — that is the re-run case, and the
# generated content is where it belongs.
_migrate_generated() {
    [ -d "$GUI_DIR" ] && [ ! -L "$GUI_DIR" ] || return 0

    moved=''
    for rel in $GENERATED; do
        src="$GUI_DIR/$rel"
        dst="$GIT_ROOT/gui/$rel"
        [ -e "$src" ] || continue

        mkdir -p "$(dirname "$dst")"
        rm -rf -- "$dst"
        mv -- "$src" "$dst"
        moved="$moved $rel"
    done

    # public/tools/ holds index.php from the repository plus one link per
    # installed tool, so merge rather than replace.
    if [ -d "$GUI_DIR/public/tools" ]; then
        mkdir -p "$GIT_ROOT/gui/public/tools"
        for path in "$GUI_DIR/public/tools"/*; do
            [ -e "$path" ] || [ -L "$path" ] || continue
            name="$(basename "$path")"
            [ "$name" = 'index.php' ] && continue
            rm -rf -- "$GIT_ROOT/gui/public/tools/$name"
            mv -- "$path" "$GIT_ROOT/gui/public/tools/"
            moved="$moved public/tools/$name"
        done
    fi

    # data/ is the installation's state directory. The checkout has the empty
    # skeleton; merge so that anything real the installer put there — the panel
    # certificate, the persistent Composer home — comes across without wiping
    # the tracked placeholder files.
    if [ -d "$GUI_DIR/data" ]; then
        cp -a "$GUI_DIR/data/." "$GIT_ROOT/gui/data/"
        moved="$moved data"
    fi

    [ -n "$moved" ] && log "moved into the checkout:$moved" || true
}

_link_engine() {
    if [ -L "$ENGINE_DIR" ] && [ "$(readlink "$ENGINE_DIR")" = "$GIT_ROOT/engine" ]; then
        log "engine already linked"
        return 0
    fi

    rm -rf -- "$ENGINE_DIR"
    ln -s "$GIT_ROOT/engine" "$ENGINE_DIR"
    log "engine -> $GIT_ROOT/engine"
}

_link_gui() {
    if [ -L "$GUI_DIR" ] && [ "$(readlink "$GUI_DIR")" = "$GIT_ROOT/gui" ]; then
        log "gui already linked"
        return 0
    fi

    rm -rf -- "$GUI_DIR"
    ln -s "$GIT_ROOT/gui" "$GUI_DIR"
    log "gui -> $GIT_ROOT/gui"
}

# Plugins arrive as "<checkout directory>:<plugin name>" arguments, resolved on
# the host by docker/imscp — the checkout is called imscp-php-version, but the
# panel wants the name the plugin gives itself in makefile.json, SGW_PhpVersion.
#
# These links land inside the checkout, since gui/ now is the checkout;
# .gitignore covers gui/plugins/*. The plugin sources themselves stay outside
# it, under /var/www/imscp-plugins, so that each remains its own repository.
_link_plugins() {
    mkdir -p "$PLUGINS_DIR"

    found=''
    for spec in "$@"; do
        checkout="${spec%%:*}"
        name="${spec##*:}"
        [ -n "$checkout" ] && [ -n "$name" ] || die "malformed plugin spec: $spec"

        path="$PLUGIN_MOUNT_ROOT/$checkout"
        [ -d "$path" ] || die "plugin checkout $path is not mounted"
        found="$found $name"

        dest="$PLUGINS_DIR/$name"
        [ -L "$dest" ] && [ "$(readlink "$dest")" = "$path" ] && continue

        rm -rf -- "$dest"
        ln -s "$path" "$dest"
    done

    # Drop links to plugins that have been taken off the list, so that removing
    # one from IMSCP_PLUGINS actually removes it from the panel.
    for dest in "$PLUGINS_DIR"/*; do
        [ -L "$dest" ] || continue
        case "$(readlink "$dest")" in
            "$PLUGIN_MOUNT_ROOT"/*) ;;
            *) continue ;;
        esac
        case " $found " in
            *" $(basename "$dest") "*) ;;
            *) rm -f -- "$dest" ;;
        esac
    done

    [ -n "$found" ] && log "plugins:$found -> $PLUGIN_MOUNT_ROOT/" \
        || log "no plugins configured"
}

# The panel runs its own PHP-FPM master out of /usr/local/etc/imscp_panel
# (Package::FrontEnd), with open_basedir pinned to the installed tree. PHP tests
# the resolved path, so the checkout has to be named there or nothing the panel
# includes can be read.
_patch_open_basedir() {
    pool='/usr/local/etc/imscp_panel/php-fpm.conf'

    [ -f "$pool" ] || { warn "$pool not found; skipping open_basedir patch"; return 0; }

    if grep -q "$GIT_ROOT/" "$pool"; then
        log "open_basedir already covers the checkout"
        return 0
    fi

    sed -i "s#^\(php_admin_value\[open_basedir\][[:space:]]*=[[:space:]]*\)#\1$GIT_ROOT/:$PLUGIN_MOUNT_ROOT/:#" "$pool"
    grep -q "$GIT_ROOT/" "$pool" \
        || die "could not add $GIT_ROOT to open_basedir in $pool"
    log "open_basedir += $GIT_ROOT/ $PLUGIN_MOUNT_ROOT/"
}

# Everything moved in above was written by the panel's own account, with the
# modes a server wants: vendor/ and library/ arrive as 0750 owned by that uid.
# In the installation that is right; in a checkout it means the developer cannot
# read their own vendor/ — no editor indexing, and `git clean` fails on it.
#
# So hand the migrated paths back to the host user and open the modes to what
# each one actually needs: the panel only ever reads vendor/ and library/, and
# writes sessions, caches, logs and uploads under data/. HOST_UID/HOST_GID come
# from docker/imscp, which knows who invoked it.
_hand_generated_to_host() {
    if [ -z "${HOST_UID:-}" ] || [ -z "${HOST_GID:-}" ]; then
        warn "HOST_UID/HOST_GID not set; leaving generated files as the panel wrote them"
    else
        for rel in $GENERATED public/tools data; do
            [ -e "$GIT_ROOT/gui/$rel" ] || continue
            chown -R "$HOST_UID:$HOST_GID" "$GIT_ROOT/gui/$rel"
        done
        log "generated files handed to $HOST_UID:$HOST_GID"
    fi

    for rel in $GENERATED public/tools; do
        [ -e "$GIT_ROOT/gui/$rel" ] && chmod -R a+rX "$GIT_ROOT/gui/$rel"
    done
    chmod -R a+rwX "$GIT_ROOT/gui/data"
    log "gui/data made writable by the panel"
}

[ -f "$IMSCP_CONF" ] || die "$IMSCP_CONF not found — i-MSCP is not installed yet"

ROOT_DIR="$(conf_get ROOT_DIR)"
GUI_DIR="$(conf_get GUI_ROOT_DIR)"
ENGINE_DIR="$(conf_get ENGINE_ROOT_DIR)"
PLUGINS_DIR="$(conf_get PLUGINS_DIR)"
[ -n "$ROOT_DIR" ] && [ -n "$GUI_DIR" ] && [ -n "$ENGINE_DIR" ] && [ -n "$PLUGINS_DIR" ] \
    || die "could not read the installation paths out of $IMSCP_CONF"

_migrate_generated
_link_engine
_link_gui
_link_plugins "$@"
_patch_open_basedir
_hand_generated_to_host

# The panel caches compiled templates and Composer's autoloader map keyed by
# path; both go stale the moment the paths behind them change.
rm -rf -- "$GIT_ROOT/gui/data/cache"/* 2>/dev/null || true

systemctl is-active --quiet imscp_panel && systemctl restart imscp_panel || true

log "done"
