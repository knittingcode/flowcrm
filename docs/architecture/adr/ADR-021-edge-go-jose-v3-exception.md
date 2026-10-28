# ADR-021: Temporary exception for go-jose v3 in the edge Caddy binary

- **Status:** proposed (FCRM-SEC-042), **not accepted**. The owner decides.
  Until it is accepted, the exception in `security/trivyignore.yaml` must not
  reach `main`.
- **Related:** [container vulnerabilities](../../security/container-vulnerabilities.md)
  (exception policy, CVE-2026-116587 triage, edge configuration guard),
  ADR-017 (edge routing)

## Context

Trivy reports CVE-2026-116587 / GHSA-mgcc-cww5-fp2q (HIGH, CVSS 7.5,
CWE-407/770) in `usr/bin/caddy` of the edge images. go-jose parses the RSA
modulus and primes of a JWK without bounds before `crypto/rsa` validation,
so a crafted key costs cubic CPU time: a denial of service, with no impact
on confidentiality or integrity.

| Module | Version | Fixed in | Handling |
|---|---|---|---|
| `github.com/go-jose/go-jose/v4` | 4.1.6 | 4.1.6 | upgraded (was 4.1.5); not excepted |
| `github.com/go-jose/go-jose/v3` | 3.0.5 | no fixed release (3.0.5 is the newest v3) | this decision |

go-jose v3 cannot be removed today:

- `modules/caddytls` (internal issuer, CA pools) and
  `caddyconfig/httpcaddyfile` import `modules/caddypki`, and
  `modules/caddyhttp` imports `caddytls`. Every Caddy build with the HTTP
  app therefore links `caddypki` → `smallstep/certificates/authority` →
  `go.step.sm/crypto/jose` → go-jose v3. A build from the
  `modules/standard` list without `caddypki` still contains v3 3.0.5.
- The newest releases still require v3: Caddy 2.11.7,
  `smallstep/certificates` 0.30.2 and `go.step.sm/crypto` 0.91.1. The move
  of `smallstep/crypto` to go-jose v4 is open as smallstep/crypto#1157 and
  needs a `smallstep/certificates` release on top.
- go-jose v3 receives only critical security updates, and no backport of
  the fix exists.

Reachability in FlowCRM:

- **Caddy code:** only Caddy's `acme_server` handler passes untrusted input
  to the vulnerable parser. It parses the JWS of an unauthenticated ACME
  request before any check. `tls internal` and the `pki` app parse only
  keys that Caddy creates or loads from its own configuration, and Caddy's
  ACME client does not link go-jose.
- **FlowCRM's configuration:** no edge configuration uses `acme_server`, a
  `pki` app, `tls internal`, `local_certs` or an issuer. Both Caddyfiles set
  `admin off`, `auto_https off` and `persist_config off`, and the HTTPS test
  edge loads a static certificate.
- **Runtime check:** the advisory's proof of concept (a JWK with a
  16384-bit RSA prime) got a 404 from every HTTPS test edge port, using
  about 0 s of CPU. With `acme_server` enabled, one unauthenticated request
  cost about 2.2 s of CPU.

The runtime gate (`tests/app/scan.sh`) fails on every HIGH or CRITICAL
finding, so this finding blocks every pull request and `main`.

## Decision (proposed)

