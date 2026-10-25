<?php

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class StatisticsTest extends TestCase
{
    private const MIB = 1048576;
    private const GIB = 1073741824;

    public static function stateCases(): array
    {
        return [
            'unlimited'          => [5 * self::GIB, 0, 'ok', 0],
            'empty account'      => [0, 1000, 'ok', 0],
            '79 percent'         => [790, 1000, 'ok', 79],
            '80 percent'         => [800, 1000, 'approaching', 80],
            'exactly the limit'  => [1000, 1000, 'approaching', 100],
            'one byte over'      => [1001, 1000, 'over', 100],
            '110 percent'        => [1100, 1000, 'over', 110],
        ];
    }

    #[DataProvider('stateCases')]
    public function testGetDiskUsageState($usage, $limit, $state, $percent): void
    {
        $this->assertSame(['state' => $state, 'percent' => $percent], getDiskUsageState($usage, $limit));
    }

    public function testGetDiskUsageStateLabel(): void
    {
        $this->assertSame('Over limit', getDiskUsageStateLabel('over'));
        $this->assertSame('Approaching limit', getDiskUsageStateLabel('approaching'));
        $this->assertSame('', getDiskUsageStateLabel('ok'));
    }

    public function testGetDiskUsageWarning(): void
    {
        $this->assertSame('', getDiskUsageWarning(1 * self::GIB, 5 * self::GIB));
        $this->assertSame('', getDiskUsageWarning(9 * self::GIB, 0));
        $this->assertSame(
            'You have used 4.50 GiB of your 5.00 GiB disk space (90%). Consider reducing usage or contact your reseller to upgrade your plan.',
            getDiskUsageWarning(4.5 * self::GIB, 5 * self::GIB)
        );
        $this->assertSame(
            'You are using 6.00 GiB of your 5.00 GiB disk space. Your plan may be upgraded. Reduce usage or contact your reseller.',
            getDiskUsageWarning(6 * self::GIB, 5 * self::GIB)
        );
    }

    public function testFormatMailQuotaLimit(): void
    {
        $this->assertSame('up to 5.00 GiB (account disk limit)', formatMailQuotaLimit(0, 5 * self::GIB));
        $this->assertSame('∞', formatMailQuotaLimit(0, 0));
        $this->assertSame('2.00 GiB', formatMailQuotaLimit(2 * self::GIB, 5 * self::GIB));
        $this->assertSame('2.00 GiB', formatMailQuotaLimit(2 * self::GIB, 0));
    }

    public function testFormatMailboxUsage(): void
    {
        // Unlimited mailbox, account with a disk limit
        $this->assertSame(
            '1.20 GiB / 5.00 GiB (account limit) – 24%', formatMailboxUsage(1.2 * self::GIB, 0, 5 * self::GIB)
        );
        // Unlimited mailbox, unlimited account
        $this->assertSame('1.20 GiB / ∞', formatMailboxUsage(1.2 * self::GIB, 0, 0));
        // Mailbox with a quota (as mail_accounts.php showed it before)
        $this->assertSame('250.00 MiB / 500.00 MiB (50%)', formatMailboxUsage(250 * self::MIB, 500 * self::MIB, 0));
        $this->assertSame('600.00 MiB / 500.00 MiB (100%)', formatMailboxUsage(600 * self::MIB, 500 * self::MIB, 0));
        // Mailbox with a quota but no maildirsize yet
        $this->assertSame('- / 500.00 MiB', formatMailboxUsage(NULL, 500 * self::MIB, 5 * self::GIB));
        // Never measured, unlimited
        $this->assertSame('0.00 B / ∞', formatMailboxUsage(0, 0, 0));
    }

    public function testFormatDiskUsageMeasuredAt(): void
    {
        $this->assertSame('Not measured yet', formatDiskUsageMeasuredAt(NULL, 'd.m.Y'));
        $this->assertSame('Not measured yet', formatDiskUsageMeasuredAt(0, 'd.m.Y'));
        $this->assertSame('Measured 25.10.2026 03:00', formatDiskUsageMeasuredAt(1792897200, 'd.m.Y'));
    }

    public function testGetDiskUsageSummaryMessage(): void
    {
        $this->assertSame('', getDiskUsageSummaryMessage(0, 0));
        $this->assertSame(
            '3 customers over their disk limit, 5 approaching', getDiskUsageSummaryMessage(3, 5)
        );
        $this->assertSame(
            '0 customers over their disk limit, 1 approaching', getDiskUsageSummaryMessage(0, 1)
        );
    }
}
