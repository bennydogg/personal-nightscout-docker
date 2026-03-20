#!/bin/bash

# Cleanup Unused Cloudflare Tunnels
# This script helps delete unused tunnels

set -e

echo "🧹 Cloudflare Tunnel Cleanup"
echo "============================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# List existing tunnels
print_info "Current tunnels:"
cloudflared tunnel list

echo
print_warning "⚠️  WARNING: This will permanently delete tunnels!"
echo "Make sure you know which tunnels you want to keep."
echo

# Detect active tunnel name from .env if available
ACTIVE_TUNNEL=""
if [ -f ".env" ]; then
    ACTIVE_TUNNEL=$(grep "^TUNNEL_NAME=" .env 2>/dev/null | cut -d'=' -f2)
fi

# Ask which tunnels to delete
if [ -n "$ACTIVE_TUNNEL" ]; then
    read -p "Enter tunnel names to delete (space-separated, or 'all' for all except '$ACTIVE_TUNNEL'): " TUNNELS_TO_DELETE
else
    read -p "Enter tunnel names to delete (space-separated, or 'all' for all): " TUNNELS_TO_DELETE
fi

if [ "$TUNNELS_TO_DELETE" = "all" ]; then
    EXCLUDE_NAME="${ACTIVE_TUNNEL}"
    if [ -n "$EXCLUDE_NAME" ]; then
        print_info "Deleting all tunnels except '$EXCLUDE_NAME'..."
    else
        print_info "Deleting all tunnels..."
    fi

    TUNNELS_TO_DELETE=$(cloudflared tunnel list -o json | python3 -c "
import json, sys
try:
    exclude = '$EXCLUDE_NAME'
    data = json.load(sys.stdin)
    names = [tunnel['name'] for tunnel in data if not exclude or tunnel.get('name') != exclude]
    print(' '.join(names))
except:
    sys.exit(1)
" 2>/dev/null)

    if [ -z "$TUNNELS_TO_DELETE" ]; then
        print_info "No tunnels to delete"
        exit 0
    fi
fi

# Confirm deletion
echo
print_warning "The following tunnels will be deleted:"
for tunnel in $TUNNELS_TO_DELETE; do
    echo "  - $tunnel"
done

echo
read -p "Are you sure you want to delete these tunnels? (y/N): " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Delete tunnels
    for tunnel in $TUNNELS_TO_DELETE; do
        print_info "Deleting tunnel: $tunnel"
        cloudflared tunnel delete "$tunnel"
        print_status "Deleted tunnel: $tunnel"
    done
    
    echo
    print_status "Cleanup completed!"
    echo
    print_info "Remaining tunnels:"
    cloudflared tunnel list
else
    print_info "Cleanup cancelled."
fi 