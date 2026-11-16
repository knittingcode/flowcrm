# FlowCRM MVP

Frozen on 2026-11-16. A change to the scope below is a change to this file,
agreed with the project owner. The task list is in
[MVP-BACKLOG.md](MVP-BACKLOG.md).

## 1. Goal

A small sales team can keep its customers, contacts and deals in FlowCRM and
see where every deal stands: one complete workflow through the real
frontend, API and database, reproducible on a developer machine.

## 2. Target user

A sales representative or sales manager of one company (one organization in
FlowCRM), working in a browser. The platform operator creates the
organization and its users with the console; there is no registration.

## 3. User journey

1. The user signs in and is in their organization.
2. They add a customer company (account) and open it.
3. They add a contact and link it to the account.
4. They create an opportunity for the account; it starts in the first stage
   of the organization's pipeline.
5. They move the opportunity to another stage, and later mark it won or
   lost.
6. They record a note on the account, the contact or the opportunity and
   see the history in order.
7. They look at the open opportunities by stage.
8. They sign out; after signing in again everything is still there.

A session works in one organization at a time, the one in the address. The
data model and every request keep organizations apart.

## 4. In scope

| ID | Feature | Minimum |
|---|---|---|
| M1 | Authentication and organization context | login, logout, session, current user, the organization of the address, permission per route, tenant isolation (existing) |
| M2 | Accounts | create, list, open, edit, archive; name, optional website, e-mail and phone, timestamps |
| M3 | Contacts | create, list, open, edit; first and last name, e-mail, optional phone, optional account of the same organization |
| M4 | Pipeline | one pipeline per organization with ordered stages, created with the organization; stages listed by the API and shown in the frontend |
| M5 | Opportunities | create for an account, in a stage; list, open, edit; move between stages; mark won or lost; optional value and expected close date |
| M6 | Activity history | a note on an account, a contact or an opportunity, with its author and time; shown in chronological order |
| M7 | Frontend | layout and navigation; lists and detail pages for accounts and contacts; opportunities by stage; forms with validation messages; loading, error and empty states |
| M8 | Demo | reproducible start, a repeatable seed of synthetic demo data, a written walkthrough |

## 5. Out of scope

E-mail, Gmail or Outlook and calendar integration; workflow automation; AI
features; analytics, dashboards and forecasts; custom fields; several
pipelines per organization and a pipeline editor; attachments; CSV import
and export; webhooks and plugins; billing; role administration beyond the
existing three roles; switching organizations inside a page; real-time
collaboration; mobile apps; search infrastructure; microservices,
Kubernetes and new orchestration; refactoring of finished modules.

Membership administration (pull requests #19 and #20) is not part of the
MVP: the operator console adds members.

## 6. Acceptance criteria

Status on 2026-11-16, from the evidence named in the backlog. "Verified"
means tests for it pass in the required CI checks on `main`.

| ID | Criterion | Status |
|---|---|---|
| AC-01 | A user can sign in and access the CRM. | verified on `main` |
| AC-02 | A company can be created, listed, opened and edited. | implemented in S1, not yet on `main` |
| AC-03 | A contact can be created and linked to a company. | missing (S2) |
| AC-04 | A pipeline with ordered stages exists. | partly: tables and entities exist; no default pipeline, API or page (S3) |
| AC-05 | An opportunity can be created and assigned to a stage. | missing (S3) |
| AC-06 | The opportunity can be moved to another valid stage. | missing (S3) |
| AC-07 | An opportunity can be marked won or lost. | missing (S3) |
| AC-08 | Activities can be recorded and viewed in chronological order. | missing (S4) |
| AC-09 | Data remains persisted after an application restart. | verified on `main` for users, organizations and sessions (stack tests); per CRM table with its slice |
| AC-10 | Cross-tenant access and cross-tenant associations are rejected. | verified on `main` for organizations and members; per CRM resource with its slice |
| AC-11 | All MVP workflows are accessible through the React frontend. | per slice |
| AC-12 | All required backend, frontend and integration tests pass. | per slice |
| AC-13 | The required GitHub Actions checks pass on the final MVP revision. | at the end (S5) |
| AC-14 | The README contains exact setup and demo instructions. | setup exists; demo instructions missing (S5) |
| AC-15 | An end-to-end demonstration passes without manual database editing. | missing (S5) |

## 7. What exists

- Sign-in with e-mail and password, server-side sessions in PostgreSQL,
  CSRF and origin checks, login and API rate limits, audit log
  ([authentication](../architecture/authentication.md), ADR-019).
- Organizations, memberships with the roles ADMIN, MANAGER and REP, tenant
  resolution from the address and one permission per route
  (`TenantGuard`); operator console commands for users, organizations and
  memberships.
- Tables and entities for the pipeline and its stages, without use cases.
- React application with login, organization page and member directory.
- Docker Compose development stack, `make` commands, backend, frontend,
  stack and production-like test suites, container scan, CI.

## 8. What is missing

Accounts (S1, in review), contacts, the default pipeline with its API,
opportunities, activity history, their pages in the frontend, demo data and
the demo walkthrough.

## 9. Dependencies and decisions

- Modules follow [backend modules](../architecture/backend-modules.md):
  accounts and contacts in `CRM`, pipeline and opportunities in `Sales`,
  notes in `Activities`.
- Every CRM table is a tenant table: `organization_id` plus `UNIQUE
  (organization_id, id)`, and references to other CRM rows are composite
  foreign keys, so PostgreSQL itself refuses a link across organizations
  ([data model](../architecture/data-model.md)).
- CRM routes are under `/api/v1/organizations/{organizationId}/…`, declare
  one permission and are described in `backend/openapi.yaml`.
- Rows are archived or closed, not deleted.
- Each slice needs: a migration with the runtime privileges (ADR-018), unit
  and integration tests including the cross-tenant cases, negative controls
  for its protections, component tests and a browser test.
- Separate from the MVP, tracked by the owner: the scan exception for
  CVE-2026-116587 (expires 2026-11-30), open Dependabot alerts, the Trivy
  cache cleanup messages and the credential incident C032-01/02.

## 10. Definition of Done

The MVP is done when AC-01 to AC-15 are all verified on one revision of
`main`: the required CI checks pass on it, the browser tests walk the
journey of section 3 against the real stack, and the README walkthrough
works on a fresh checkout with the seeded demo data. A slice is done when
its acceptance criteria are verified in CI and its pull request is merged.
No partly built feature counts.
