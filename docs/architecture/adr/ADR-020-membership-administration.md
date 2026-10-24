# ADR-020: Membership administration

- **Status:** proposed (awaiting architecture review)
- **Related:** FCRM-002 (REQ-013 to REQ-015, BR-02, BR-03, BR-05, BR-31, AC-09, TI-04, T-04, section H), FCRM-003 C-05 and C-11, ADR-018 (database roles), ADR-019 (authentication and tenant authorization)
- **Design:** FCRM-FND-010C; details in [authentication](../authentication.md#membership-administration)

## Context

FND-010B made organizations readable: `TenantGuard` loads the user's
active membership on every request and checks one declared permission.
Memberships could only be created by the platform operator on the console.
FCRM-002 section H gives "add, remove, change role" to the ADMIN, and BR-03
requires that an organization never loses its last ADMIN.

Two things make a naive implementation unsafe:

- `TenantGuard` decides before the controller runs. If an ADMIN is demoted
  or removed between that check and the write, the write must not happen
  with the stale authorization.
- The last-admin rule is a rule across rows. Two ADMINs who demote each
  other at the same time each see two ADMINs and, under PostgreSQL's
  default isolation (READ COMMITTED), both writes succeed: no ADMIN is left.

## Decision

1. **Permissions:** `membership.add`, `membership.change_role` and
   `membership.remove`, granted to ADMIN only (`RolePolicy`). The read
   permissions of FND-010B are unchanged; MANAGER and REP get exactly the
   lists they had.

   | Permission | ADMIN | MANAGER | REP | Source |
   |---|---|---|---|---|
   | `membership.add` | yes | no | no | FCRM-002 section H [TASK] |
   | `membership.change_role` | yes | no | no | FCRM-002 section H [TASK] |
   | `membership.remove` | yes | no | no | FCRM-002 section H [TASK] |

2. **Endpoints** (tenant routes; one `#[TenantPermission]` each; the
   CSRF, origin, JSON and per-user limit rules of ADR-019 apply):
   - `POST /api/v1/organizations/{organizationId}/members` with
     `{"email", "role"}`: 201 with the member and `Location`;
   - `PATCH /api/v1/organizations/{organizationId}/members/{membershipId}`
     with `{"role"}`: 200 with the member;
   - `DELETE /api/v1/organizations/{organizationId}/members/{membershipId}`:
     204; the membership becomes `REMOVED` (the row stays, C-11).
3. **One transaction per change, serialised per organization**
   (`ManageMemberships`, inside `Transaction::run`):
   1. `SELECT id FROM organizations WHERE id = ? FOR NO KEY UPDATE` on the
      default connection, which the entity manager and the audit trail share
      (`OrganizationLock`, implemented by `DbalOrganizationLock`; it refuses
      to run outside a transaction). `NO KEY UPDATE` excludes a second
      holder but not the `KEY SHARE` locks of foreign key checks, so rows
      that reference the organization can be inserted meanwhile; the
      operator's `flowcrm:membership:add` takes the same lock. `flowcrm_app` already holds `UPDATE` on
      `organizations` (ADR-018); no privilege and no schema change is needed.
   2. The actor's own membership is read again under the lock. No active
      membership any more: 404 (as `TenantGuard` would answer now). Its role
      no longer grants the permission (`RolePolicy`): 403.
   3. The target membership is read by organization and ID; unknown, of
      another organization and `REMOVED` are the same 404.
   4. For the demotion or removal of an active ADMIN the active ADMINs are
      counted under the lock (`LastAdminRule`, a pure domain rule): fewer
      than two is a 409 `LAST_ADMIN`. The rule applies to everyone,
      including an ADMIN demoting or removing themselves.
   5. The change and its audit event are written and committed together
      (BR-31). If the event cannot be written the transaction rolls back
      and the answer is a 500. The member for the answer of `POST` and
      `PATCH` (the user's profile) is read in the same transaction, before
      the commit, so a failure there also rolls back. Only a commit
      without a known result (the connection is lost after `COMMIT` was
      sent) or a failure after the commit while the response is finished
      (for example the session write) can answer 500 for a saved change;
      clients that must know the outcome re-read the list instead of
      assuming a rollback.

   Every membership change of an organization takes the same row lock, so
   two concurrent changes run one after the other and the second sees the
   first: in the mutual-demotion case the second request finds that its
   actor is no longer ADMIN and gets 403. Reads (`TenantGuard`, the
   directory) take no lock and are not blocked.
4. **Audit:** `membership.added` `{role}`, `membership.role_changed`
   `{roleFrom, roleTo}`, `membership.removed` `{role}`; actor type `user`
   with the actor's user ID and actor role `ADMIN`, the organization, the
   request ID; never an e-mail address. A role change to the same role
   changes nothing and writes no event. Refusals are not audited; they are
   logged on the `security` channel (`tenant_not_found`,
   `authorization_denied`, `membership_change_refused` with a reason).
5. **Errors:**
   - 409 is a new problem type `/problems/conflict` with
     `errors: [{"code": …}]` (`ProblemException::conflict()`), codes
     `MEMBERSHIP_EXISTS` and `LAST_ADMIN`; the OpenAPI schema
     `ConflictProblem` lists exactly these codes.
   - 422 uses the existing `validation-error` type: `INVALID_ROLE`
     (pointer `/role`; roles are the exact upper-case values), `UNKNOWN_USER`
     (pointer `/email`), and `UNKNOWN_FIELD`, `REQUIRED`, `INVALID_TYPE` from
     `JsonBody`.
   - Status order: 415/403 `csrf-invalid`, 401, 429, 404 organization, 403
     permission, 404 target, 422, 409. For `PATCH` the body is parsed only
     after the target has been found under the lock, so an unknown target
     is a 404 even with an invalid body. For `POST` the body is validated
     before the actor is checked again under the lock: an actor demoted
     while the request is in flight gets 422 for an invalid body instead
     of 403; nothing is written either way.
6. **Adding** finds the user by e-mail address, case-insensitively
   (`UserDirectory::idOfEmail`). Only existing users can be added (BR-02);
   an unknown address is a 422 `UNKNOWN_USER`. Any existing membership of
   the user in the organization, active or removed, is a 409
   `MEMBERSHIP_EXISTS`.

## Excluded (not specified in FCRM-002)

- Reactivating a removed membership; a removed user cannot be added again.
- Leaving an organization without the ADMIN role, listing removed members.
- Changes to account recovery: the operator's
  `flowcrm:user:reset-password` stays the recovery path (FCRM-002 OQ-10).
- A dedicated rate limit for adding by e-mail beyond the per-user API limit
  (600 requests per minute): not implemented here; whether to add one is
  open (see "Account discovery and consent" under Open decisions).
- Invitations or creating users through the API.

## Deviations, with reasons

Recorded for the owner's decision; not approved.

| From | Implemented here | Why |
|---|---|---|
| FCRM-002 E (audit catalog): membership events record "Target user ID; role old/new" | the event's entity is the membership (`entity_type` `membership`, `entity_id` the membership ID) with `{role}` or `{roleFrom, roleTo}`; no user ID in `changes` | the same form as the operator's `membership.added`; the membership row is never deleted (C-11), so the target user follows from it |
| FCRM-003 I ("Errors"): a top-level stable `code` in problem documents | the 409 `conflict` problem carries its code in `errors: [{"code": …}]`; there is no top-level `code` | the `errors[]` form of the existing problem documents (ADR-019); one place for codes in every problem type |
| FCRM-002 Q, RK-09: "Add existing user by e-mail" reveals whether an e-mail is registered, to Admins; mitigation "Admin-only, rate limited, audited; revisit with invitations" | Admin-only as required; rate limited only by the per-user API limit; successful adds are audited, refused lookups (422 `UNKNOWN_USER`, 409 `MEMBERSHIP_EXISTS`) are not audited, only logged on the `security` channel as `membership_change_refused` without the e-mail address | refusals are not audited anywhere (decision 4, as ADR-019 for failed logins); see "Account discovery and consent" under Open decisions |

## Open decisions

- **Reactivation** of removed memberships (and how it is audited), or a
  new membership row after a removal: today both are refused with
  `MEMBERSHIP_EXISTS`.
- **Disabled ADMINs:** the last-admin rule counts active memberships whatever
  the user's account state, so the enabled ADMIN of an organization whose
  only other ADMIN is disabled can still demote or remove themselves, which
  leaves the organization with only a disabled ADMIN (pinned by
  `MembershipAdministrationTest::testADisabledAdminCountsForTheLastAdminRule`).
  Whether disabled users should count is not specified.
  Disabled users can also be added.
- **Account discovery and consent (privacy):** an ADMIN of any organization
  can learn whether an e-mail address has a FlowCRM account (422
  `UNKNOWN_USER` against 201 or 409), bounded only by the per-user API
  limit. A successful add also returns the user's display name and ID and
  makes them a member without their consent; the add is audited, and a
  removal blocks a later re-add (no reactivation). FCRM-002 BR-02 requires
  the distinction between known and unknown addresses, so this ADR keeps
  it. Not decided: a dedicated, lower limit for this route; a uniform answer
  with an invitation the user accepts (needs e-mail delivery, which does not
  exist); or no change. This is a product and privacy decision for the
  owner.
- **Code name:** `LAST_ADMIN` follows FCRM-002 BR-03; the sprint plan
  suggested `LAST_ADMIN_REQUIRED`. The API and the SPA must use one name.
- **Lock wait:** the lock wait is not bounded beyond PHP-FPM's request
  timeout; membership changes are rare and short, so no `lock_timeout` is
  set. A bounded wait (and its 503 answer) can be added if contention shows.

## Consequences

- Membership changes of one organization are serialised by a row lock on
  `organizations`. Changes to the organization row itself (none exist yet)
  would wait for them, and future writers that need the same invariant must
  take the same lock first.
- The authorization of a membership change is checked twice: by
  `TenantGuard` (cheap, before the controller) and under the lock (the one
  that decides the write).
- A demoted or removed member is affected from their next request, as for
  operator changes (TI-04): nothing about roles is cached.

## Verification

- `backend/tests/Integration/Database/OrganizationLockTest`: the lock
  excludes a second holder but not a referencing insert, and the
  operator's add waits for it.
- `backend/tests/Integration/Security/MembershipAdministrationTest` over
  the real PHP-FPM and PostgreSQL: the role matrix of the new routes,
  foreign organizations and membership IDs, the last-admin rule, audit
  events and their rollback, the rollback of a change whose answer cannot
  be read, CSRF on the new routes, and lock tests that
  hold the organization row from a separate connection: concurrent mutual
  demotions and mutual removals leave exactly one ADMIN; the last two
  ADMINs stepping down at once (one demotion, one removal) leave one, the
  second getting 409 `LAST_ADMIN`; two adds of one user create one
  membership and a 409 `MEMBERSHIP_EXISTS`; two removals of one member
  remove it once (204 and 404, one event); two different role changes of
  one member apply one after the other, the second starting from the
  first's role (one chain of events, no lost update); an ADMIN demoted (403) or
  removed (404) while their request waits is refused; another
  organization's changes and refusals do not wait for the lock.
- Unit tests: `RolePolicyTest` (the matrix), `MembershipRulesTest`
  (`Membership::changeRole`, `LastAdminRule`), `ManageMembershipsTest` (the
  lock comes first; every check, the audit event and the read of the member
  for the answer are inside the transaction).
- `MembershipRefusalLoggingTest`: refused lookups are logged on the
  `security` channel with reason, actor, organization, route and request
  ID, never the address.
- `tests/app/backend.sh` BE-18: twenty-one new negative controls
  (last-admin rule not applied or off by one, a removal checked like a
  promotion, the ADMIN count unscoped or including removed ADMINs, lock not
  taken or taking no row lock, actor re-check of the role, of a removed
  membership and for a weaker permission, the actor's membership not scoped
  to the organization, MANAGER granted `membership.change_role`, unscoped
  target lookup, a removed target changed again, no audit event or an
  audit event after the commit, the member for the answer read after the
  commit, a route without `TenantPermission`, an unvalidated role, a lock that blocks foreign key checks, the
  operator's add without the lock).

## Alternatives rejected

- **Trusting `TenantGuard`'s decision for the write:** a demotion between
  the check and the write would be ignored.
- **SERIALIZABLE isolation:** would detect the conflict, but only as a
  serialization failure that needs a retry loop around the whole request;
  the row lock makes the second request wait and then decide on current
  data.
- **Locking the membership rows (`FOR UPDATE` on the ADMINs):** does not
  cover memberships being added concurrently and needs more care to lock in
  a fixed order; one organization row is simpler.
- **PostgreSQL advisory locks:** not tied to a row, need a key scheme, and
  a forgotten unlock outlives the transaction unless the transaction-level
  variant is used; the row lock needs nothing new.
- **A database trigger for the last-admin rule:** would hide a business
  rule in the schema and still needs the same locking against concurrent
  transactions.
