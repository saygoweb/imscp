<?php
/**
 * Drive the panel's plugin manager from the command line.
 *
 * The panel's System tools / Plugin management page is the supported way to
 * install a plugin; CI has no browser, so this calls the same
 * iMSCP\Plugin\PluginManager methods the page calls, and a plugin ends up in
 * exactly the state the page would have left it in.
 *
 * Run as the panel user (it alone may read /etc/imscp/imscp.conf and write the
 * panel's cache), under the PHP the panel itself runs:
 *
 *   sudo -u vu2000 php7.4 plugin-ctl.php sync
 *   sudo -u vu2000 php7.4 plugin-ctl.php install <Name>
 *   sudo -u vu2000 php7.4 plugin-ctl.php status  <Name>
 *
 * `status` prints "<status>\t<error>" and nothing else, for scripts to read.
 * A plugin with a backend part stops at a to* status until the backend has run;
 * ci-attach-plugin.sh runs it and polls this.
 */
if (PHP_SAPI !== 'cli') {
    exit("This script must be run from the command line.\n");
}

require_once '/var/www/imscp/gui/include/imscp-lib.php';

use iMSCP\Registry;

$command = $argv[1] ?? '';
$plugin = $argv[2] ?? '';

if ($command !== 'sync' && $plugin === '') {
    fwrite(STDERR, "Usage: plugin-ctl.php {sync|install <Name>|status <Name>}\n");
    exit(2);
}

/** @var \iMSCP\Plugin\PluginManager $pm */
$pm = Registry::get('pluginManager');

try {
    switch ($command) {
        case 'sync':
            $pm->pluginSyncData();
            echo "plugin list synchronised\n";
            break;
        case 'install':
            $pm->pluginInstall($plugin);
            echo "$plugin: install requested\n";
            break;
        case 'status':
            if (!$pm->pluginIsKnown($plugin)) {
                echo "unknown\t\n";
                break;
            }
            printf("%s\t%s\n", $pm->pluginGetStatus($plugin), $pm->pluginGetError($plugin) ?: '');
            break;
        default:
            fwrite(STDERR, "unknown command: $command\n");
            exit(2);
    }
} catch (Throwable $e) {
    fwrite(STDERR, sprintf("%s failed: %s\n", $command, $e->getMessage()));
    exit(1);
}
