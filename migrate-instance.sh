#!/bin/bash

# Migrate an existing Nightscout instance to a new per-user directory
#
# Usage:
#   ./migrate-instance.sh --name alice --domain alice-ns.example.com --port 8081
#   ./migrate-instance.sh --name alice --domain alice-ns.example.com --port 8081 --source /path/to/old/instance
#
# This script:
#   1. Creates a new instance directory with all project files
#   2. Runs setup to generate fresh credentials
#   3. Optionally migrates data from an existing instance (local or remote mongodump)

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }

# Parse arguments
INSTANCE_NAME=""
DOMAIN=""
HOST_PORT=""
SOURCE_DIR=""
DUMP_FILE=""
BASE_DIR="/opt/nightscout"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared instance utilities
source "$SCRIPT_DIR/lib/instance-utils.sh"

usage() {
    echo "Migrate/create a Nightscout instance"
    echo ""
    echo "Usage:"
    echo "  $0 --name NAME --domain DOMAIN --port PORT [options]"
    echo ""
    echo "Required:"
    echo "  --name NAME          Instance name (e.g., alice, bob)"
    echo "  --domain DOMAIN      Domain for Cloudflare tunnel (e.g., alice-ns.example.com)"
    echo "  --port PORT          Host port (must be unique per instance, e.g., 8081)"
    echo ""
    echo "Optional:"
    echo "  --source DIR         Source instance directory to migrate data FROM"
    echo "  --dump FILE          Path to a mongodump archive (.gz) to restore"
    echo "  --base-dir DIR       Base directory for instances (default: /opt/nightscout)"
    echo "  --help               Show this help"
    echo ""
    echo "Examples:"
    echo "  # Fresh instance"
    echo "  $0 --name alice --domain alice-ns.example.com --port 8081"
    echo ""
    echo "  # Migrate from existing single-instance setup"
    echo "  $0 --name alice --domain alice-ns.example.com --port 8081 --source /opt/nightscout/old"
    echo ""
    echo "  # Restore from a mongodump file"
    echo "  $0 --name alice --domain alice-ns.example.com --port 8081 --dump /tmp/backup.gz"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --name) INSTANCE_NAME="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --port) HOST_PORT="$2"; shift 2 ;;
        --source) SOURCE_DIR="$2"; shift 2 ;;
        --dump) DUMP_FILE="$2"; shift 2 ;;
        --base-dir) BASE_DIR="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) print_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Validate required args
if [ -z "$INSTANCE_NAME" ] || [ -z "$DOMAIN" ] || [ -z "$HOST_PORT" ]; then
    print_error "Missing required arguments"
    usage
    exit 1
fi

# Validate port is a number
if ! [[ "$HOST_PORT" =~ ^[0-9]+$ ]]; then
    print_error "Port must be a number"
    exit 1
fi

# Check for port conflicts (config files AND actual network bindings)
export NIGHTSCOUT_BASE_DIR="$BASE_DIR"
PORT_CONFLICT=$(check_port_available "$HOST_PORT" "$INSTANCE_NAME" 2>&1) || {
    print_error "$PORT_CONFLICT"
    exit 1
}

# Show existing instances for context
EXISTING=$(discover_instances 2>/dev/null)
if [ -n "$EXISTING" ]; then
    echo
    print_info "Existing instances:"
    print_instance_table
    echo
fi

INSTANCE_DIR="$BASE_DIR/$INSTANCE_NAME"

echo "🔧 Nightscout Instance Migration/Setup"
echo "======================================="
echo "Instance name: $INSTANCE_NAME"
echo "Domain:        $DOMAIN"
echo "Host port:     $HOST_PORT"
echo "Instance dir:  $INSTANCE_DIR"
if [ -n "$SOURCE_DIR" ]; then
    echo "Migrating from: $SOURCE_DIR"
fi
if [ -n "$DUMP_FILE" ]; then
    echo "Restoring from: $DUMP_FILE"
fi
echo

# Check if instance dir already exists
if [ -d "$INSTANCE_DIR" ]; then
    print_warning "Instance directory already exists: $INSTANCE_DIR"
    read -p "Continue and overwrite config? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 1
    fi
fi

# =========================================================================
# Step 1: Create instance directory and copy project files
# =========================================================================
print_info "Step 1: Creating instance directory..."

mkdir -p "$INSTANCE_DIR"

