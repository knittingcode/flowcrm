<?php

declare(strict_types=1);

namespace App\Sales\Infrastructure\Persistence;

use Doctrine\Bundle\DoctrineBundle\Attribute\AsDoctrineListener;
use Doctrine\ORM\Tools\Event\GenerateSchemaEventArgs;
use Doctrine\ORM\Tools\ToolEvents;

/**
 * Foreign keys of the Sales tables, added to the schema generated from the
 * mapping. A stage references its pipeline together with the organization
 * (a composite tenant key, FCRM-003 section F), so a stage can never belong
 * to another organization's pipeline.
 */
#[AsDoctrineListener(event: ToolEvents::postGenerateSchema)]
final class SalesSchema
{
    public function postGenerateSchema(GenerateSchemaEventArgs $args): void
    {
        $schema = $args->getSchema();
        if ($schema->hasTable('pipelines')) {
            $schema->getTable('pipelines')->addForeignKeyConstraint('organizations', ['organization_id'], ['id'], [], 'pipelines_organization_fkey');
        }
        if ($schema->hasTable('pipeline_stages')) {
            $schema->getTable('pipeline_stages')->addForeignKeyConstraint('pipelines', ['organization_id', 'pipeline_id'], ['organization_id', 'id'], [], 'pipeline_stages_pipeline_fkey');
        }
    }
}
