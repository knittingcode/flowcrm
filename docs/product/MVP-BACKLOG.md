# FlowCRM MVP backlog

The tasks that complete [MVP.md](MVP.md), in dependency order. Each slice is
one pull request with backend, frontend and tests. A status changes only
with evidence: a test, a CI run or a merged pull request.

Statuses: `done` (merged, CI green on `main`), `in review` (implemented and
tested on its branch), `todo`.

## Critical path

S1 → S2 → S3 → S4 → S5. S2 needs the accounts table of S1 (a contact
references an account). S3 needs accounts (an opportunity belongs to one).
S4 needs all three (a note refers to one of them). S5 needs everything.

## S1 — Accounts (AC-02; AC-09 to AC-12 for accounts)

Status: `in review` (branch `feat/fcrm-mvp-s1-accounts`).

| Task | Deliverable | Status |
|---|---|---|
| S1.1 | `accounts` table with tenant key and checks; runtime privileges without DELETE; `Account` entity in `CRM` | in review |
| S1.2 | Permissions `account.view`, `account.manage` (all roles) and `account.archive` (ADMIN, MANAGER); `Permission` and `TenantPermission` in the public Api of `Organizations` so that other modules can declare routes | in review |
| S1.3 | API: list, create, open, replace, archive under `/organizations/{organizationId}/accounts`; validation with a code per field; audit events without values; OpenAPI | in review |
| S1.4 | Tests: domain rules, API over PHP-FPM (CRUD, another organization's accounts, forged organization, CSRF, permissions, paging, audit, persistence), concurrent writes, schema, route pins, seven negative controls | in review |
| S1.5 | Frontend: accounts list with empty state and form, account page with edit and archive, navigation; component tests; browser test | in review |

## S2 — Contacts (AC-03; AC-09 to AC-12 for contacts)

Status: `todo`. Needs S1.

| Task | Deliverable |
|---|---|
| S2.1 | `contacts` table: first name, last name, e-mail, optional phone, optional `account_id` as a composite foreign key `(organization_id, account_id)`; `Contact` entity in `CRM` |
| S2.2 | Permissions `contact.view` and `contact.manage`; API: list, create, open, replace, with the account as an optional member checked against the organization |
| S2.3 | Tests as in S1.4, plus: an account of another organization as `accountId` is rejected by the API (422) and by the database |
| S2.4 | Frontend: contacts list and page with form and account choice; the account page lists its contacts; tests as in S1.5 |

## S3 — Pipeline and opportunities (AC-04 to AC-07; AC-09 to AC-12)

Status: `todo`. Needs S1.

| Task | Deliverable |
|---|---|
| S3.1 | A default pipeline with ordered stages for every organization: created with the organization, and by a migration for existing ones; API to list the stages |
| S3.2 | `opportunities` table: title, account and stage as composite foreign keys, status `OPEN`, `WON` or `LOST`, optional value (in the organization's currency) and expected close date; `Opportunity` entity in `Sales` |
| S3.3 | Permissions and API: list (by stage), create, open, edit, move to a stage, mark won or lost. Rules: only an active stage of the organization's pipeline; only an open opportunity moves or closes |
| S3.4 | Tests as in S1.4, plus: a stage or account of another organization is rejected, a move of a closed opportunity is rejected, an archived stage is rejected |
| S3.5 | Frontend: opportunities by stage, opportunity page with form, stage change and won or lost; the account page lists its opportunities; tests as in S1.5 |

## S4 — Activity history (AC-08; AC-09 to AC-12)

Status: `todo`. Needs S1, S2 and S3.

| Task | Deliverable |
|---|---|
| S4.1 | `notes` table in `Activities`: text, author, time and exactly one subject (account, contact or opportunity) as a composite foreign key |
| S4.2 | Permissions and API: add a note to a subject, list the notes of a subject oldest first |
| S4.3 | Tests as in S1.4, plus: a subject of another organization is rejected, a note without or with two subjects is rejected |
| S4.4 | Frontend: a timeline with a form on the account, contact and opportunity pages; tests as in S1.5 |

## S5 — Demo and release validation (AC-13 to AC-15)

Status: `todo`. Needs S1 to S4.

| Task | Deliverable |
|---|---|
| S5.1 | Console command that seeds a synthetic demo organization (users, accounts, contacts, opportunities in several stages, notes); repeatable; refused outside development and test |
| S5.2 | One browser test that walks the whole journey of MVP.md section 3 against the real stack, including a restart of the stack between two steps |
| S5.3 | README: exact setup, seed and demo walkthrough; project status and roadmap updated |
| S5.4 | Verification of AC-01 to AC-15 on one revision of `main` with the required CI checks, recorded in MVP.md |

## Not in this backlog

Maintenance that does not block a slice is tracked outside the MVP (MVP.md
section 9). A security finding that fails a required check is fixed first,
in its own pull request.
