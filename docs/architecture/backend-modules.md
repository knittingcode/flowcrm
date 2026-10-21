# Backend modules and layers

The backend is a modular monolith (FCRM-003 section E, ADR-001). This page
lists the rules and how they are enforced.

## Modules

| Module | Responsibility | Status |
|---|---|---|
| `Identity` | users, password hashing, login, sessions, `/me` | planned |
| `Organizations` | organizations, memberships, roles, tenant resolution | planned |
| `CRM` | accounts, contacts | planned |
| `Sales` | pipelines, stages, opportunities | planned |
| `Activities` | tasks | planned |
| `Reporting` | dashboard queries; no tables of its own | planned |
| `Audit` | audit writer and queries | planned |
| `Shared` | small cross-cutting code: health checks, API status, problem details, request IDs; later `Clock`, UUIDv7 and `Money` | implemented |

The planned modules exist only as rules in `backend/deptrac.modules.yaml`;
their namespaces are created by the tasks that implement them. No
placeholder classes are added.

Rules (`backend/deptrac.modules.yaml`):

- A module may depend on its own classes, on the public `App\<Module>\Api`
  namespace of every other module, and on `Shared`.
- An `Api` namespace may depend only on `Shared`: it exposes interfaces and
  value types, not the module's internals or another module's Api.
- `Shared` depends on no module.

## Layers

Every class lives in `src/<Module>/<Layer>/`, with the layers `Api`,
`Domain`, `Application`, `Infrastructure` and `Http`; only `src/Kernel.php`
sits at the root.

| Layer | May depend on | Must not use |
|---|---|---|
| `Domain` | nothing else in the application | framework HTTP (`Symfony\Component\HttpFoundation`, `HttpKernel`, `Routing`, `Form`, `Security`, `Symfony\Bundle`); Doctrine except the mapping attributes (`Doctrine\ORM\Mapping`), `Doctrine\DBAL\Types\Types` and `Doctrine\Common\Collections` |
| `Api` | `Domain` (identifiers and value objects) | framework HTTP, persistence |
| `Application` | `Domain`, `Api` | framework HTTP, persistence |
| `Infrastructure` | `Domain`, `Application`, `Api`, framework HTTP, Doctrine | — |
| `Http` | `Domain`, `Application`, `Api`, framework HTTP | `Infrastructure`, Doctrine |

Rules: `backend/deptrac.layers.yaml`. Doctrine mapping attributes in the
Domain are an accepted trade-off (FCRM-003 section E). Libraries that are
not listed (for example `Psr\Log` or `Symfony\Component\Uid`) are not
restricted.

Two configurations are used, because Deptrac reports dependencies inside one
layer as violations when a class belongs to two layers of one
configuration.

## Enforcement

`tests/app/backend.sh` runs, in the required `Dev environment` CI job:

| Check | What fails it |
|---|---|
| BE-11 `deptrac analyse --config-file=deptrac.modules.yaml` | a forbidden dependency between modules |
| BE-12 `deptrac analyse --config-file=deptrac.layers.yaml` | a forbidden dependency between layers or on framework HTTP or persistence code |
| BE-13 PHPUnit suite `architecture` (`backend/tests/Architecture`) | a rule that no longer rejects its forbidden case or rejects an allowed one; a source file outside `src/<Module>/<Layer>/`; any violation in the application |

The architecture suite writes small source trees to a temporary directory
and runs Deptrac with the project's configurations on them: one case per
forbidden dependency (for example Domain → Infrastructure, Domain →
`Doctrine\ORM\EntityManagerInterface`, Http → Infrastructure, Http →
`Doctrine\DBAL\Connection`, a module → another module's Domain, Shared → a
module) and allowed cases (Http → Application → Domain, a module → another
module's Api, Doctrine mapping attributes in the Domain).

There are no exceptions and no Deptrac baseline. A new exception needs a
written justification in this file.

Deptrac is a development dependency (`deptrac/deptrac` 4.7.2, pinned in
`backend/composer.json`) and is not part of the production image.

## Run locally

```console
$ tests/app/backend.sh
```
