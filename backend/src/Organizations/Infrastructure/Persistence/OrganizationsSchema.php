<?php

declare(strict_types=1);

namespace App\Organizations\Infrastructure\Persistence;

use Doctrine\Bundle\DoctrineBundle\Attribute\AsDoctrineListener;
use Doctrine\ORM\Tools\Event\GenerateSchemaEventArgs;
use Doctrine\ORM\Tools\ToolEvents;

/**
 * Foreign keys of the Organizations tables. Entities reference other rows by
 * ID, without ORM associations (users belong to another module), so the
 * keys are added to the schema generated from the mapping; schema
 * validation then compares them with the database.
 */
#[AsDoctrineListener(event: ToolEvents::postGenerateSchema)]
final class OrganizationsSchema
{
    public function postGenerateSchema(GenerateSchemaEventArgs $args): void
    {
        $schema = $args->getSchema();
        if (!$schema->hasTable('memberships')) {
            return;
        }
        $memberships = $schema->getTable('memberships');
        $memberships->addForeignKeyConstraint('organizations', ['organization_id'], ['id'], [], 'memberships_organization_fkey');
        $memberships->addForeignKeyConstraint('users', ['user_id'], ['id'], [], 'memberships_user_fkey');
    }
}
