<?php

declare(strict_types=1);

namespace App\Organizations\Domain;

/**
 * Actions within an organization (FCRM-002 section H): the read actions of
 * FCRM-FND-010B and the membership administration of FCRM-FND-010C. Every
 * action not listed here is denied.
 */
enum Permission: string
{
    /** The organization profile. */
    case OrganizationView = 'organization.view';
    /** The member directory: name and role. */
    case MembershipList = 'membership.list';
    /** Members' e-mail addresses in the directory. */
    case MembershipViewEmail = 'membership.view_email';
    /** Adding an existing user to the organization with a role. */
    case MembershipAdd = 'membership.add';
    /** Changing a member's role. */
    case MembershipChangeRole = 'membership.change_role';
    /** Removing a member (the membership becomes REMOVED). */
    case MembershipRemove = 'membership.remove';
}
