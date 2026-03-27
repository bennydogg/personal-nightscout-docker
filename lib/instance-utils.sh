#!/bin/bash
# Shared utilities for discovering and inspecting Nightscout instances.
# Source this file from other scripts: source "$(dirname "$0")/lib/instance-utils.sh"

# Default base directory for multi-instance deployments
NIGHTSCOUT_BASE_DIR="${NIGHTSCOUT_BASE_DIR:-/opt/nightscout}"

# Invoke Docker Compose (v1 standalone binary or v2 plugin).
docker_compose() {
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    elif docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        echo "docker compose is not available (install docker-compose or the docker compose plugin)" >&2
        return 127
    fi
}

# Read KEY=value from a file; value may contain '=' (e.g. base64 secrets).
env_var_value() {
    local key="$1" file="${2:-.env}"
    grep "^${key}=" "$file" 2>/dev/null | head -1 | sed "s/^${key}=//"
}

# Colors (safe to re-source; these are just variable assignments)
_IU_RED='\033[0;31m'
_IU_GREEN='\033[0;32m'
_IU_YELLOW='\033[1;33m'
_IU_BLUE='\033[0;34m'
_IU_DIM='\033[2m'
_IU_NC='\033[0m'

# ---------------------------------------------------------------------------
# discover_instances
#
# Finds all Nightscout instances by scanning:
#   1. Instance directories under $NIGHTSCOUT_BASE_DIR
#   2. Running Docker containers whose compose labels match nightscout projects
#   3. Actual port bindings on the host
#
# Outputs one line per instance (tab-separated):
#   NAME  DIR  HOST_PORT  DOMAIN  CONTAINER_STATUS  MONGO_STATUS  HEALTH
#
# Container/Mongo status: "running", "stopped", "missing"
# Health: "healthy", "unhealthy", "starting", "unknown", "n/a"
# ---------------------------------------------------------------------------
discover_instances() {
    local seen_dirs=()

    # --- Pass 1: Scan instance directories ---
    if [ -d "$NIGHTSCOUT_BASE_DIR" ]; then
        for dir in "$NIGHTSCOUT_BASE_DIR"/*/; do
            [ -f "$dir/docker-compose.yml" ] || continue
            [ -f "$dir/.env" ] || continue
            _emit_instance_info "$dir"
            seen_dirs+=("$(cd "$dir" && pwd)")
        done
    fi

    # --- Pass 2: Find running nightscout containers not in known dirs ---
    # Use process substitution so the loop runs in this shell (seen_dirs works).
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        while read -r cdir; do
            [ -n "$cdir" ] || continue
            local already=false
            for s in "${seen_dirs[@]}"; do
                if [ "$s" = "$cdir" ]; then already=true; break; fi
            done
            $already && continue
            if [ -f "$cdir/docker-compose.yml" ]; then
                _emit_instance_info "$cdir"
            fi
        done < <(docker ps -a --filter "label=com.docker.compose.service=nightscout" \
            --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | sort -u)
    fi
}

# Internal: emit info for one instance directory
_emit_instance_info() {
    local dir="$1"
    local name host_port domain container_status mongo_status health

    name=$(basename "$dir")

    # Read config from .env (values may contain '=')
    host_port=$(env_var_value HOST_PORT "$dir/.env")
    host_port=${host_port:-8080}
    domain=$(env_var_value CLOUDFLARE_DOMAIN "$dir/.env")
    domain=${domain:--}

    # Check container status via compose
    local ns_id mongo_id
    ns_id=$(cd "$dir" && docker_compose ps -q nightscout 2>/dev/null)
    mongo_id=$(cd "$dir" && docker_compose ps -q mongo 2>/dev/null)

    if [ -n "$ns_id" ] && docker ps -q --filter "id=$ns_id" 2>/dev/null | grep -q .; then
        container_status="running"
        health=$(docker inspect "$ns_id" --format='{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
    elif [ -n "$ns_id" ]; then
        container_status="stopped"
        health="n/a"
    else
        container_status="missing"
        health="n/a"
    fi

    if [ -n "$mongo_id" ] && docker ps -q --filter "id=$mongo_id" 2>/dev/null | grep -q .; then
        mongo_status="running"
    elif [ -n "$mongo_id" ]; then
        mongo_status="stopped"
    else
        mongo_status="missing"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$dir" "$host_port" "$domain" "$container_status" "$mongo_status" "$health"
}

# ---------------------------------------------------------------------------
# print_instance_table
#
# Calls discover_instances and formats output as a human-readable table.
# ---------------------------------------------------------------------------
print_instance_table() {
    local instances
    instances=$(discover_instances)

    if [ -z "$instances" ]; then
        echo -e "${_IU_YELLOW}No Nightscout instances found.${_IU_NC}"
        echo "  Searched: $NIGHTSCOUT_BASE_DIR/*/"
        echo "  Also checked running Docker containers."
        return 1
    fi

    # Header
    printf "${_IU_DIM}%-14s %-7s %-30s %-10s %-10s %-10s${_IU_NC}\n" \
        "INSTANCE" "PORT" "DOMAIN" "APP" "MONGO" "HEALTH"
    echo "------------- ------- ------------------------------ ---------- ---------- ----------"

    echo "$instances" | while IFS=$'\t' read -r name dir port domain app_status mongo_status health; do
        # Color-code statuses
        local app_col mongo_col health_col
        case "$app_status" in
            running) app_col="${_IU_GREEN}running${_IU_NC}" ;;
            stopped) app_col="${_IU_RED}stopped${_IU_NC}" ;;
            *)       app_col="${_IU_YELLOW}missing${_IU_NC}" ;;
        esac
        case "$mongo_status" in
            running) mongo_col="${_IU_GREEN}running${_IU_NC}" ;;
            stopped) mongo_col="${_IU_RED}stopped${_IU_NC}" ;;
            *)       mongo_col="${_IU_YELLOW}missing${_IU_NC}" ;;
        esac
        case "$health" in
            healthy)   health_col="${_IU_GREEN}healthy${_IU_NC}" ;;
            unhealthy) health_col="${_IU_RED}unhealthy${_IU_NC}" ;;
            starting)  health_col="${_IU_YELLOW}starting${_IU_NC}" ;;
            *)         health_col="${_IU_DIM}${health}${_IU_NC}" ;;
        esac

        # printf with ANSI needs wider field widths to compensate for escape codes
        printf "%-14s %-7s %-30s %-21b %-21b %-21b\n" \
            "$name" "$port" "$domain" "$app_col" "$mongo_col" "$health_col"
    done
}

