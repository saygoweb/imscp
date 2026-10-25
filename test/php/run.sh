#!/bin/sh
# Runs the GUI unit tests in the composer image, whose PHP has the extensions
# PHPUnit needs (dom, mbstring), whatever the host has.
#
#   test/php/run.sh [phpunit arguments]
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)

exec docker run --rm \
    -u "$(id -u):$(id -g)" \
    -e COMPOSER_HOME=/tmp/composer \
    -v "$root:/src" \
    -w /src/test/php \
    composer:2.8 \
    sh -c 'composer install --no-interaction --no-progress --quiet && vendor/bin/phpunit "$@"' sh "$@"
