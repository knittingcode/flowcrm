<?php

declare(strict_types=1);

namespace App\Tests\Integration\Database;

use App\Audit\Domain\ActorType;
use App\Audit\Domain\AuditEvent;
use App\Identity\Domain\User;
use App\Organizations\Domain\Currency;
use App\Organizations\Domain\Membership;
use App\Organizations\Domain\MembershipRole;
use App\Organizations\Domain\MembershipStatus;
use App\Organizations\Domain\Organization;
use App\Sales\Domain\Pipeline;
use App\Sales\Domain\PipelineStage;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Uid\Uuid;

/**
 * The ORM mapping of the core entities against the migrated schema: each
 * entity is written and read back unchanged. Runs in a rolled-back
 * transaction.
 */
final class CoreEntitiesTest extends KernelTestCase
{
    private EntityManagerInterface $em;

    protected function setUp(): void
    {
        $em = self::getContainer()->get('doctrine.orm.entity_manager');
        self::assertInstanceOf(EntityManagerInterface::class, $em);
        $this->em = $em;
        $this->em->getConnection()->beginTransaction();
    }

    protected function tearDown(): void
    {
        $this->em->getConnection()->rollBack();
        $this->em->clear();
        parent::tearDown();
    }

    public function testCoreEntitiesRoundTrip(): void
    {
        $at = new \DateTimeImmutable('2026-10-22T08:15:30+00:00');
        $user = new User(Uuid::v7(), 'Anna.Nowak@example.com', '$argon2id$hash', 'Anna Nowak', $at);
        $org = new Organization(Uuid::v7(), 'Acme', Currency::PLN, 'Europe/Warsaw', $at);
        $membership = new Membership(Uuid::v7(), $org->id(), $user->id(), MembershipRole::Manager, $at);
        $pipeline = new Pipeline(Uuid::v7(), $org->id());
        $stage = new PipelineStage(Uuid::v7(), $org->id(), $pipeline->id(), 'Qualified', 1);
        $event = new AuditEvent(Uuid::v7(), $org->id(), $at, ActorType::PlatformOperator, null, null, 'organization.created', 'organization', $org->id(), ['name' => ['to' => 'Acme']], Uuid::v7(), '2001:db8::1');
        foreach ([$user, $org, $membership, $pipeline, $stage, $event] as $entity) {
            $this->em->persist($entity);
        }
        $this->em->flush();
        $membership->remove($at->modify('+1 day'));
        $stage->archive($at->modify('+2 days'));
        $this->em->flush();
        $this->em->clear();

        $loadedUser = $this->em->find(User::class, $user->id());
        self::assertInstanceOf(User::class, $loadedUser);
        self::assertSame('Anna.Nowak@example.com', $loadedUser->email());
        self::assertEquals($at, $loadedUser->createdAt());

        $loadedOrg = $this->em->find(Organization::class, $org->id());
        self::assertInstanceOf(Organization::class, $loadedOrg);
        self::assertSame(Currency::PLN, $loadedOrg->currency());
        self::assertSame('Europe/Warsaw', $loadedOrg->timezone());

        $loadedMembership = $this->em->find(Membership::class, $membership->id());
        self::assertInstanceOf(Membership::class, $loadedMembership);
        self::assertSame(MembershipRole::Manager, $loadedMembership->role());
        self::assertSame(MembershipStatus::Removed, $loadedMembership->status());
        self::assertEquals($at->modify('+1 day'), $loadedMembership->removedAt());
        self::assertTrue($user->id()->equals($loadedMembership->userId()));

        $loadedStage = $this->em->find(PipelineStage::class, $stage->id());
        self::assertInstanceOf(PipelineStage::class, $loadedStage);
        self::assertTrue($pipeline->id()->equals($loadedStage->pipelineId()));
        self::assertEquals($at->modify('+2 days'), $loadedStage->archivedAt());

        $loadedEvent = $this->em->find(AuditEvent::class, $event->id());
        self::assertInstanceOf(AuditEvent::class, $loadedEvent);
        self::assertSame(ActorType::PlatformOperator, $loadedEvent->actorType());
        self::assertSame(['name' => ['to' => 'Acme']], $loadedEvent->changes());
        self::assertSame('2001:db8::1', $loadedEvent->ip());
    }
}
