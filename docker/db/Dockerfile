# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# FlowCRM db: PostgreSQL 18, run as the image's postgres user (uid 70).
# The container never starts as root, so the image's gosu (used only to drop
# from root to postgres) is never executed; it is removed because its Go
# runtime carries known vulnerabilities that no PostgreSQL image fixes yet.
# See docs/security/container-vulnerabilities.md.

ARG POSTGRES_IMAGE=postgres:18.6-alpine3.24@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873

FROM ${POSTGRES_IMAGE}
# brotli-libs >= 1.2.1-r0 fixes CVE-2026-111497 (HIGH), which the pinned base
# image still ships (docs/security/container-vulnerabilities.md).
RUN apk add --no-cache --upgrade 'brotli-libs>=1.2.1-r0' \
    && rm -f /usr/local/bin/gosu
# Database roles (ADR-018): created on a new volume by the initdb hook, and
# checked or upgraded by bin/devenv through flowcrm-db-roles.
COPY --chmod=0755 docker/db/flowcrm-db-roles /usr/local/bin/flowcrm-db-roles
COPY --chmod=0755 docker/db/initdb-roles.sh /docker-entrypoint-initdb.d/10-flowcrm-roles.sh
USER postgres
