# No security gate

Mounted into the edge at `/run/flowcrm-gate` when no gate directory is
given (`FLOWCRM_GATE_DIR` unset): the production-like and test stacks,
which are not run by `bin/devenv`. It must never contain a file named
`security-gate`. `bin/devenv` mounts `.runtime/gate` instead, where it
records the security gate (docs/architecture/adr/ADR-018-database-roles.md).
