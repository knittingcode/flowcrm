# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# FlowCRM db: PostgreSQL 18, run as the image's postgres user (uid 70).
# The container never starts as root, so the image's gosu (used only to drop
# from root to postgres) is never executed; it is removed because its Go
# runtime carries known vulnerabilities that no PostgreSQL image fixes yet.
# See docs/security/container-vulnerabilities.md.

ARG POSTGRES_IMAGE=postgres:18.6-alpine3.24@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873

FROM ${POSTGRES_IMAGE}
# brotli-libs >= 1.2.1-r0 fixes CVE-2026-111497 (HIGH) and libcurl
# >= 8.23.0-r0 fixes CVE-2026-92392 (HIGH), which the pinned base image still
# ships (docs/security/container-vulnerabilities.md). The base image has
# libcurl but no curl tool, so only the library is upgraded. musl/musl-utils
# >= 1.2.6-r3 fix CVE-2026-107891, krb5-libs >= 1.22.3-r0 and libxslt
# >= 1.1.43-r4 the HIGH findings listed there under "Runtime image packages
# (2026-11-16)".
RUN apk add --no-cache --upgrade 'brotli-libs>=1.2.1-r0' 'libcurl>=8.23.0-r0' \
        'musl>=1.2.6-r3' 'musl-utils>=1.2.6-r3' 'krb5-libs>=1.22.3-r0' 'libxslt>=1.1.43-r4' \
    && rm -f /usr/local/bin/gosu
# Database roles (ADR-018): created on a new volume by the initdb hook, and
# checked or upgraded by bin/devenv through flowcrm-db-roles.
COPY --chmod=0755 docker/db/flowcrm-db-roles /usr/local/bin/flowcrm-db-roles
COPY --chmod=0755 docker/db/initdb-roles.sh /docker-entrypoint-initdb.d/10-flowcrm-roles.sh
USER postgres
