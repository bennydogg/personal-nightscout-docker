#!/bin/bash

# MongoDB Upgrade Script for Nightscout
#
# Upgrades MongoDB through the required version steps: 4.4 → 5.0 → 6.0 → 7.0
# Each step sets featureCompatibilityVersion before and after the image change.
#
# Usage:
#   ./upgrade-mongodb.sh                    # Upgrade to 7.0
#   ./upgrade-mongodb.sh --target 5.0       # Stop at 5.0
#   ./upgrade-mongodb.sh --dry-run          # Show what would happen
#   ./upgrade-mongodb.sh --skip-backup      # Skip pre-upgrade backup

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared utilities (provides mongo_shell)
source "$SCRIPT_DIR/lib/instance-utils.sh"

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

# Valid upgrade path
VERSIONS=("4.4" "5.0" "6.0" "7.0")

# Which shell binary each version provides
mongo_cmd_for_version() {
    case "$1" in
        4.4|5.0) echo "mongo" ;;
        6.0|7.0) echo "mongosh" ;;
        *) echo "mongosh" ;;
    esac
}

# Parse arguments
DRY_RUN=false
TARGET_VERSION="7.0"
SKIP_BACKUP=false

usage() {
    echo "MongoDB Upgrade Script for Nightscout"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --target VERSION   Target MongoDB version (5.0, 6.0, or 7.0; default: 7.0)"
    echo "  --dry-run          Show what would happen without making changes"
    echo "  --skip-backup      Skip the pre-upgrade backup"
    echo "  --help, -h         Show this help"
    echo ""
    echo "The script upgrades through each required step (4.4 → 5.0 → 6.0 → 7.0),"
    echo "setting featureCompatibilityVersion at each stage."
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --target) TARGET_VERSION="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-backup) SKIP_BACKUP=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Validate target version
TARGET_VALID=false
for v in "${VERSIONS[@]}"; do
    if [ "$v" = "$TARGET_VERSION" ]; then TARGET_VALID=true; break; fi
done
if ! $TARGET_VALID; then
    print_error "Invalid target version: $TARGET_VERSION (valid: ${VERSIONS[*]})"
    exit 1
fi

# Must have a .env file
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    print_error "No .env file found in $SCRIPT_DIR. Run from an instance directory."
    exit 1
fi

cd "$SCRIPT_DIR"

# Determine current version
CURRENT_VERSION=$(grep "^MONGO_VERSION=" .env 2>/dev/null | cut -d'=' -f2)
CURRENT_VERSION=${CURRENT_VERSION:-4.4}

# Read HOST_PORT for health checks
HOST_PORT=$(grep "^HOST_PORT=" .env 2>/dev/null | cut -d'=' -f2)
HOST_PORT=${HOST_PORT:-8080}

# Read MongoDB root password
MONGO_PASSWORD=$(grep "^MONGO_INITDB_ROOT_PASSWORD=" .env | sed 's/^MONGO_INITDB_ROOT_PASSWORD=//')
if [ -z "$MONGO_PASSWORD" ]; then
    print_error "MONGO_INITDB_ROOT_PASSWORD not found in .env"
    exit 1
fi

INSTANCE_NAME=$(basename "$SCRIPT_DIR")

echo "MongoDB Upgrade: $INSTANCE_NAME"
echo "================================="
echo "Current version: $CURRENT_VERSION"
echo "Target version:  $TARGET_VERSION"
if $DRY_RUN; then
    echo "Mode:            DRY RUN (no changes will be made)"
fi
echo ""

# Find current and target indices in the version array
CURRENT_IDX=-1
TARGET_IDX=-1
for i in "${!VERSIONS[@]}"; do
    if [ "${VERSIONS[$i]}" = "$CURRENT_VERSION" ]; then CURRENT_IDX=$i; fi
    if [ "${VERSIONS[$i]}" = "$TARGET_VERSION" ]; then TARGET_IDX=$i; fi
done

if [ $CURRENT_IDX -eq -1 ]; then
    print_error "Current version '$CURRENT_VERSION' is not in the supported upgrade path (${VERSIONS[*]})"
    exit 1
