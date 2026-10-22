# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# FlowCRM edge: Caddy 2, the only service with a published host port.
# Targets: dev (proxies the Vite dev server) and prod (serves the built SPA).
# Build context: the repository root.

ARG CADDY_IMAGE=caddy:2.11.7-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f
ARG GO_IMAGE=golang:1.26.10-alpine3.24@sha256:9ce231b28998b32e116927c61aa5c406183061d4f3f2d61b292c88e7f6bdf7ca
ARG NODE_IMAGE=node:24.22.1-alpine3.24@sha256:6a1c190e17215d844926b0677f4bf87273ff7d5e54db06d3b5b5863ab0b09a3d

# Caddy 2.11.7 rebuilt from the upstream module with a patched Go toolchain
# and patched dependencies (docker/edge/caddy/go.mod, verified by go.sum);
# the released binary (Go 1.26.8, x/net 0.59.0) contains vulnerable versions
# that no Caddy release fixes yet. See docs/security/container-vulnerabilities.md.
FROM ${GO_IMAGE} AS caddy-build
ENV CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS=-mod=readonly
WORKDIR /src
COPY docker/edge/caddy/go.mod docker/edge/caddy/go.sum ./
RUN go mod download
COPY docker/edge/caddy/main.go ./
RUN go build -trimpath -ldflags "-s -w" -o /out/caddy . && /out/caddy version

FROM ${CADDY_IMAGE} AS caddy-base
# The rebuilt binary has no file capabilities: port 8080 needs none, and a
# container without capabilities could not exec a binary that requests one.
COPY --from=caddy-build /out/caddy /usr/bin/caddy
# Unprivileged user; Caddy keeps its data and config on tmpfs.
ENV XDG_DATA_HOME=/tmp/caddy/data XDG_CONFIG_HOME=/tmp/caddy/config
COPY docker/edge/common.caddy /etc/caddy/common.caddy
USER 65534:65534
EXPOSE 8080

FROM caddy-base AS dev
COPY docker/edge/Caddyfile.dev /etc/caddy/Caddyfile

FROM ${NODE_IMAGE} AS spa-build
WORKDIR /app
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

FROM caddy-base AS prod
COPY docker/edge/Caddyfile.prod /etc/caddy/Caddyfile
COPY --from=spa-build /app/dist /srv/www
