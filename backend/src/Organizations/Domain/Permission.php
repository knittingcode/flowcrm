<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

/**
 * Actions within an organization (FCRM-002 section H). Only the read
 * actions of FCRM-FND-010B exist; every action not listed here is denied.
 */
enum Permission: string
{
    /** The organization profile. */
    case OrganizationView = 'organization.view';
    /** The member directory: name and role. */
    case MembershipList = 'membership.list';
    /** Members' e-mail addresses in the directory. */
    case MembershipViewEmail = 'membership.view_email';
}
