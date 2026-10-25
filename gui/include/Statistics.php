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

/** @noinspection
 * PhpUnusedParameterInspection
 * PhpUnhandledExceptionInspection
 * PhpDocMissingThrowsInspection
 */

/**
 * Return usage in percent
 *
 * @param int $usage Current value
 * @param int $usageMax (0 = unlimited)
 * @return int Usage in percent or infinity mathematical symbol if $usageMax
 *             lower than 1
 */
function getPercentUsage($usage, $usageMax)
{
    return sprintf(
        '%.2f',
        min(
            [
                100,
                $usageMax > 0
                    ? round($usage / $usageMax * 100, PHP_ROUND_HALF_ODD)
                    : 0
            ]
        )
    );
}

/**
 * Get monthly traffic data for the given customer
 *
 * @param int $domainId Customer main domain ID
 * @return array An array container Web, FTP, SMTP, POP and total traffic for
 *              the current month
 */
function getClientMonthlyTrafficStats($domainId)
{
    $stmt = exec_query(
        '
          SELECT IFNULL(SUM(dtraff_web), 0) AS dtraff_web,
            IFNULL(SUM(dtraff_ftp), 0) AS dtraff_ftp,
            IFNULL(SUM(dtraff_mail), 0) AS dtraff_mail,
            IFNULL(SUM(dtraff_pop), 0) AS dtraff_pop
          FROM domain_traffic
          WHERE dtraff_time BETWEEN ? AND ?
          AND domain_id = ?
        ',
        [getFirstDayOfMonth(), getLastDayOfMonth(), $domainId]
    );

    if (!$stmt->rowCount()) {
        return array_fill(0, 5, 0);
    }

    $row = $stmt->fetchRow();

    return [
        $row['dtraff_web'],
        $row['dtraff_ftp'],
        $row['dtraff_mail'],
        $row['dtraff_pop'],
        $row['dtraff_web'] + $row['dtraff_ftp'] + $row['dtraff_mail']
        + $row['dtraff_pop']
    ];
}

/**
 * Get statistiques for the given client
 *
 * @param int $clientId User unique identifier
 * @return array
 */
function getClientTrafficAndDiskStats($clientId)
{
    $stmt = exec_query(
        '
            SELECT domain_id, IFNULL(domain_disk_usage, 0) AS disk_usage
            FROM domain
            WHERE domain_admin_id = ?
        ',
        [$clientId]
    );

    if (!$stmt->rowCount()) {
        showBadRequestErrorPage();
    }

    $row = $stmt->fetchRow();

    list(
        $webTraffic, $ftpTraffic, $smtpTraffic, $popTraffic, $totalTraffic
        ) = getClientMonthlyTrafficStats($row['domain_id']);

    return [
        $webTraffic, $ftpTraffic, $smtpTraffic, $popTraffic, $totalTraffic,
        $row['disk_usage']
    ];
}

/**
 * Get counts of consumed and max items for the given customer
 *
 * Note: For disk and traffic, only limit are returned.
 *
 * @param int $clientId Client unique identifier
 * @return array
 */
function getClientItemCountsAndLimits($clientId)
{
    $stmt = exec_query(
        '
            SELECT domain_id, domain_subd_limit, domain_alias_limit,
                domain_mailacc_limit, domain_ftpacc_limit, domain_sqld_limit,
                domain_sqlu_limit, domain_traffic_limit, domain_disk_limit
            FROM domain
            WHERE domain_admin_id = ?
        ',
        [$clientId]
    );

    if (!$stmt->rowCount()) {
        return array_fill(0, 14, 0);
    }

    $row = $stmt->fetchRow(PDO::FETCH_ASSOC);

    return [
        $row['domain_subd_limit'] == -1
            ? 0 : get_customer_subdomains_count($row['domain_id']),
        $row['domain_subd_limit'],
        $row['domain_alias_limit'] == -1
            ? 0 : get_customer_domain_aliases_count($row['domain_id']),
        $row['domain_alias_limit'],
        $row['domain_mailacc_limit'] == -1
            ? 0 : get_customer_mail_accounts_count($row['domain_id']),
        $row['domain_mailacc_limit'],
        $row['domain_ftpacc_limit'] == -1
            ? 0 : get_customer_ftp_users_count($clientId),
        $row['domain_ftpacc_limit'],
        $row['domain_sqld_limit'] == -1
            ? 0 : get_customer_sql_databases_count($row['domain_id']),
        $row['domain_sqld_limit'],
        $row['domain_sqlu_limit'] == -1
            ? 0 : get_customer_sql_users_count($row['domain_id']),
        $row['domain_sqlu_limit'],
        $row['domain_traffic_limit'] * 1048576,
        $row['domain_disk_limit'] * 1048576
    ];
}

