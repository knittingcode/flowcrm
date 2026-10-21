# syntax=docker/dockerfile:1
# FlowCRM db: PostgreSQL 18, run as the image's postgres user (uid 70).
# The container never starts as root, so the image's gosu (used only to drop
# from root to postgres) is never executed; it is removed because its Go
# runtime carries known vulnerabilities that no PostgreSQL image fixes yet.
# See docs/security/container-vulnerabilities.md.

ARG POSTGRES_IMAGE=postgres:18.6-alpine3.24@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873

FROM ${POSTGRES_IMAGE}
RUN rm -f /usr/local/bin/gosu
USER postgres