1. Upgrade go-jose v4 to 4.1.6 (PR #41). v4 gets no exception.
2. Add one temporary exception to `security/trivyignore.yaml` that matches
   only this finding:

   ```yaml
   - id: CVE-2026-116587
     paths: ["usr/bin/caddy"]
     purls: ["pkg:golang/github.com/go-jose/go-jose/v3@v3.0.5"]
     expired_at: 2026-11-30
   ```

   Trivy applies an entry only when the id, path and purl all match. The
   pinned Trivy 0.67.2 was run on real images to check this:
   - the v4 4.1.5 finding still fails the gate;
   - a v3 3.0.4 build still fails it;
   - the control scan keeps its 28 HIGH and CRITICAL findings;
   - api-prod and db suppress nothing;
   - with an expiry in the past, the finding blocks again.
3. Compensating controls, which land in the same change as the exception:
   - **Edge configuration guard**, `scripts/ci/guard-edge-config.sh` in the
     `Repository guard` job. It parses every tracked Caddy file like Caddy
     does, including imports, import globs and snippets, and every place
     that starts Caddy. It rejects:
     - `acme_server`, `pki`, issuers, `tls internal`, `local_certs` and
       other ACME options, in every Caddy file and in every file copied or
       mounted into `/etc/caddy`, whatever its name;
     - a global block other than exactly `admin off`, `auto_https off` and
       `persist_config off`;
     - environment placeholders;
     - `--resume` and `--watch`;
     - other configuration files, and `CADDY_ADMIN`;
     - edge service commands in Compose other than the exact `caddy run`
       form, entrypoints, YAML escapes, and mounts over `/etc` or the
       binary;
     - edge Dockerfile stages that could link, copy or rename the binary.

     Unknown Caddyfile constructs fail. Shell, YAML and Dockerfile text is
     read line by line. The guard catches ordinary and accidental changes,
     but not a deliberate evasion assembled at run time (see Consequences).
   - **Adapted-configuration check**, in `tests/app/scan.sh`. It runs
     `caddy adapt` with the built binary in the built edge images and on
     the HTTPS test edge, and checks the JSON: the admin API is disabled,
     there is no `pki` app, no TLS automation or issuer and no
     `acme_server` handler, automatic HTTPS is off and persistence is off.
     An unsafe control configuration must be rejected.
   - **Stricter exception guard**, `scripts/ci/guard-trivyignore.sh`. Every
     entry must name its path and exactly one package with an exactly
     pinned purl; no package may appear in two entries, and an id that the
     exceptions table lists as an alias (the GHSA id of this CVE) is
     rejected, because Trivy matches only the id it reports. An entry that
     expires on or before the check date fails the guard.
   - **Visibility:** the scan template prints the suppressed finding as
     `SUPPRESSED` in the edge-prod scan log. The edge `dev` report scan does not use the
     ignore file and keeps listing it.
4. The exception is listed in the exceptions table of the container
   vulnerability document, which states that it does not fix the vulnerable
   code.

## Consequences

- **The vulnerable code stays in the binary.** The exception only stops the
  gate from blocking on it.
- **Residual risk:** availability only. If a configuration enabled an ACME
  server, or a mutable admin API, a remote client could exhaust the edge's
  CPU. The edge has no CPU or memory limits, so the API and database on the
  same host could suffer too. An ordinary change that enables such a
  configuration fails the static guard. The adapted check also catches it
  when the change is in the built image. The checks do not see commands or
  paths assembled at run time (shell variables, `eval`, an `env_file` that
  sets `CADDY_ADMIN` or a `{$VAR}` value, `docker cp`). They do not see
  `docker run --entrypoint` with another executable in a script outside
  Compose, a Caddy plugin added to `docker/edge/caddy/main.go`, or what an
  `apk add` package installs. The adapted check does not apply Compose
  mounts. These remain review items: every change under `docker/edge`,
  `tests/app/https` or a Compose file is a review trigger below.
- **Expiry:** on 2026-11-30 Trivy stops applying the entry, and the
  exception guard fails the `Repository guard` job, so every pull request
  is blocked until the exception is renewed after a new review or removed.
  The maximum renewal under the policy is 90 days.
- **Review triggers.** The exception is reviewed early, and removed as soon
  as it is no longer needed, on any of:
  - a go-jose v3 release with the fix;
  - a `go.step.sm/crypto` and `smallstep/certificates` release on go-jose
    v4, or a Caddy release without v3;
  - the further go-jose v3 advisories GHSA-4w3g-jfj2-cw2q and
    GHSA-vvm8-gf78-28g4 reaching the advisory database;
  - a Go vulnerability database entry with affected symbols, for a
    govulncheck check;
  - a severity change;
  - any change under `docker/edge` or `tests/app/https`, to the edge
    service in a Compose file, or a new Caddy plugin;
  - a Trivy upgrade;
  - a deployment beyond the loopback-only development and test stacks.
- **Exit criteria:** go-jose v3 is gone from `go version -m usr/bin/caddy`,
  or replaced by a fixed version. The exception entry and its table row are
  then removed, and this ADR is superseded.
- **Operations:**
  - the edge configuration guard takes about 2 s, and its regression
    suite about 2.5 minutes, in the `Repository guard` job;
  - the adapted check adds seconds to the scan step;
  - a renewal is a reviewed change to `security/trivyignore.yaml` and the
    exceptions table.
- **Rollback:** revert the exception commit. The gate then fails on the
  finding again, and the guards stay in place.

## Alternatives considered

- **Wait for an upstream fix without an exception:** keeps the gate strict,
  but blocks every merge, including unrelated security fixes, for an
  unknown time.
- **A Caddy build without `caddypki`:** does not remove v3 (see Context).
- **A `replace` with a patched go-jose v3, or a Caddy fork:** a
  self-maintained fork of a cryptographic library or of Caddy's TLS stack,
  in the TLS edge. This is an architecture change, and it is not proposed.
- **An exception by id or by path only, a 90-day expiry, a report-only
  edge-prod scan, or a lower threshold:** rejected. They would also hide
  the fixable v4 finding, or weaken the runtime gate.