# Copy project files (not .env, not .git)
for f in docker-compose.yml Dockerfile .env.example setup.sh setup-cloudflare.sh \
         validate.sh validate-database.sh diagnose.sh debug-tunnel.sh fix-tunnel.sh \
         cleanup.sh cleanup-tunnels.sh backup.sh upgrade-mongodb.sh; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$INSTANCE_DIR/"
    fi
done

# Copy directories
for d in mongo-init lib; do
    if [ -d "$SCRIPT_DIR/$d" ]; then
        cp -r "$SCRIPT_DIR/$d" "$INSTANCE_DIR/"
    fi
done

# Copy this script too for future use
cp "$SCRIPT_DIR/migrate-instance.sh" "$INSTANCE_DIR/" 2>/dev/null || true

print_status "Project files copied to $INSTANCE_DIR"

# =========================================================================
# Step 2: Generate .env with instance-specific config
# =========================================================================
print_info "Step 2: Generating instance configuration..."

cd "$INSTANCE_DIR"

# Generate secrets
API_SECRET=$(openssl rand -base64 32)
MONGO_ROOT_PASSWORD=$(openssl rand -base64 24)
MONGO_APP_PASSWORD=$(openssl rand -base64 24)
MONGO_APP_PASSWORD_ENCODED=$(echo "$MONGO_APP_PASSWORD" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g')

HOSTNAME_PART=$(echo "$DOMAIN" | cut -d'.' -f1)
CUSTOM_TITLE="${HOSTNAME_PART^} Nightscout"

cat > .env << ENVEOF
# Nightscout Instance: $INSTANCE_NAME
# Domain: $DOMAIN

# Instance settings
HOST_PORT=$HOST_PORT
MONGO_VERSION=7.0
MONGO_CACHE_SIZE_GB=0.25

# Security
API_SECRET=$API_SECRET
MONGO_INITDB_ROOT_PASSWORD=$MONGO_ROOT_PASSWORD

# MongoDB application user (Nightscout connects with this, not root)
MONGO_APP_USERNAME=nightscout
MONGO_APP_PASSWORD=$MONGO_APP_PASSWORD

# MongoDB connection (uses app user)
MONGO_CONNECTION=mongodb://nightscout:${MONGO_APP_PASSWORD_ENCODED}@mongo:27017/nightscout?authSource=nightscout
MONGO_COLLECTION=entries

# Core settings
NODE_ENV=production
TZ=America/New_York
DISPLAY_UNITS=mg/dl
CUSTOM_TITLE=$CUSTOM_TITLE

# Features
ENABLE=careportal basal dbsize rawbg iob maker cob bwp cage iage sage boluscalc pushover treatmentnotify loop pump profile food openaps bage alexa override cors
DEFAULT_FEATURES=careportal boluscalc food rawbg iob

# Alarms
ALARM_HIGH=260
ALARM_LOW=55
ALARM_URGENT_HIGH=370
ALARM_URGENT_LOW=40

# Theme
THEME=colors
LANGUAGE=en
AUTH_DEFAULT_ROLES=readable

# Security headers
INSECURE_USE_HTTP=false
SECURE_HSTS_HEADER=true
SECURE_HSTS_HEADER_INCLUDESUBDOMAINS=true
SECURE_HSTS_HEADER_PRELOAD=true

# Cloudflare
CLOUDFLARE_DOMAIN=$DOMAIN
CLOUDFLARE_TUNNEL_ID=
TUNNEL_NAME=${HOSTNAME_PART}-tunnel
ENVEOF

chmod 600 .env
print_status "Generated .env with unique credentials"

# =========================================================================
# Step 3: Start the new instance
# =========================================================================
print_info "Step 3: Starting new instance..."

docker-compose up -d
print_status "Instance started"

# Wait for MongoDB to be ready
print_info "Waiting for MongoDB to be ready..."
for i in {1..30}; do
    MONGO_CONTAINER=$(docker-compose ps -q mongo 2>/dev/null)
    if [ -n "$MONGO_CONTAINER" ] && mongo_shell "$MONGO_CONTAINER" --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
        print_status "MongoDB is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        print_error "MongoDB failed to become ready after 30 attempts"
        print_info "Check logs: docker-compose logs mongo"
        exit 1
    fi
    sleep 2
done

# =========================================================================
# Step 4: Migrate data if source provided
# =========================================================================
if [ -n "$SOURCE_DIR" ]; then
    print_info "Step 4: Migrating data from existing instance..."

    if [ ! -d "$SOURCE_DIR" ]; then
        print_error "Source directory not found: $SOURCE_DIR"
        exit 1
    fi

    # Get source MongoDB credentials
    if [ -f "$SOURCE_DIR/.env" ]; then
        # Extract password - handle base64 '=' characters by reading everything after first '='
        SRC_MONGO_PASS=$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$SOURCE_DIR/.env" | sed 's/^MONGO_INITDB_ROOT_PASSWORD=//')
    else
        print_error "No .env found in source directory"
        exit 1
    fi

    # Find the source mongo container
    SRC_MONGO=$(cd "$SOURCE_DIR" && docker-compose ps -q mongo 2>/dev/null)

    if [ -n "$SRC_MONGO" ] && docker ps -q --filter "id=$SRC_MONGO" | grep -q .; then
        print_info "Source MongoDB is running, dumping data..."

        # Dump from source
        DUMP_DIR="/tmp/nightscout-migrate-${INSTANCE_NAME}-$$"
        mkdir -p "$DUMP_DIR"

        docker exec "$SRC_MONGO" mongodump \
            --username root \
            --password "$SRC_MONGO_PASS" \
            --authenticationDatabase admin \
            --archive="/tmp/dump.archive" \
            --gzip

        docker cp "$SRC_MONGO:/tmp/dump.archive" "$DUMP_DIR/dump.archive"
        docker exec "$SRC_MONGO" rm -f /tmp/dump.archive

        print_status "Data exported from source instance"

        # Restore to new instance
        DEST_MONGO=$(docker-compose ps -q mongo)
        docker cp "$DUMP_DIR/dump.archive" "$DEST_MONGO:/tmp/dump.archive"

        docker exec "$DEST_MONGO" mongorestore \
            --username root \
            --password "$MONGO_PASSWORD" \
            --authenticationDatabase admin \
            --archive="/tmp/dump.archive" \
            --gzip \
            --drop

        docker exec "$DEST_MONGO" rm -f /tmp/dump.archive
        rm -rf "$DUMP_DIR"

        print_status "Data restored to new instance"
    else
        print_warning "Source MongoDB container is not running"
        print_info "Start the source instance first, or use --dump with a mongodump file"
    fi

elif [ -n "$DUMP_FILE" ]; then
    print_info "Step 4: Restoring data from dump file..."

    if [ ! -f "$DUMP_FILE" ]; then
        print_error "Dump file not found: $DUMP_FILE"
        exit 1
    fi

    DEST_MONGO=$(docker-compose ps -q mongo)
    docker cp "$DUMP_FILE" "$DEST_MONGO:/tmp/dump.archive"

    docker exec "$DEST_MONGO" mongorestore \
        --username root \
        --password "$MONGO_PASSWORD" \
        --authenticationDatabase admin \
        --archive="/tmp/dump.archive" \
        --gzip \
        --drop

    docker exec "$DEST_MONGO" rm -f /tmp/dump.archive

    print_status "Data restored from dump file"
else
    print_info "Step 4: Skipped (no source data to migrate)"
fi

# =========================================================================
# Step 5: Verify the instance
# =========================================================================
print_info "Step 5: Verifying instance..."

# Wait for Nightscout to be ready
for i in {1..24}; do
    if curl -s -f "http://localhost:${HOST_PORT}/api/v1/status" > /dev/null 2>&1; then
        print_status "Nightscout is responding on port $HOST_PORT"
        break
    fi
    if [ $i -eq 24 ]; then
        print_warning "Nightscout not yet responding (may still be starting)"
        print_info "Check logs: cd $INSTANCE_DIR && docker-compose logs -f"
    fi
    sleep 5
done

# =========================================================================
# Summary
# =========================================================================
echo
echo "============================================="
echo "Instance '$INSTANCE_NAME' is ready!"
echo "============================================="
echo
echo "Directory:  $INSTANCE_DIR"
echo "Local URL:  http://localhost:$HOST_PORT"
echo "Domain:     https://$DOMAIN (after tunnel setup)"
echo
echo "Next steps:"
echo "  1. Add ingress rule to your Cloudflare tunnel config:"
echo "     - hostname: $DOMAIN"
echo "       service: http://localhost:$HOST_PORT"
echo ""
echo "  2. Register DNS: cloudflared tunnel route dns <tunnel-name> $DOMAIN"
echo ""
echo "  3. Restart cloudflared: sudo systemctl restart cloudflared"
echo ""
echo "Management:"
echo "  cd $INSTANCE_DIR"
echo "  docker-compose logs -f        # View logs"
echo "  docker-compose restart        # Restart"
echo "  docker-compose down           # Stop"
echo "  ./validate.sh                 # Validate config"
