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
      and the answer is a 500.

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
     is a 404 even with an invalid body.
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
  (600 requests per minute).
- Invitations or creating users through the API.

## Open decisions

- **Reactivation** of removed memberships (and how it is audited), or a
  new membership row after a removal: today both are refused with
  `MEMBERSHIP_EXISTS`.
- **Disabled ADMINs:** the last-admin rule counts active memberships whatever
  the user's account state, so an organization whose only other ADMIN is
  disabled cannot demote its last enabled ADMIN, but could be left with only
  a disabled ADMIN. Whether disabled users should count is not specified.
  Disabled users can also be added.
- **Add-by-e-mail limit:** an ADMIN can learn whether an e-mail address has
  an account (422 `UNKNOWN_USER` against 201 or 409), bounded only by the
  per-user API limit. FCRM-002 BR-02 requires the distinction; a dedicated,
  lower limit for this route is a product decision.
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
  events and their rollback, CSRF on the new routes, and two lock tests
  that hold the organization row from a separate connection: concurrent
  mutual demotions leave exactly one ADMIN, and an ADMIN demoted while
  their request waits is refused.
- Unit tests: `RolePolicyTest` (the matrix), `MembershipRulesTest`
  (`Membership::changeRole`, `LastAdminRule`), `ManageMembershipsTest` (the
  lock comes first; every check and the audit event are inside the
  transaction).
- `tests/app/backend.sh` BE-18: eight new negative controls (last-admin
  rule, lock, actor re-check, MANAGER granted `membership.change_role`,
  unscoped target lookup, audit event after the commit, a route without
  `TenantPermission`, an unvalidated role).

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
