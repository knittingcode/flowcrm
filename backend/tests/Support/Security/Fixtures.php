<?php

declare(strict_types=1);

namespace App\Tests\Support\Security;

use App\Identity\Infrastructure\Security\SecurityUser;
use Doctrine\DBAL\Connection;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Symfony\Component\PasswordHasher\Hasher\PasswordHasherFactoryInterface;
use Symfony\Component\PasswordHasher\PasswordHasherInterface;
use Symfony\Component\Uid\Uuid;

/**
 * Synthetic users, organizations and memberships for the security tests,
 * written as the runtime role flowcrm_app (the API's own privileges).
 * Addresses use the reserved .test domain and a random part, so tests never
 * share an account (or its login limits) and need no cleanup in the
 * throwaway test database.
 */
final readonly class Fixtures
{
    public const PASSWORD = 'correct horse battery staple';

    public function __construct(
        private Connection $connection,
        private PasswordHasherInterface $hasher,
    ) {
    }

    public static function from(ContainerInterface $container): self
    {
        $connection = $container->get('doctrine.dbal.default_connection');
        $hashers = $container->get('security.password_hasher_factory');
        \assert($connection instanceof Connection && $hashers instanceof PasswordHasherFactoryInterface);

        return new self($connection, $hashers->getPasswordHasher(SecurityUser::class));
    }

    /** @param string|null $hash a ready-made hash instead of one of $password */
    public function user(string $label, string $password = self::PASSWORD, ?string $hash = null): TestUser
    {
        $id = Uuid::v7();
        $email = $label.'-'.bin2hex(random_bytes(4)).'@example.test';
        $name = ucfirst($label).' Tester';
        $this->connection->insert('users', [
            'id' => $id->toRfc4122(),
            'email' => $email,
            'password_hash' => $hash ?? $this->hasher->hash($password),
            'display_name' => $name,
            'created_at' => '2026-10-23 08:00:00+00',
        ]);

        return new TestUser($id, $email, $password, $name);
    }

    public function organization(string $label): Uuid
    {
        $id = Uuid::v7();
        $this->connection->insert('organizations', [
            'id' => $id->toRfc4122(),
            'name' => ucfirst($label).' '.bin2hex(random_bytes(3)),
            'currency' => 'EUR',
            'timezone' => 'Europe/Warsaw',
            'created_at' => '2026-10-23 08:00:00+00',
        ]);

        return $id;
    }

    public function member(Uuid $organization, TestUser $user, string $role): Uuid
    {
        $id = Uuid::v7();
        $this->connection->insert('memberships', [
            'id' => $id->toRfc4122(),
            'organization_id' => $organization->toRfc4122(),
            'user_id' => $user->id->toRfc4122(),
            'role' => $role,
            'status' => 'ACTIVE',
            'created_at' => '2026-10-23 08:00:00+00',
        ]);

        return $id;
    }

    public function changeRole(Uuid $membership, string $role): void
    {
        $this->connection->update('memberships', ['role' => $role], ['id' => $membership->toRfc4122()]);
    }

    public function removeMembership(Uuid $membership): void
    {
        $this->connection->executeStatement("UPDATE memberships SET status = 'REMOVED', removed_at = now() WHERE id = ?", [$membership->toRfc4122()]);
    }

    public function connection(): Connection
    {
        return $this->connection;
    }
}
