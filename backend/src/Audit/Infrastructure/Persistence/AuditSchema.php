<?php

declare(strict_types=1);

namespace App\Audit\Infrastructure\Persistence;

use Doctrine\Bundle\DoctrineBundle\Attribute\AsDoctrineListener;
use Doctrine\ORM\Tools\Event\GenerateSchemaEventArgs;
use Doctrine\ORM\Tools\ToolEvents;

/**
 * Foreign key of the audit log, added to the schema generated from the
 * mapping. The append-only trigger is created by the migration; schema
 * comparison does not cover triggers.
 */
#[AsDoctrineListener(event: ToolEvents::postGenerateSchema)]
final class AuditSchema
{
    public function postGenerateSchema(GenerateSchemaEventArgs $args): void
    {
        $schema = $args->getSchema();
        if ($schema->hasTable('audit_events')) {
            $schema->getTable('audit_events')->addForeignKeyConstraint('organizations', ['organization_id'], ['id'], [], 'audit_events_organization_fkey');
        }
    }
}
