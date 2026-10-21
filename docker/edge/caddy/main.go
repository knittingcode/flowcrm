// Caddy 2 with its standard modules, built from the upstream release so the
// Go toolchain and module versions can include security fixes before a new
// Caddy release does (see docs/security/container-vulnerabilities.md).
package main

import (
	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	_ "github.com/caddyserver/caddy/v2/modules/standard"
)

func main() {
	caddycmd.Main()
}
