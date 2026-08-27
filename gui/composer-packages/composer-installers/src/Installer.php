<?php

namespace iMSCP\Composer;

use Composer\Composer;
use Composer\Installer\BinaryInstaller;
use Composer\Installer\LibraryInstaller;
use Composer\IO\IOInterface;
use Composer\Package\PackageInterface;
use Composer\Repository\InstalledRepositoryInterface;
use Composer\Util\Filesystem;

class Installer extends LibraryInstaller
{
    /**
     * Package types to installer class map
     *
     * @var array
     */
    private $supportedTypes = [
        'imscp'     => 'ImscpInstaller',
        'roundcube' => 'RoundcubeInstaller'
    ];

    /**
     * Installer constructor.
     *
     * Disables installers specified in main composer extra installer-disable
     * list
     *
     * @param IOInterface $io
     * @param Composer $composer
     * @param string $type
     * @param Filesystem|null $filesystem
     * @param BinaryInstaller|null $binaryInstaller
     */
    public function __construct(
        IOInterface $io,
        Composer $composer,
        $type = 'library',
        Filesystem $filesystem = null,
        BinaryInstaller $binaryInstaller = null
    ) {
        parent::__construct($io, $composer, $type, $filesystem, $binaryInstaller);

        $this->removeDisabledInstallers();
    }

    /**
     * Look for installers set to be disabled in composer's extra config and
     * remove them from the list of supported installers.
     *
     * Globals:
     *  - true, "all", and "*" - disable all installers.
     *  - false - enable all installers (useful with
     *     wikimedia/composer-merge-plugin or similar)
     *
     * @return void
     */
    protected function removeDisabledInstallers()
    {
        $extra = $this->composer->getPackage()->getExtra();
        if (! isset($extra['installer-disable']) || $extra['installer-disable'] === false) {
            // No installers are disabled
            return;
        }

        // Get installers to disable
        $disable = $extra['installer-disable'];
        // Ensure $disabled is an array
        if (! is_array($disable)) {
            $disable = [$disable];
        }

        // Check which installers should be disabled
        $all = [true, "all", "*"];
        $intersect = array_intersect($all, $disable);
        if (! empty($intersect)) {
            // Disable all installers
            $this->supportedTypes = [];
        } else {
            // Disable specified installers
            foreach ($disable as $key => $installer) {
                if (is_string($installer) && key_exists($installer, $this->supportedTypes)) {
                    unset($this->supportedTypes[$installer]);
                }
            }
        }
    }

    /**
     * {@inheritDoc}
     */
    public function getInstallPath(PackageInterface $package)
    {
        $type = $package->getType();
        $installerType = $this->findInstallerType($type);

        if ($installerType === false) {
            throw new \InvalidArgumentException(
                'The package type of this package is not supported.'
            );
        }

        $class = 'iMSCP\\Composer\\' . $this->supportedTypes[$installerType];

        /** @var \iMSCP\Composer\AbstractInstaller $installer */
        $installer = new $class($package, $this->composer, $this->getIO());

        return $installer->getInstallPath($package, $installerType);
    }

    /**
     * Finds a supported installer type if it exists and returns it
     *
     * @param  string $type
     * @return string
     */
    protected function findInstallerType($type)
    {
        $installerType = false;
        krsort($this->supportedTypes);

        foreach ($this->supportedTypes as $key => $val) {
            if ($key === substr($type, 0, strlen($key))) {
                $installerType = substr($type, 0, strlen($key));
                break;
            }
        }

        return $installerType;
    }

    /**
     * Get I/O object
     *
     * @return IOInterface
     */
    private function getIO()
    {
        return $this->io;
    }

    /**
     * {@inheritDoc}
     *
     * Composer 1 removes the package synchronously and returns nothing, so the
     * result could be reported immediately. Composer 2 performs the removal
     * asynchronously and hands back a promise, so reporting straight away would
     * inspect the directory before it has been deleted. Defer the report onto
     * the promise when there is one, and keep the old behaviour when there is
     * not.
     */
    public function uninstall(InstalledRepositoryInterface $repo, PackageInterface $package)
    {
        $installPath = $this->getPackageBasePath($package);
        $io = $this->io;

        $report = function () use ($io, $installPath) {
            $io->write(sprintf(
                'Deleting %s - %s',
                $installPath,
                ! file_exists($installPath) ? '<comment>deleted</comment>' : '<error>not deleted</error>'
            ));
        };

        $promise = parent::uninstall($repo, $package);

        if ($promise instanceof \React\Promise\PromiseInterface) {
            return $promise->then($report);
        }

        $report();

        return $promise;
    }

    /**
     * {@inheritDoc}
     */
    public function supports($packageType)
    {
        $installerType = $this->findInstallerType($packageType);

        if ($installerType === false) {
            return false;
        }

        $locationPattern = $this->getLocationPattern($installerType);

        return preg_match('#' . $installerType . '-' . $locationPattern . '#', $packageType, $matches) === 1;
    }

    /**
     * Get the second part of the regular expression to check for support of a
     * package type
     *
     * @param  string $installerType
     * @return string
     */
    protected function getLocationPattern($installerType)
    {
        $pattern = false;

        if (! empty($this->supportedTypes[$installerType])) {
            $installerClass = 'iMSCP\\Composer\\' . $this->supportedTypes[$installerType];
            /** @var AbstractInstaller $installer */
            $installer = new $installerClass(null, $this->composer, $this->getIO());
            $locations = array_keys($installer->getLocations());
            $pattern = $locations ? '(' . implode('|', $locations) . ')' : false;
        }

        return $pattern ?: '(\w+)';
    }
}
