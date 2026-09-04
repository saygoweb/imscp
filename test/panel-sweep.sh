#!/bin/sh
# Render every significant panel page as each account type and fail on any
# error page, fatal or deprecation. This is the regression test for a PHP
# version change: it is what catches a deprecation that the panel's exception
# handler turns into a fatal error page.
#
# Run inside the box:  sudo test/panel-sweep.sh [php-binary]
set -e

PHP=${1:-php7.4}
GUI=/var/www/imscp/gui
PORT=8099
LOG=/tmp/panel-sweep.log
FAILED=0
SRV=

[ "$(id -u)" -eq 0 ] || { echo "$0: must be run as root" >&2; exit 1; }

# The panel's own cache directory is borrowed for the sweep, so remember how
# it was owned in order to hand it back unchanged.
CACHE_OWNER=$(stat -c '%u:%g' "$GUI/data/cache" 2>/dev/null || echo '0:0')
CACHE_MODE=$(stat -c '%a' "$GUI/data/cache" 2>/dev/null || echo 750)

# A test-only entry point that adopts an existing identity, so the sweep does
# not need anybody's password. Removed again at the end.
cat > "$GUI/public/_sweep_login.php" <<'PHP'
<?php
require_once 'imscp-lib.php';
use iMSCP\Authentication\AuthService;
$type = isset($_GET['as']) ? $_GET['as'] : 'admin';
$i = exec_query(
    'SELECT admin_id, admin_name, admin_pass, admin_type, email, created_by
     FROM admin WHERE admin_type = ? ORDER BY admin_id LIMIT 1',
    [$type]
)->fetchRow(PDO::FETCH_OBJ);
if (!$i) { http_response_code(500); die("no $type in database"); }
AuthService::getInstance()->setIdentity($i);
$g = exec_query('SELECT lang, layout FROM user_gui_props WHERE user_id = ?', [$i->admin_id])
    ->fetchRow(PDO::FETCH_ASSOC);
$_SESSION['user_def_lang']    = isset($g['lang']) ? $g['lang'] : 'en_GB';
$_SESSION['user_theme']       = isset($g['layout']) ? $g['layout'] : 'default';
$_SESSION['user_theme_color'] = 'black';
echo "SESSION OK {$i->admin_name}";
PHP

cat > /tmp/sweep-router.php <<'PHP'
<?php
$p = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$f = '/var/www/imscp/gui/public' . $p;
if ($p !== '/' && file_exists($f) && !is_dir($f)) {
    if (substr($f, -4) === '.php') { require $f; return true; }
    return false;
}
require '/var/www/imscp/gui/public/' . ($p === '/' ? 'index.php' : 'plugins.php');
return true;
PHP

cleanup() {
    [ -n "$SRV" ] && kill "$SRV" 2>/dev/null || true
    rm -f "$GUI/public/_sweep_login.php" /tmp/sweep-router.php /tmp/sweep-ck.*
    # Hand the cache directory back as it was found, emptied so that the live
    # panel rebuilds it under its own ownership.
    rm -rf "$GUI/data/cache"
    mkdir -p "$GUI/data/cache"
    chown "$CACHE_OWNER" "$GUI/data/cache"
    chmod "$CACHE_MODE" "$GUI/data/cache"
    mysql -e "DELETE FROM imscp.login WHERE ipaddr = '127.0.0.1';" 2>/dev/null || true
}
trap cleanup EXIT
# A signal must still reach the EXIT trap, so turn each one into an exit.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

rm -rf "$GUI/data/cache"; mkdir -p "$GUI/data/cache"; chmod 777 "$GUI/data/cache"

$PHP -d error_reporting=E_ALL -d display_errors=1 \
     -d include_path=".:$GUI/library:/usr/share/php" \
     -S 127.0.0.1:$PORT -t "$GUI/public" /tmp/sweep-router.php > "$LOG" 2>&1 &
SRV=$!
sleep 3

sweep() {
    role=$1; shift
    ck=/tmp/sweep-ck.$role
    curl -sf -c "$ck" "http://127.0.0.1:$PORT/_sweep_login.php?as=$role" >/dev/null \
        || { echo "  FAIL  could not establish a $role session"; FAILED=1; return; }
    for p in "$@"; do
        title=$(curl -s -b "$ck" -c "$ck" "http://127.0.0.1:$PORT/$p" \
                | grep -oE '<title>[^<]*</title>' | head -1 | sed 's/<[^>]*>//g')
        case "$title" in
            *"Fatal Error"*|"") echo "  FAIL  $role $p"; FAILED=1 ;;
            *)                  echo "  ok    $role $p" ;;
        esac
    done
}

echo "Panel sweep under $($PHP -r 'echo PHP_VERSION;')"
sweep admin admin/index.php admin/users.php admin/settings.php \
             admin/system_info.php admin/ip_manage.php
sweep reseller reseller/index.php reseller/users.php reseller/user_add1.php \
                reseller/hosting_plan.php
sweep user client/index.php client/domains_manage.php client/subdomain_add.php \
            client/alias_add.php client/mail_accounts.php client/mail_add.php \
            client/sql_manage.php client/sql_database_add.php \
            client/ftp_accounts.php client/ftp_add.php client/profile.php

echo
echo "Deprecations and warnings:"
if grep -aoE "(Deprecated|Warning|Fatal error):.{0,110}" "$LOG" | sort -u | grep .; then
    FAILED=1
else
    echo "  none"
fi

[ "$FAILED" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$FAILED"
