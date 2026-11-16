<?php

declare(strict_types=1);

namespace App\Organizations\Api;

/**
 * Actions within an organization (FCRM-002 section H): the read actions of
 * FCRM-FND-010B and the account actions of the MVP. Every action not listed
 * here is denied. Public (Api), so that the routes of every module can
 * declare their permission.
 */
enum Permission: string
{
    /** The organization profile. */
    case OrganizationView = 'organization.view';
    /** The member directory: name and role. */
    case MembershipList = 'membership.list';
    /** Members' e-mail addresses in the directory. */
    case MembershipViewEmail = 'membership.view_email';
    /** Customer companies: the list and one account. */
    case AccountView = 'account.view';
    /** Creating and editing accounts. */
    case AccountManage = 'account.manage';
    /** Archiving an account. */
    case AccountArchive = 'account.archive';
}