fi

if [ $CURRENT_IDX -ge $TARGET_IDX ]; then
    print_status "Already at or beyond target version ($CURRENT_VERSION >= $TARGET_VERSION). Nothing to do."
    exit 0
fi

# Show upgrade plan
echo "Upgrade path:"
for (( i=CURRENT_IDX; i<TARGET_IDX; i++ )); do
    echo "  ${VERSIONS[$i]} → ${VERSIONS[$((i+1))]}"
done
echo ""

# ---------------------------------------------------------------------------
# Pre-upgrade backup
# ---------------------------------------------------------------------------
if ! $SKIP_BACKUP && ! $DRY_RUN; then
    print_info "Step 0: Creating pre-upgrade backup..."
    if [ -f "$SCRIPT_DIR/backup.sh" ]; then
        if ./backup.sh --schedule manual; then
            print_status "Backup completed"
        else
            print_error "Backup failed. Aborting upgrade."
            print_info "Use --skip-backup to bypass (not recommended)"
            exit 1
        fi
    else
        print_warning "backup.sh not found, skipping backup"
    fi
    echo ""
elif $DRY_RUN; then
    print_info "[DRY RUN] Would create backup via ./backup.sh"
    echo ""
fi

# ---------------------------------------------------------------------------
# Step through each version
# ---------------------------------------------------------------------------
for (( i=CURRENT_IDX; i<TARGET_IDX; i++ )); do
    FROM_VERSION="${VERSIONS[$i]}"
    TO_VERSION="${VERSIONS[$((i+1))]}"
    SHELL_CMD=$(mongo_cmd_for_version "$FROM_VERSION")
    NEW_SHELL_CMD=$(mongo_cmd_for_version "$TO_VERSION")
    STEP_NUM=$((i - CURRENT_IDX + 1))

    echo "==========================================="
    echo "Step $STEP_NUM: $FROM_VERSION → $TO_VERSION"
    echo "==========================================="

    if $DRY_RUN; then
        echo "  [DRY RUN] Would set featureCompatibilityVersion to '$FROM_VERSION' (using $SHELL_CMD)"
        echo "  [DRY RUN] Would run: docker-compose down"
        echo "  [DRY RUN] Would update MONGO_VERSION=$TO_VERSION in .env"
        echo "  [DRY RUN] Would run: docker-compose up -d"
        echo "  [DRY RUN] Would wait for MongoDB to be ready (using $NEW_SHELL_CMD)"
        echo "  [DRY RUN] Would set featureCompatibilityVersion to '$TO_VERSION'"
        echo "  [DRY RUN] Would verify Nightscout health on port $HOST_PORT"
        echo ""
        continue
    fi

    # 1. Ensure containers are running for FCV set
    MONGO_CONTAINER=$(docker-compose ps -q mongo 2>/dev/null)
    if [ -z "$MONGO_CONTAINER" ] || ! docker ps -q --filter "id=$MONGO_CONTAINER" 2>/dev/null | grep -q .; then
        print_info "Starting containers for FCV check..."
        docker-compose up -d
        sleep 5
        MONGO_CONTAINER=$(docker-compose ps -q mongo 2>/dev/null)
    fi

    # 2. Set FCV to current version (required before upgrading)
    print_info "Setting featureCompatibilityVersion to '$FROM_VERSION'..."
    if mongo_shell "$MONGO_CONTAINER" \
        --username root --password "$MONGO_PASSWORD" --authenticationDatabase admin \
        --eval "db.adminCommand({ setFeatureCompatibilityVersion: '$FROM_VERSION' })" >/dev/null 2>&1; then
        print_status "FCV set to $FROM_VERSION"
    else
        print_error "Failed to set featureCompatibilityVersion to $FROM_VERSION"
        print_info "Check: docker-compose logs mongo"
        exit 1
    fi

    # Verify FCV
    FCV_CHECK=$(mongo_shell "$MONGO_CONTAINER" \
        --username root --password "$MONGO_PASSWORD" --authenticationDatabase admin \
        --quiet --eval "db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 }).featureCompatibilityVersion.version" 2>/dev/null)
    print_info "Confirmed FCV: $FCV_CHECK"

    # 3. Stop containers
    print_info "Stopping containers..."
    docker-compose down
    print_status "Containers stopped"

    # 4. Update MONGO_VERSION in .env
    print_info "Updating MONGO_VERSION to $TO_VERSION in .env..."
    if grep -q "^MONGO_VERSION=" .env; then
        sed -i.bak "s/^MONGO_VERSION=.*/MONGO_VERSION=$TO_VERSION/" .env
        rm -f .env.bak
    else
        echo "MONGO_VERSION=$TO_VERSION" >> .env
    fi
    print_status "Updated .env"

    # 5. Start containers with new version
    print_info "Starting containers with MongoDB $TO_VERSION..."
    docker-compose up -d
    print_status "Containers starting"

    # 6. Wait for MongoDB to be ready
    print_info "Waiting for MongoDB $TO_VERSION to be ready..."
    MONGO_CONTAINER=$(docker-compose ps -q mongo 2>/dev/null)
    READY=false
    for attempt in {1..60}; do
        if [ -n "$MONGO_CONTAINER" ] && mongo_shell "$MONGO_CONTAINER" \
            --username root --password "$MONGO_PASSWORD" --authenticationDatabase admin \
            --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            READY=true
            break
        fi
        # Re-fetch container ID in case it changed
        MONGO_CONTAINER=$(docker-compose ps -q mongo 2>/dev/null)
        sleep 2
    done

    if ! $READY; then
        print_error "MongoDB $TO_VERSION failed to become ready after 120 seconds"
        print_info "Check logs: docker-compose logs mongo"
        print_warning "To rollback: edit .env, set MONGO_VERSION=$FROM_VERSION, then docker-compose up -d"
        exit 1
    fi
    print_status "MongoDB $TO_VERSION is ready"

    # 7. Set FCV to new version
    print_info "Setting featureCompatibilityVersion to '$TO_VERSION'..."
    if mongo_shell "$MONGO_CONTAINER" \
        --username root --password "$MONGO_PASSWORD" --authenticationDatabase admin \
        --eval "db.adminCommand({ setFeatureCompatibilityVersion: '$TO_VERSION' })" >/dev/null 2>&1; then
        print_status "FCV set to $TO_VERSION"
    else
        print_error "Failed to set featureCompatibilityVersion to $TO_VERSION"
        print_info "MongoDB is running at $TO_VERSION but FCV is still at $FROM_VERSION"
        print_info "You can set it manually later: mongosh --eval \"db.adminCommand({setFeatureCompatibilityVersion: '$TO_VERSION'})\""
        # Don't exit — the upgrade itself succeeded, FCV can be set later
    fi

    # 8. Verify Nightscout health
    print_info "Checking Nightscout health..."
    NS_HEALTHY=false
    for attempt in {1..24}; do
        if curl -s -f "http://localhost:${HOST_PORT}/api/v1/status" >/dev/null 2>&1; then
            NS_HEALTHY=true
            break
        fi
        sleep 5
    done

    if $NS_HEALTHY; then
        print_status "Nightscout is healthy on port $HOST_PORT"
    else
        print_warning "Nightscout not yet responding (may still be starting)"
        print_info "Check: docker-compose logs -f nightscout"
    fi

    echo ""
    print_status "Completed: $FROM_VERSION → $TO_VERSION"
    echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "============================================="
if $DRY_RUN; then
    echo "DRY RUN complete — no changes were made"
    echo ""
    echo "To run the upgrade for real:"
    echo "  ./upgrade-mongodb.sh --target $TARGET_VERSION"
else
    echo "MongoDB upgrade complete!"
    echo "============================================="
    echo ""
    echo "Instance:    $INSTANCE_NAME"
    echo "Version:     $CURRENT_VERSION → $TARGET_VERSION"
    echo ""
    echo "Verify with:"
    echo "  docker-compose exec mongo mongosh --eval \"db.adminCommand({getParameter:1, featureCompatibilityVersion:1})\""
    echo "  ./validate.sh"
    echo "  ./validate-database.sh"
fi
