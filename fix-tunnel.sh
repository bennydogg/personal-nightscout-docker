#!/bin/bash

# Fix Cloudflare Tunnel Setup
# This script helps fix tunnel issues and get everything running

set -e

echo "🔧 Fixing Cloudflare Tunnel Setup"
echo "=================================="

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

# Check if .env file exists and get domain
if [ -f ".env" ]; then
    DOMAIN=$(grep "^CLOUDFLARE_DOMAIN=" .env | cut -d'=' -f2)
    if [ -z "$DOMAIN" ]; then
        print_error "CLOUDFLARE_DOMAIN not found in .env file"
        read -p "Enter your domain (e.g., nightscout.yourdomain.com): " DOMAIN
    else
        print_status "Found domain in .env: $DOMAIN"
    fi
else
    print_error ".env file not found. Please run ./setup.sh first."
    exit 1
fi

# List existing tunnels
print_info "Existing tunnels:"
cloudflared tunnel list

# Detect tunnel name from .env if available
DEFAULT_TUNNEL=""
if [ -f ".env" ]; then
    DEFAULT_TUNNEL=$(grep "^TUNNEL_NAME=" .env 2>/dev/null | cut -d'=' -f2)
fi

# Ask which tunnel to use
echo
if [ -n "$DEFAULT_TUNNEL" ]; then
    read -p "Enter the tunnel name to use (or press Enter for '$DEFAULT_TUNNEL'): " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-$DEFAULT_TUNNEL}
else
    read -p "Enter the tunnel name to use: " TUNNEL_NAME
    if [ -z "$TUNNEL_NAME" ]; then
        print_error "Tunnel name is required"
        exit 1
    fi
fi

print_info "Using tunnel: $TUNNEL_NAME"

# Set up DNS route
print_info "Setting up DNS route..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN"
print_status "DNS route configured"

# Check if tunnel config exists
TUNNEL_DIR="$HOME/.cloudflared"
if [ ! -f "$TUNNEL_DIR/config.yml" ]; then
    print_error "Tunnel configuration not found!"
    print_info "Please run ./setup-cloudflare.sh first to create the tunnel configuration."
    exit 1
fi

# Start the tunnel service
print_info "Starting tunnel service..."
sudo systemctl daemon-reload
sudo systemctl enable cloudflared
sudo systemctl start cloudflared

# Check service status
sleep 3
if sudo systemctl is-active --quiet cloudflared; then
    print_status "Tunnel service is running"
else
    print_error "Tunnel service failed to start"
    print_info "Checking logs..."
    sudo journalctl -u cloudflared --no-pager -n 10
    exit 1
fi

# Test tunnel connection
print_info "Testing tunnel connection..."
sleep 5
if curl -s -f "https://$DOMAIN" > /dev/null 2>&1; then
    print_status "Tunnel connection test successful!"
else
    print_warning "Tunnel connection test failed. This is normal if DNS hasn't propagated yet."
    print_info "DNS propagation can take a few minutes."
fi

# Show final status
echo
echo "🎉 Tunnel setup completed!"
echo
echo "📋 Summary:"
echo "- Tunnel Name: $TUNNEL_NAME"
echo "- Domain: $DOMAIN"
echo "- Service Status: $(sudo systemctl is-active cloudflared)"
echo
echo "🔧 Management Commands:"
echo "- Check status: sudo systemctl status cloudflared"
echo "- View logs: sudo journalctl -u cloudflared -f"
echo "- Restart tunnel: sudo systemctl restart cloudflared"
echo
echo "🌐 Your Nightscout will be available at:"
echo "   https://$DOMAIN"
echo
echo "🚀 Ready to start Nightscout:"
echo "   docker compose up -d" 