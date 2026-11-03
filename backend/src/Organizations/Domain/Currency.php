<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

/**
 * The currencies an organization may use (FCRM-003 section F, OQ-05); the
 * database enforces the same allow-list.
 */
enum Currency: string
{
    case EUR = 'EUR';
    case PLN = 'PLN';
    case USD = 'USD';
    case GBP = 'GBP';
    case CHF = 'CHF';
    case SEK = 'SEK';
    case NOK = 'NOK';
    case DKK = 'DKK';
    case CZK = 'CZK';
}
