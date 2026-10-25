# GUI unit tests

Unit tests for the GUI's pure helper functions: no application boot, database
or session. `bootstrap.php` loads only the include files under test.

    test/php/run.sh

runs them in the `composer:2.8` docker image, which installs PHPUnit into
`test/php/vendor/` on first use. Pass PHPUnit arguments through, for example
`test/php/run.sh --filter getDiskUsageState`.
