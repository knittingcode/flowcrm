#!/bin/sh
# Docker health check of the API container: a FastCGI request for
# /health/live straight to PHP-FPM (no edge, no database).
set -eu
SCRIPT_NAME=/index.php SCRIPT_FILENAME=/app/public/index.php \
  REQUEST_METHOD=GET REQUEST_URI=/health/live QUERY_STRING='' \
  cgi-fcgi -bind -connect 127.0.0.1:9000 | grep -q '"status":"live"'