/**
 * Returns statistics about consumed items for the given reseller
 *
 * @param int $resellerId Reseller unique identifier
 * @return array An array containing total consumed for each items
 */
function getResellerStats($resellerId)
{
    $stmt = exec_query(
        '
            SELECT t1.domain_id, t1.domain_admin_id
            FROM domain AS t1
            JOIN admin AS t2 ON(t2.admin_id = t1.domain_admin_id)
            WHERE t2.created_by = ?
        ',
        [$resellerId]
    );

    if (!$stmt->rowCount()) {
        return array_fill(0, 9, 0);
    }

    $rtraffConsumed = $rdiskConsumed = 0;

    while ($row = $stmt->fetchRow(PDO::FETCH_ASSOC)) {
        $customerStats = getClientTrafficAndDiskStats($row['domain_admin_id']);
        $rtraffConsumed += $customerStats[4];
        $rdiskConsumed += $customerStats[5];
    }

    return [
        get_reseller_domains_count($resellerId),
        get_reseller_subdomains_count($resellerId),
        get_reseller_domain_aliases_count($resellerId),
        get_reseller_mail_accounts_count($resellerId),
        get_reseller_ftp_users_count($resellerId),
        get_reseller_sql_databases_count($resellerId),
        get_reseller_sql_users_count($resellerId),
        $rtraffConsumed,
        $rdiskConsumed
    ];
}

/**
 * Disk usage at or above this percentage of the limit is reported as approaching it
 */
define('DISK_USAGE_APPROACHING_PERCENT', 80);

/**
 * Grade disk usage against a disk limit
 *
 * The disk limit is informational: nothing is enforced. Usage above the
 * limit is over it; at or above DISK_USAGE_APPROACHING_PERCENT it is
 * approaching it.
 *
 * @param int|float $usageBytes Disk usage in bytes
 * @param int|float $limitBytes Disk limit in bytes (0 = unlimited)
 * @return array ['state' => 'ok'|'approaching'|'over', 'percent' => int]
 */
function getDiskUsageState($usageBytes, $limitBytes)
{
    if ($limitBytes <= 0) {
        return ['state' => 'ok', 'percent' => 0];
    }

    $percent = (int)floor($usageBytes / $limitBytes * 100);

    if ($usageBytes > $limitBytes) {
        $state = 'over';
    } elseif ($usageBytes * 100 >= $limitBytes * DISK_USAGE_APPROACHING_PERCENT) {
        $state = 'approaching';
    } else {
        $state = 'ok';
    }

    return ['state' => $state, 'percent' => $percent];
}

/**
 * Get the message telling a customer their disk usage approaches or exceeds their disk limit
 *
 * @param int|float $usageBytes Disk usage in bytes
 * @param int|float $limitBytes Disk limit in bytes (0 = unlimited)
 * @return string Message, empty when usage is within the limit
 */
function getDiskUsageWarning($usageBytes, $limitBytes)
{
    $usage = getDiskUsageState($usageBytes, $limitBytes);

    switch ($usage['state']) {
        case 'approaching':
            return tr(
                'You have used %s of your %s disk space (%d%%). Consider reducing usage or contact your reseller to upgrade your plan.',
                bytesHuman($usageBytes), bytesHuman($limitBytes), $usage['percent']
            );
        case 'over':
            return tr(
                'You are using %s of your %s disk space. Your plan may be upgraded. Reduce usage or contact your reseller.',
                bytesHuman($usageBytes), bytesHuman($limitBytes)
            );
        default:
            return '';
    }
}

