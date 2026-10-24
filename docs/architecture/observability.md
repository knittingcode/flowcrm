# Observability

Logging, request correlation and metrics of the foundation (FCRM-003
section Q). No external log, metrics or error-tracking service is used.

## Logs

Every service writes to stdout or stderr; Docker collects the output
(`make logs SERVICE=edge|web|api|db`).

### API (Symfony, Monolog)

One JSON object per line on stderr (`backend/config/packages/monolog.yaml`,
`App\Shared\Infrastructure\Logging\JsonLineFormatter`):

```json
{"ts":"2026-10-21T20:30:00.123Z","level":"info","channel":"http","message":"request completed","request_id":"0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c","context":{"method":"GET","route":"api_v1_system_status","status":200,"duration_ms":12.4}}
```

| Field | Content |
|---|---|
| `ts` | UTC, milliseconds |
| `level` | PSR-3 level (`debug` … `emergency`); handlers write `info` and above |
| `channel` | `http` (request records), `health` (readiness failures), `security` (logins, rejected requests, tenant denials; see [authentication](authentication.md#audit-events-and-security-log)), `request` and `php` (framework errors), `app` |
| `message` | placeholders filled in after redaction |
| `request_id` | the request's ID, `null` outside a request (for example console commands) |
| `context`, `extra` | remaining structured data, redacted |

Channels `event` and `doctrine` (per-query debug records) are not written.
PHP-FPM passes worker output through unchanged (`catch_workers_output`,
`decorate_workers_output = no`, `log_limit = 16384`, so records are not
split).

### Edge (Caddy)

JSON access log on stdout with the request, including the `X-Request-Id`
request header that the edge generated (`docker/edge/common.caddy`).

### Retention

The api and edge logs are short-lived diagnostics: Docker keeps at most 3
files of 10 MB per container (`compose.yaml`, `x-request-logs`) and removes
them with the container. Security records use pseudonyms instead of e-mail
and IP addresses; the edge's access log contains the client address. A
deployment must enforce equivalent limits in its log pipeline.

## Request IDs

1. The edge replaces any client-supplied `X-Request-Id` with a new UUID.
2. Symfony uses that ID if it is a valid UUID and generates a UUIDv7
   otherwise (`App\Shared\Http\RequestId`).
3. The ID is returned in the `X-Request-Id` response header, in every
   problem document (`requestId`), and in every log record written while
   the request runs (`App\Shared\Http\Logging\RequestIdProcessor`).

To follow one request:

```console
$ make logs SERVICE=api | grep 0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c
$ make logs SERVICE=edge | grep 0192f0c4-7d1e-7b8a-9f3c-2b4d6e8f0a1c
```

## Request records and metrics

`App\Shared\Http\Logging\RequestLogListener` writes one `request completed`
record per request on the `http` channel with `method`, `route` (the
Symfony route name, `null` when no route matched), `status` and
`duration_ms` (from the start of the PHP request to the response). Paths,
query strings, headers and bodies are not logged. Health checks are logged
at `debug` level and therefore not written, because the Compose health
checks call them every few seconds.

Metrics are derived from these records (FCRM-003: request counts, latency
and error rate from logs; no metrics endpoint in the MVP). For example, with
`jq`:

```console
$ make logs SERVICE=api | grep '^{' | jq -r 'select(.message == "request completed") | "\(.context.status) \(.context.route)"' | sort | uniq -c
$ make logs SERVICE=api | grep '^{' | jq -s '[.[] | select(.message == "request completed") | .context.duration_ms] | sort | .[(length * 0.95 | floor)]'
```

A Prometheus endpoint on the internal network remains a post-MVP option.

## Errors

- Exceptions are logged once, by Symfony's error listener, with the request
  ID: `critical` for unexpected errors and 5xx, `error` for other client
  errors, `info` for unknown routes (404) and wrong methods (405)
  (`framework.exceptions` in `backend/config/packages/framework.yaml`).
- The client receives an RFC 9457 problem document with the same
  `requestId` and no exception details.
- Readiness failures are logged on the `health` channel with the reason;
  `/health/ready` itself only answers `not-ready`.

## Redaction

`App\Shared\Infrastructure\Logging\LogRedactor`, applied by the formatter
to every record:

| Data | Treatment |
|---|---|
| Values under the keys `password`, `passwd`, `pwd`, `secret`, `token`, `csrf`, `authorization`, `cookie`, `set-cookie`, `session`, `sid`, `sess_id`, `sess_data`, `api_key`, `apikey`, `email`, `phone`, `first_name`, `last_name`, `display_name` (any case), keys containing `password`, `secret`, `token`, `csrf`, `cookie`, `session`, `sessid` or `authorization`, and keys ending in `_sid` or `-sid` (the session cookie names `flowcrm_sid`, `__Host-flowcrm_sid`) | replaced by `[redacted]`, at any depth |
| `key=value` or `key: value` text with such a key, `Bearer`/`Basic` credentials, passwords in URLs (`scheme://user:password@`) | value replaced by `[redacted]` in messages and strings |
| The query and fragment of a URL (`scheme://…`) written into messages and strings, for example the `Referer` that the framework quotes for an unknown route (`No route found … (from "…")`) | replaced by `?[redacted]`; the scheme, host and path are kept |
| Values under the URL keys `request_uri`, `uri`, `url`, `referer`, `referrer`, `redirect_uri`, `location`, `target_path`, `href`, `return_to` (any case), relative or absolute | query and fragment replaced by `?[redacted]`; the path (and scheme and host) is kept |
| Messages of database errors (DBAL exceptions, driver exceptions, `PDOException`) | replaced by `database error (SQLSTATE …)`: PostgreSQL error details can quote row values |
| Objects other than exceptions | logged as their type only |

The edge access log does not contain `Cookie`, `Set-Cookie`,
`Authorization` or `Proxy-Authorization` values (Caddy's default), the
`X-Csrf-Token` header, or query strings (`?[redacted]`, also in `Referer`).

Redaction is a safety net, not a licence: code must not log request bodies,
credentials or contact data in the first place.

## Database visibility

Queries are not logged (the `doctrine` channel is excluded): per-query
records would expose parameters and add volume without a current need.
Database availability is visible through `/health/ready` and the `health`
channel, and slow requests through `duration_ms`.

## Tests

| Test | Proves |
|---|---|
| `backend/tests/Unit/Shared/Infrastructure/Logging/JsonLineFormatterTest.php` | record shape, redaction of every class above, placeholders after redaction, database error messages reduced to SQLSTATE |
| `backend/tests/Unit/Shared/Http/Logging/RequestLoggingTest.php` | request ID processor, request record fields, no path, query or headers, health at debug |
| `backend/tests/Unit/Shared/Infrastructure/Logging/JsonLineFormatterTest.php` (URLs) | the query string of a URL value (`request_uri`, `uri`, `url`, `referer`, `referrer`, `redirect_uri`, `location`, `target_path`, `href`, `return_to`), such as the router's "Matched route" record, becomes `?[redacted]` |
| `backend/tests/Unit/Shared/Infrastructure/Logging/JsonLineFormatterTest.php` (URLs in text) | the query and fragment of URLs in messages and context strings (one or several URLs) become `?[redacted]`; a URL without a query is kept |
| `backend/tests/Integration/Shared/LoggingTest.php` | the configured pipeline on the booted kernel: request and error records share the response's request ID; a database error is logged without its data and correlates with the problem document; the query of the `Referer` of an unknown route is not logged |
| `tests/app/stack.sh` ST-40 to ST-43 | on the running stack: the api record and the edge access log carry the response's request ID; every api JSON line is complete; query, `Authorization`, `Cookie` and CSRF values appear in no log |
