#!/bin/bash

# List all Nightscout instances, their status, and Cloudflare tunnel config.
#
# Usage:
#   ./list-instances.sh                    # Show all instances
#   ./list-instances.sh --base-dir /path   # Custom base directory

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --base-dir) export NIGHTSCOUT_BASE_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--base-dir DIR]"
            echo "Lists all Nightscout instances and their status."
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

source "$SCRIPT_DIR/lib/instance-utils.sh"

echo "Nightscout Instance Status"
echo "=========================="
echo

print_instance_table

echo
echo "---"
echo

# Show Cloudflare tunnel info
get_cloudflare_ingress 2>/dev/null || true

echo
echo "---"
echo

# Show port bindings for nightscout-related containers
echo "Docker port bindings (nightscout-related):"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker ps --filter "label=com.docker.compose.service=nightscout" \
        --format '  {{.Names}}: {{.Ports}}' 2>/dev/null || true
    docker ps --filter "label=com.docker.compose.service=mongo" \
        --format '  {{.Names}}: {{.Ports}}' 2>/dev/null || true
    # Catch any nightscout containers not using compose labels
    docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -i nightscout | while IFS=$'\t' read -r name ports; do
        echo "  $name: $ports"
    done
else
    echo "  Docker not available"
fi
