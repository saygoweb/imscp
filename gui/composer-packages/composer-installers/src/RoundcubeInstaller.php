<?php

namespace iMSCP\Composer;

class RoundcubeInstaller extends AbstractInstaller
{
    protected $locations = [
        'plugin' => 'plugins/{$name}/',
    ];

    /**
     * Lowercase name and changes the name to a underscores
     *
     * @param  array $vars
     * @return array
     */
    public function inflectPackageVars(array $vars): array
    {
        $vars['name'] = strtolower(str_replace('-', '_', $vars['name']));

        return $vars;
    }
}