# ---------------------------------------------------------------------------
# check_port_available PORT [EXCLUDE_INSTANCE_NAME]
#
# Returns 0 if the port is available, 1 if in use.
# Checks both instance configs AND actual network bindings.
# Prints a message if the port is taken.
# ---------------------------------------------------------------------------
check_port_available() {
    local port="$1"
    local exclude="${2:-}"

    # Check config files
    if [ -d "$NIGHTSCOUT_BASE_DIR" ]; then
        for dir in "$NIGHTSCOUT_BASE_DIR"/*/; do
            [ -f "$dir/.env" ] || continue
            local ep en
            ep=$(env_var_value HOST_PORT "$dir/.env")
            en=$(basename "$dir")
            if [ "$ep" = "$port" ] && [ "$en" != "$exclude" ]; then
                echo "Port $port is configured by instance '$en' ($dir)"
                return 1
            fi
        done
    fi

    # Check actual network binding (skip if it matches our own excluded instance)
    local binding_check=false
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q ":${port} " && binding_check=true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q ":${port} " && binding_check=true
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:${port} -sTCP:LISTEN >/dev/null 2>&1 && binding_check=true
    fi

    if $binding_check; then
        # If we have an exclude name, check if it's our own instance binding the port
        if [ -n "$exclude" ] && [ -d "$NIGHTSCOUT_BASE_DIR/$exclude" ]; then
            local own_ns_id
            own_ns_id=$(cd "$NIGHTSCOUT_BASE_DIR/$exclude" && docker_compose ps -q nightscout 2>/dev/null)
            if [ -n "$own_ns_id" ] && docker ps -q --filter "id=$own_ns_id" 2>/dev/null | grep -q .; then
                # It's our own instance, that's fine
                return 0
            fi
        fi
        echo "Port $port is already bound on the host (check: ss -tlnp | grep :$port)"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# get_cloudflare_ingress
#
# Reads ~/.cloudflared/config.yml and prints the ingress rules.
# Returns 1 if no config found.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# mongo_shell CONTAINER [ARGS...]
#
# Executes the appropriate MongoDB shell (mongosh or legacy mongo) inside
# a container. Auto-detects which is available so scripts work across
# MongoDB 4.4 through 7.0.
# ---------------------------------------------------------------------------
mongo_shell() {
    local container="$1"; shift
    if docker exec "$container" mongosh --version >/dev/null 2>&1; then
        docker exec "$container" mongosh "$@"
    else
        docker exec "$container" mongo "$@"
    fi
}

# ---------------------------------------------------------------------------
# mongo_shell_compose [ARGS...]
#
# Same as mongo_shell but resolves the container via docker-compose.
# Must be called from a directory with docker-compose.yml.
# ---------------------------------------------------------------------------
mongo_shell_compose() {
    local mongo_container
    mongo_container=$(docker_compose ps -q mongo 2>/dev/null)
    if [ -z "$mongo_container" ]; then
        echo "MongoDB container not found" >&2
        return 1
    fi
    mongo_shell "$mongo_container" "$@"
}

# ---------------------------------------------------------------------------
get_cloudflare_ingress() {
    local config="${HOME}/.cloudflared/config.yml"
    if [ ! -f "$config" ]; then
        echo "No Cloudflare tunnel config found at $config"
        return 1
    fi

    echo "Cloudflare tunnel ingress rules ($config):"
    # Extract hostname and service lines from ingress block
    awk '/^ingress:/,0 { print }' "$config" | grep -E '^\s+- (hostname|service):' | while read -r line; do
        echo "  $line"
    done
}
