# syntax=docker/dockerfile:1
# FlowCRM edge: Caddy 2, the only service with a published host port.
# Targets: dev (proxies the Vite dev server) and prod (serves the built SPA).
# Build context: the repository root.

ARG CADDY_IMAGE=caddy:2.11.4-alpine@sha256:6aeddd44c3078b0f9a35206472a11420648a79c184603ef95957d0a20044cb2b
ARG NODE_IMAGE=node:24.20.0-alpine3.24@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf

FROM ${CADDY_IMAGE} AS caddy-base
# Port 8080 needs no privileges: drop the binary's cap_net_bind_service file
# capability, which a container without capabilities could not exec.
RUN setcap -r /usr/bin/caddy
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
