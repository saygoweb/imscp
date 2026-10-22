<?php
/**
 * i-MSCP - internet Multi Server Control Panel
 * Copyright (C) 2010-2019 by Laurent Declercq <l.declercq@nuxwin.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

declare(strict_types=1);

namespace iMSCP;

/**
 * Version and build of the Git checkout the panel runs from
 *
 * A server updated by `git pull` runs the panel straight from its checkout, so
 * the version the installer recorded in imscp.conf goes stale with every pull.
 * This reads it from Git instead.
 *
 * Git itself finds the checkout: under the panel's open_basedir PHP can't even
 * see the .git directory, which sits above gui/.
 *
 * @package iMSCP
 */
class GitVersion
{
    /**
     * Get the nearest version tag and the short SHA of HEAD
     *
     * @param string $dir A directory inside the checkout
     * @return array|null [version, build], or NULL if $dir isn't in a Git
     *                    checkout, Git isn't available or there's no version tag
     */
    public static function get(string $dir): ?array
    {
        $process = @proc_open(
            [
                'git',
                // The checkout is owned by another user than the panel's
                '-c', 'safe.directory=*',
                '-C', $dir,
                'describe', '--tags', '--long', '--match', '[0-9]*'
            ],
            [1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
            $pipes,
            NULL,
            // PHP-FPM clears the environment
            ['PATH' => '/usr/local/bin:/usr/bin:/bin', 'LC_ALL' => 'C']
        );

        if (!is_resource($process)) {
            return NULL;
        }

        $output = stream_get_contents($pipes[1]);
        fclose($pipes[1]);
        fclose($pipes[2]);

        if (proc_close($process) !== 0) {
            return NULL;
        }

        return self::parse($output);
    }

    /**
     * Parse `git describe --long` output: <tag>-<commits since>-g<short SHA>
     *
     * @param string $describe
     * @return array|null [version, build], or NULL if it can't be parsed
     */
    public static function parse(string $describe): ?array
    {
        if (!preg_match('/^(.+)-\d+-g([0-9a-f]+)$/', trim($describe), $matches)) {
            return NULL;
        }

        return [$matches[1], $matches[2]];
    }
}
