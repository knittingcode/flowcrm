<?php

declare(strict_types=1);

namespace App\CRM\Infrastructure\Persistence;

use Doctrine\Bundle\DoctrineBundle\Attribute\AsDoctrineListener;
use Doctrine\ORM\Tools\Event\GenerateSchemaEventArgs;
use Doctrine\ORM\Tools\ToolEvents;

/**
 * Foreign keys of the CRM tables, added to the schema generated from the
 * mapping (entities reference other modules' rows by ID, without ORM
 * associations), so that schema validation compares them with the database.
 */
#[AsDoctrineListener(event: ToolEvents::postGenerateSchema)]
final class CrmSchema
{
    public function postGenerateSchema(GenerateSchemaEventArgs $args): void
    {
        $schema = $args->getSchema();
        if ($schema->hasTable('accounts')) {
            $schema->getTable('accounts')->addForeignKeyConstraint('organizations', ['organization_id'], ['id'], [], 'accounts_organization_fkey');
        }
    }
}
