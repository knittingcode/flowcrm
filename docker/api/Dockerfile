# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# FlowCRM API: Symfony 7.4 on PHP-FPM 8.5, running as www-data (uid 82).
# Build context: the repository root. Targets: dev (dev dependencies; the
# source comes from the read-only mounts of compose.yaml, so editing PHP code
# does not rebuild the image), test (dev plus the full source, for
# tests/app/backend.sh) and prod (no dev dependencies, code baked in).

ARG PHP_IMAGE=php:8.5.12-fpm-alpine3.24@sha256:c15690bd932bd6d33f43ccae6ddd8d60acb93cee50c16afc6e699265d5d86583
ARG COMPOSER_IMAGE=composer:2.9.7@sha256:02062f7719ec9433a9d4256cfba1c792db96dc9db60a4a92e48264c9e166b877

FROM ${COMPOSER_IMAGE} AS composer

FROM ${PHP_IMAGE} AS base
# brotli-libs >= 1.2.1-r0 fixes CVE-2026-111497 (HIGH), which the pinned base
# image still ships; remove once the base includes it
# (docs/security/container-vulnerabilities.md).
RUN apk add --no-cache --upgrade 'brotli-libs>=1.2.1-r0' \
    && apk add --no-cache fcgi postgresql-libs \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS postgresql-dev \
    && docker-php-ext-install -j"$(nproc)" pdo_pgsql \
    && apk del .build-deps
COPY docker/api/php-fpm.conf /usr/local/etc/php-fpm.d/zz-flowcrm.conf
COPY docker/api/php.ini "$PHP_INI_DIR/conf.d/zz-flowcrm.ini"
COPY --chmod=0755 docker/api/entrypoint.sh /usr/local/bin/flowcrm-entrypoint
COPY --chmod=0755 docker/api/healthcheck.sh /usr/local/bin/flowcrm-healthcheck
WORKDIR /app
RUN chown www-data:www-data /app
USER www-data
EXPOSE 9000
ENTRYPOINT ["flowcrm-entrypoint"]
CMD ["php-fpm", "--nodaemonize"]

FROM base AS dev
COPY --from=composer /usr/bin/composer /usr/local/bin/composer
ENV APP_ENV=dev COMPOSER_NO_INTERACTION=1
COPY --chown=www-data:www-data backend/composer.json backend/composer.lock backend/symfony.lock ./
RUN composer install --no-progress --no-scripts --prefer-dist
COPY --chown=www-data:www-data backend/bin ./bin
COPY --chown=www-data:www-data backend/.env ./
RUN composer dump-autoload --no-scripts

FROM dev AS test
COPY --chown=www-data:www-data backend/ ./
RUN composer dump-autoload --no-scripts

FROM base AS prod-vendor
COPY --from=composer /usr/bin/composer /usr/local/bin/composer
ENV COMPOSER_NO_INTERACTION=1
COPY --chown=www-data:www-data backend/composer.json backend/composer.lock backend/symfony.lock ./
RUN composer install --no-progress --no-scripts --prefer-dist --no-dev
COPY --chown=www-data:www-data backend/ ./
RUN composer dump-autoload --no-scripts --no-dev --classmap-authoritative \
    && rm -rf tests phpunit.dist.xml phpstan.dist.neon .php-cs-fixer.dist.php .env.test

FROM base AS prod
ENV APP_ENV=prod APP_DEBUG=0
COPY --from=prod-vendor --chown=www-data:www-data /app /app