/**
 * Format an account's mail quota limit
 *
 * A mail quota of 0 has no limit of its own; with a disk limit it is bounded by it.
 *
 * @param int|float $mailQuotaBytes Account mail quota in bytes (0 = none of its own)
 * @param int|float $diskLimitBytes Account disk limit in bytes (0 = unlimited)
 * @return string
 */
function formatMailQuotaLimit($mailQuotaBytes, $diskLimitBytes)
{
    if ($mailQuotaBytes > 0) {
        return bytesHuman($mailQuotaBytes);
    }

    if ($diskLimitBytes > 0) {
        return tr('up to %s (account disk limit)', bytesHuman($diskLimitBytes));
    }

    return '∞';
}

/**
 * Format a mailbox's usage for the mailbox list
 *
 * @param int|float|null $usageBytes Mailbox usage in bytes, NULL if unknown
 * @param int|float $quotaBytes Mailbox quota in bytes (0 = unlimited)
 * @param int|float $diskLimitBytes Account disk limit in bytes (0 = unlimited)
 * @return string
 */
function formatMailboxUsage($usageBytes, $quotaBytes, $diskLimitBytes)
{
    if ($quotaBytes > 0) {
        if (NULL === $usageBytes) {
            return '- / ' . bytesHuman($quotaBytes);
        }

        return sprintf(
            '%s / %s (%.0f%%)',
            bytesHuman($usageBytes),
            bytesHuman($quotaBytes),
            min(100, round($usageBytes / $quotaBytes * 100))
        );
    }

    if (NULL === $usageBytes) {
        $usageBytes = 0;
    }

    if ($diskLimitBytes > 0) {
        return tr(
            '%s / %s (account limit) – %d%%',
            bytesHuman($usageBytes), bytesHuman($diskLimitBytes), floor($usageBytes / $diskLimitBytes * 100)
        );
    }

    return bytesHuman($usageBytes) . ' / ∞';
}

/**
 * Say when an account's disk usage was last measured
 *
 * @param int|null $timestamp Unix time of the last measurement, NULL if never
 * @param string $dateFormat Date format (config DATE_FORMAT)
 * @return string
 */
function formatDiskUsageMeasuredAt($timestamp, $dateFormat)
{
    if (empty($timestamp)) {
        return tr('Not measured yet');
    }

    return tr('Measured %s', date($dateFormat . ' H:i', (int)$timestamp));
}

/**
 * Get the summary line of customers over or approaching their disk limit
 *
 * @param int $overCount Customers over their disk limit
 * @param int $approachingCount Customers approaching their disk limit
 * @return string Summary, empty when both counts are 0
 */
function getDiskUsageSummaryMessage($overCount, $approachingCount)
{
    if ($overCount == 0 && $approachingCount == 0) {
        return '';
    }

    return tr('%d customers over their disk limit, %d approaching', $overCount, $approachingCount);
}

/**
 * Get the reseller's customers that are over or approaching their disk limit
 *
 * @param int $resellerId Reseller unique identifier
 * @return array [customer admin ID => ['state' => 'approaching'|'over', 'percent' => int]]
 */
function getResellerDiskUsageStates($resellerId)
{
    $stmt = exec_query(
        '
            SELECT t1.domain_admin_id, t1.domain_disk_usage, t1.domain_disk_limit
            FROM domain AS t1
            JOIN admin AS t2 ON(t2.admin_id = t1.domain_admin_id)
            WHERE t2.created_by = ?
        ',
        [$resellerId]
    );

    $states = [];
    while ($row = $stmt->fetchRow(PDO::FETCH_ASSOC)) {
        $usage = getDiskUsageState($row['domain_disk_usage'], $row['domain_disk_limit'] * 1048576);

        if ($usage['state'] != 'ok') {
            $states[$row['domain_admin_id']] = $usage;
        }
    }

    return $states;
}
