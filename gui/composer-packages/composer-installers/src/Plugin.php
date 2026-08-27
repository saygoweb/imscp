<?php

namespace iMSCP\Composer;

use Composer\Composer;
use Composer\IO\IOInterface;
use Composer\Plugin\PluginInterface;

class Plugin implements PluginInterface
{
    public function activate(Composer $composer, IOInterface $io)
    {
        $installer = new Installer($io, $composer);
        $composer->getInstallationManager()->addInstaller($installer);
    }

    /**
     * Composer 2 added this method to PluginInterface and it is not optional.
     *
     * Nothing to undo: the installer is registered on the installation manager
     * for the duration of a single run and is discarded along with it.
     *
     * @param Composer $composer
     * @param IOInterface $io
     * @return void
     */
    public function deactivate(Composer $composer, IOInterface $io)
    {
    }

    /**
     * Composer 2 added this method to PluginInterface and it is not optional.
     *
     * Nothing to clean up: this plugin keeps no state outside of the package
     * directories that Composer removes itself.
     *
     * @param Composer $composer
     * @param IOInterface $io
     * @return void
     */
    public function uninstall(Composer $composer, IOInterface $io)
    {
    }
}
