#!/bin/sh
# Initialises the database roles of a new volume (docker-entrypoint-initdb.d).
# The PostgreSQL entrypoint runs this once, when the data directory is empty.
set -eu
exec /usr/local/bin/flowcrm-db-roles init
