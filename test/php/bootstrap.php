<?php
// Unit tests load only the GUI's helper files: no application boot, database
// or session. tr() normally lives in gui/include/Intl.php, which needs the
// translator; without one it only substitutes its arguments, which is what
// this stand-in does.

if (!function_exists('tr')) {
    function tr($messageId, $substitution = NULL)
    {
        if ($substitution === NULL) {
            return $messageId;
        }

        $argv = func_get_args();
        unset($argv[0]);
        return vsprintf($messageId, $argv);
    }
}

require __DIR__ . '/../../gui/include/Shared.php';
require __DIR__ . '/../../gui/include/Statistics.php';

date_default_timezone_set('UTC');
