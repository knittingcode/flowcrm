<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use Symfony\Component\Uid\Uuid;

/**
 * A tenant (FCRM-003 section F). Its timezone is an IANA identifier, checked
 * here because the database cannot.
 */
#[ORM\Entity]
#[ORM\Table(name: 'organizations')]
class Organization
{
    #[ORM\Id]
    #[ORM\Column(type: 'uuid')]
    private Uuid $id;

    #[ORM\Column(type: Types::TEXT)]
    private string $name;

    #[ORM\Column(type: Types::STRING, length: 3, options: ['fixed' => true], enumType: Currency::class)]
    private Currency $currency;

    #[ORM\Column(type: Types::TEXT)]
    private string $timezone;

    #[ORM\Column(type: Types::DATETIMETZ_IMMUTABLE)]
    private \DateTimeImmutable $createdAt;

    public function __construct(Uuid $id, string $name, Currency $currency, string $timezone, \DateTimeImmutable $createdAt)
    {
        if ('' === trim($name)) {
            throw new \InvalidArgumentException('The organization name is empty.');
        }
        if (!\in_array($timezone, \DateTimeZone::listIdentifiers(), true)) {
            throw new \InvalidArgumentException('Unknown IANA timezone.');
        }

        $this->id = $id;
        $this->name = $name;
        $this->currency = $currency;
        $this->timezone = $timezone;
        $this->createdAt = $createdAt;
    }

    public function id(): Uuid
    {
        return $this->id;
    }

    public function name(): string
    {
        return $this->name;
    }

    public function currency(): Currency
    {
        return $this->currency;
    }

    public function timezone(): string
    {
        return $this->timezone;
    }

    public function createdAt(): \DateTimeImmutable
    {
        return $this->createdAt;
    }
}
