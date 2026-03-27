#!/usr/bin/env bash
# ns — command dispatcher for Nightscout Docker tooling.
# Sourced from ../ns; NS_ROOT must be set to the directory containing ns.

ns_help() {
    cat << 'EOF'
Nightscout CLI — one entrypoint for scripts in this repository.

Usage:
  ns <command> [arguments...]
  ns help | -h | --help

Run from:
  • Repository root (full toolset), or
  • An instance directory (e.g. /opt/nightscout/alice/) after migrate/copy.

Core
  setup              Initial .env and secrets (see: ./setup.sh --help)
  migrate            Create instance / migrate data (./migrate-instance.sh)
  validate           Config + Docker health (./validate.sh)
  validate-db        MongoDB connection / naming (./validate-database.sh)
  validate-migration Post-migration checks (./validate-migration.sh) [repo]
  backup             MongoDB backup (./backup.sh)
  cleanup            Remove THIS instance — destructive (./cleanup.sh)
  list               All instances, ports, health (./list-instances.sh)
  diagnose           Host + Docker diagnostics (./diagnose.sh)

Cloudflare
  tunnel             Tunnel install + config (./setup-cloudflare.sh)
  debug-tunnel       Tunnel diagnostics (./debug-tunnel.sh)
  fix-tunnel         Quick tunnel fixes (./fix-tunnel.sh)
  cleanup-tunnels    Delete unused tunnels (./cleanup-tunnels.sh)

MongoDB / migration
  upgrade-mongo      Stepped version upgrade (./upgrade-mongodb.sh)
  atlas              Atlas → self-hosted wizard (./setup-atlas-migration.sh) [repo]
  export-atlas       mongodump from Atlas (./export-atlas-db.sh) [repo]
  import-vm          mongorestore helper (./import-to-vm.sh) [repo]

Other
  transfer-cert      Cloudflare cert transfer (./transfer-cloudflare-cert.sh) [repo]
  check              Run bash -n on all *.sh under this tree (maintenance)

Docker (run inside an instance directory)
  docker compose up -d
  docker compose logs -f
  docker compose ps

[repo] = only in a full git checkout; use repository root or clone if missing.

Legacy invocations (./setup.sh, ./validate.sh, …) still work unchanged.
EOF
}

# Resolve script filename for a command name (empty if unknown).
ns_cmd_to_script() {
    case "$1" in
        setup) echo "setup.sh" ;;
        migrate) echo "migrate-instance.sh" ;;
        validate) echo "validate.sh" ;;
        validate-db) echo "validate-database.sh" ;;
        validate-migration) echo "validate-migration.sh" ;;
        backup) echo "backup.sh" ;;
        cleanup) echo "cleanup.sh" ;;
        list) echo "list-instances.sh" ;;
        diagnose) echo "diagnose.sh" ;;
        tunnel|cloudflare) echo "setup-cloudflare.sh" ;;
        debug-tunnel) echo "debug-tunnel.sh" ;;
        fix-tunnel) echo "fix-tunnel.sh" ;;
        cleanup-tunnels) echo "cleanup-tunnels.sh" ;;
        upgrade-mongo) echo "upgrade-mongodb.sh" ;;
        atlas) echo "setup-atlas-migration.sh" ;;
        export-atlas) echo "export-atlas-db.sh" ;;
        import-vm) echo "import-to-vm.sh" ;;
        transfer-cert) echo "transfer-cloudflare-cert.sh" ;;
        check) echo "__check__" ;;
        *) return 1 ;;
    esac
}

ns_run_check() {
    local f failed=0
    shopt -s nullglob
    if [ -f "$NS_ROOT/ns" ]; then
        if ! bash -n "$NS_ROOT/ns" 2>/dev/null; then
            echo "✗ bash -n failed: $NS_ROOT/ns" >&2
            bash -n "$NS_ROOT/ns" 2>&1 | sed "s/^/  /" >&2 || true
            failed=1
        else
            echo "✓ $NS_ROOT/ns"
        fi
    fi
    for f in "$NS_ROOT"/*.sh "$NS_ROOT"/lib/*.sh; do
        [ -f "$f" ] || continue
        if ! bash -n "$f" 2>/dev/null; then
            echo "✗ bash -n failed: $f" >&2
            bash -n "$f" 2>&1 | sed "s/^/  /" >&2 || true
            failed=1
        else
            echo "✓ $f"
        fi
    done
    return "$failed"
}

ns_main() {
    local cmd="${1:-}"
    [ -n "$cmd" ] && shift
    case "$cmd" in
        ""|-h|--help|help)
            ns_help
            return 0
            ;;
    esac

    local script_name
    script_name=$(ns_cmd_to_script "$cmd") || {
        echo "ns: unknown command: $cmd" >&2
        echo "Run: ns help" >&2
        return 1
    }

    if [ "$script_name" = "__check__" ]; then
        ns_run_check
        return $?
    fi

    local path="$NS_ROOT/$script_name"
    if [ ! -f "$path" ]; then
        echo "ns: script not found: $path" >&2
        echo "This command may only exist in a full repository checkout." >&2
        echo "Clone the repo or run ns from the repo root." >&2
        return 1
    fi

    exec bash "$path" "$@"
}
