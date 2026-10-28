# Checks the JSON that `caddy adapt` makes of an edge configuration (used by
# tests/app/scan.sh on the built images; regression cases in
# scripts/ci/tests/guard-edge-config.test.sh). Prints one line per
# violation and nothing when the configuration keeps the admin API, config
# persistence, the PKI app, certificate issuers, ACME and the acme_server
# handler off (docs/security/container-vulnerabilities.md, edge
# configuration guard).
#
# Usage: jq -r -f scripts/ci/edge-adapted-config.jq <adapted.json>

def extra($allowed): if type == "object" then keys - $allowed else [] end;
def issuer_module: . == "acme" or . == "internal" or . == "zerossl";

if type != "object" then
  "the adapted configuration is not a JSON object"
else
  . as $c
  | (extra(["admin", "apps", "logging"]) | select(length > 0)
      | "top-level settings other than admin, apps and logging: \(join(", "))"),
    (if $c.admin.disabled != true then "admin.disabled is not true: the admin API is enabled" else empty end),
    ($c.admin | extra(["disabled", "config"]) | select(length > 0)
      | "admin has other settings: \(join(", "))"),
    (if $c.admin.config.persist != false then "admin.config.persist is not false: persist_config is not off" else empty end),
    ($c.admin.config | extra(["persist"]) | select(length > 0)
      | "admin.config has other settings (load could fetch a configuration): \(join(", "))"),
    (if $c.apps.pki != null then "apps.pki is configured: PKI app" else empty end),
    ($c.apps | extra(["http", "tls"]) | select(length > 0)
      | "apps other than http and tls: \(join(", "))"),
    (if $c.apps.tls.automation != null then
      "apps.tls.automation is configured (issuer modules: \([$c.apps.tls.automation | .. | objects | .module? | strings] | unique | join(", ")))"
    else empty end),
    ($c.apps.tls | extra(["certificates"]) | select(length > 0)
      | "apps.tls has settings other than certificates: \(join(", "))"),
    ($c.apps.tls.certificates | extra(["load_files"]) | select(length > 0)
      | "apps.tls.certificates other than load_files: \(join(", "))"),
    ([$c | .. | objects | select(.handler? == "acme_server")] | length | select(. > 0)
      | "acme_server handler found (\(.)x): parses unauthenticated JWS with go-jose"),
    ([$c | .. | objects | .module? | strings | select(issuer_module)] | unique | select(length > 0)
      | "issuer modules found: \(join(", "))"),
    ([$c | paths | .[-1] | strings | select(. == "issuers" or . == "issuer" or . == "on_demand" or . == "get_certificate")]
      | unique | select(length > 0) | "certificate issuance settings found: \(join(", "))"),
    (if ($c.apps.http.servers | type) != "object" or ($c.apps.http.servers | length) == 0 then
      "no apps.http.servers"
    else
      $c.apps.http.servers | to_entries[] | select(.value.automatic_https.disable != true)
      | "apps.http.servers.\(.key).automatic_https.disable is not true: automatic HTTPS (ACME) is on"
    end)
end
