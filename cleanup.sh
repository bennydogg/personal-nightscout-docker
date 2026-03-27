#!/bin/bash

# Cleanup Script for Nightscout Docker Setup
# This script removes all containers, volumes, and configurations

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/instance-utils.sh"

echo "🧹 Nightscout Cleanup Script"
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

# Detect what this compose project manages
COMPOSE_PROJECT=$(basename "$(pwd)")
print_info "Compose project: $COMPOSE_PROJECT"
echo

# Show all instances for context so you know what you're cleaning up
echo "All known instances:"
print_instance_table 2>/dev/null || true
echo

# Confirm cleanup
print_warning "This will remove containers, volumes, and data for THIS instance only."
print_warning "Project directory: $(pwd)"
print_warning "This action DESTROYS ALL CGM DATA for this instance and cannot be undone!"
echo
read -p "Type 'yes' to confirm cleanup: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 1
fi

# Stop and remove containers and volumes via compose (scoped to this project)
print_info "Stopping and removing containers and volumes..."
if docker_compose ps -q 2>/dev/null | head -1 | grep -q .; then
    docker_compose down -v
    print_status "Containers and volumes removed"
else
    print_info "No running containers found for this project"
    # Still run down -v to clean up stopped containers/volumes
    docker_compose down -v 2>/dev/null || true
fi

# Remove configuration files
print_info "Removing configuration files..."
rm -f .env
rm -f docker-compose.cloudflare.yml
print_status "Configuration files removed"

# Remove management scripts
print_info "Removing management scripts..."
rm -f tunnel-status.sh tunnel-logs.sh tunnel-restart.sh
print_status "Management scripts removed"

# Remove Cloudflare tunnel configuration
print_info "Removing Cloudflare tunnel configuration..."
if [ -d "$HOME/.cloudflared" ]; then
    print_warning "Cloudflare tunnel configuration found at $HOME/.cloudflared"
    read -p "Do you want to remove Cloudflare tunnel configuration? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$HOME/.cloudflared"
        print_status "Cloudflare tunnel configuration removed"
    else
        print_info "Cloudflare tunnel configuration preserved"
    fi
fi

# Stop and disable cloudflared service
print_info "Stopping cloudflared service..."
if sudo systemctl is-active --quiet cloudflared 2>/dev/null; then
    sudo systemctl stop cloudflared
    sudo systemctl disable cloudflared
    print_status "cloudflared service stopped and disabled"
else
    print_info "cloudflared service not running"
fi

# Remove cloudflared service file
if [ -f "/etc/systemd/system/cloudflared.service" ]; then
    sudo rm /etc/systemd/system/cloudflared.service
    sudo systemctl daemon-reload
    print_status "cloudflared service file removed"
fi

# Remove cloudflared binary
if [ -f "/usr/local/bin/cloudflared" ]; then
    print_warning "cloudflared binary found at /usr/local/bin/cloudflared"
    read -p "Do you want to remove cloudflared binary? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo rm /usr/local/bin/cloudflared
        print_status "cloudflared binary removed"
    else
        print_info "cloudflared binary preserved"
    fi
fi

print_status "Cleanup completed successfully!"
echo
echo "🎉 Your system is now clean and ready for a fresh setup!"
echo
echo "Next steps:"
echo "1. Run ./setup.sh to configure Nightscout"
echo "2. Run ./setup-cloudflare.sh to set up Cloudflare Tunnel"
echo "3. Start services with: docker compose up -d" 