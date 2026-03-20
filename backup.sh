#!/bin/bash

# Nightscout Backup Script
#
# Usage:
#   ./backup.sh                              # Interactive backup
#   ./backup.sh --schedule daily             # Non-interactive (cron-safe)
#   ./backup.sh --backup-dir /tmp/backups    # Custom output directory
#   ./backup.sh --encrypt                    # Encrypt the backup
#
# Cron example (daily at 2am):
#   0 2 * * * cd /opt/nightscout/alice && ./backup.sh --schedule daily >> /var/log/nightscout-backup.log 2>&1

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared utilities (provides mongo_shell)
source "$SCRIPT_DIR/lib/instance-utils.sh"

# Configuration
BACKUP_DIR="${SCRIPT_DIR}/backups"
RETENTION_DAYS=7
ENCRYPT_BACKUP=false
COMPRESS_BACKUP=true
VERIFY_BACKUP=true
SCHEDULE="manual"

# Colors (disabled in non-interactive mode)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }

is_interactive() { [ "$SCHEDULE" = "manual" ] && [ -t 0 ]; }

print_usage() {
    echo "Nightscout Backup Script"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --schedule TYPE     Backup type label (manual, daily, weekly, monthly)"
    echo "                      Non-manual schedules skip interactive prompts (cron-safe)"
    echo "  --retention DAYS    Days to keep backups (default: 7)"
    echo "  --encrypt           Encrypt backup (key stored in --key-file)"
    echo "  --key-file FILE     Encryption key file (default: ~/.nightscout-backup-key)"
    echo "  --no-compress       Disable compression"
    echo "  --no-verify         Skip backup verification"
    echo "  --backup-dir DIR    Backup output directory (default: ./backups)"
    echo "  --help, -h          Show this help"
}

ENCRYPTION_KEY_FILE="$HOME/.nightscout-backup-key"

while [[ $# -gt 0 ]]; do
    case $1 in
        --schedule) SCHEDULE="$2"; shift 2 ;;
        --retention) RETENTION_DAYS="$2"; shift 2 ;;
        --encrypt) ENCRYPT_BACKUP=true; shift ;;
        --key-file) ENCRYPTION_KEY_FILE="$2"; shift 2 ;;
        --no-compress) COMPRESS_BACKUP=false; shift ;;
        --no-verify) VERIFY_BACKUP=false; shift ;;
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        -h|--help) print_usage; exit 0 ;;
        *) print_error "Unknown option: $1"; print_usage; exit 1 ;;
    esac
done

# Validate schedule
if [[ ! "$SCHEDULE" =~ ^(manual|daily|weekly|monthly)$ ]]; then
    print_error "Invalid schedule: $SCHEDULE (must be manual, daily, weekly, or monthly)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

# Must have a .env file
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    print_error "No .env file found in $SCRIPT_DIR. Run from an instance directory."
    exit 1
fi

# Docker must be running
if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running"
    exit 1
fi

# MongoDB container must be running
MONGO_CONTAINER=$(cd "$SCRIPT_DIR" && docker-compose ps -q mongo 2>/dev/null)
if [ -z "$MONGO_CONTAINER" ] || ! docker ps -q --filter "id=$MONGO_CONTAINER" 2>/dev/null | grep -q .; then
    print_error "MongoDB container is not running. Start with: docker-compose up -d"
    exit 1
fi

# Read MongoDB password from .env (handle passwords containing '=')
MONGO_PASSWORD=$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$SCRIPT_DIR/.env" | sed 's/^MONGO_INITDB_ROOT_PASSWORD=//')
if [ -z "$MONGO_PASSWORD" ]; then
    print_error "MONGO_INITDB_ROOT_PASSWORD not found in .env"
    exit 1
fi

# Check disk space (warn if < 1GB, skip prompt in non-interactive)
AVAILABLE_KB=$(df "$BACKUP_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
if [ "$AVAILABLE_KB" -lt 1048576 ] 2>/dev/null; then
    print_warning "Low disk space: $((AVAILABLE_KB / 1024))MB available"
    if is_interactive; then
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    else
        print_warning "Continuing despite low disk space (non-interactive mode)"
    fi
fi

# Test MongoDB connectivity
if ! mongo_shell "$MONGO_CONTAINER" \
    --username root --password "$MONGO_PASSWORD" --authenticationDatabase admin \
    --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
    print_error "Cannot connect to MongoDB (auth failed or container unhealthy)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Create backup
# ---------------------------------------------------------------------------

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

DATE=$(date +%Y%m%d_%H%M%S)
INSTANCE_NAME=$(basename "$SCRIPT_DIR")
BACKUP_NAME="nightscout-${INSTANCE_NAME}-${SCHEDULE}-${DATE}"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
mkdir -p "$BACKUP_PATH"

echo "Nightscout Backup: $INSTANCE_NAME"
echo "==================================="
echo "Schedule: $SCHEDULE | Retention: ${RETENTION_DAYS}d | Encrypt: $ENCRYPT_BACKUP"
echo ""

# Step 1: mongodump with authentication
print_info "Step 1: Dumping MongoDB..."

if docker exec "$MONGO_CONTAINER" mongodump \
    --username root \
    --password "$MONGO_PASSWORD" \
    --authenticationDatabase admin \
    --gzip \
    --archive="/tmp/backup-${DATE}.archive"; then
    print_status "MongoDB dump completed"
else
    print_error "mongodump failed"
    exit 1
fi

# Copy archive out of container
docker cp "$MONGO_CONTAINER:/tmp/backup-${DATE}.archive" "$BACKUP_PATH/mongo.archive"
docker exec "$MONGO_CONTAINER" rm -f "/tmp/backup-${DATE}.archive"
print_status "Archive copied from container"

# Step 2: Back up config (not cloudflare certs — those are account-level)
print_info "Step 2: Backing up configuration..."
cp "$SCRIPT_DIR/.env" "$BACKUP_PATH/env.backup" 2>/dev/null || true
cp "$SCRIPT_DIR/docker-compose.yml" "$BACKUP_PATH/" 2>/dev/null || true
print_status "Configuration backed up"

# Step 3: Compress into a single archive
if [ "$COMPRESS_BACKUP" = true ]; then
    print_info "Step 3: Compressing..."
    ARCHIVE_FILE="${BACKUP_NAME}.tar.gz"
    (cd "$BACKUP_DIR" && tar czf "$ARCHIVE_FILE" "$BACKUP_NAME")
    rm -rf "$BACKUP_PATH"
    BACKUP_FILE="$ARCHIVE_FILE"
    print_status "Compressed to $ARCHIVE_FILE"
else
    BACKUP_FILE="$BACKUP_NAME"
fi

# Step 4: Encrypt
if [ "$ENCRYPT_BACKUP" = true ]; then
    print_info "Step 4: Encrypting..."

    if [ ! -f "$ENCRYPTION_KEY_FILE" ]; then
        openssl rand -base64 32 > "$ENCRYPTION_KEY_FILE"
        chmod 600 "$ENCRYPTION_KEY_FILE"
        print_warning "Generated new encryption key: $ENCRYPTION_KEY_FILE"
        print_warning "SAVE THIS KEY — you need it to restore backups"
    fi

    if openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -salt -in "$BACKUP_DIR/$BACKUP_FILE" \
        -out "$BACKUP_DIR/${BACKUP_FILE}.enc" \
        -pass file:"$ENCRYPTION_KEY_FILE"; then
        rm "$BACKUP_DIR/$BACKUP_FILE"
        BACKUP_FILE="${BACKUP_FILE}.enc"
        print_status "Encrypted with AES-256-CBC (PBKDF2)"
    else
        print_error "Encryption failed"
        exit 1
    fi
else
    print_info "Step 4: Encryption skipped"
fi

# Step 5: Verify
if [ "$VERIFY_BACKUP" = true ]; then
    print_info "Step 5: Verifying..."
    if [ -f "$BACKUP_DIR/$BACKUP_FILE" ] && [ -s "$BACKUP_DIR/$BACKUP_FILE" ]; then
        BACKUP_SIZE=$(du -h "$BACKUP_DIR/$BACKUP_FILE" | cut -f1)
        print_status "Verified: $BACKUP_FILE ($BACKUP_SIZE)"
    else
        print_error "Backup file missing or empty"
        exit 1
    fi
fi

# Step 6: Retention cleanup
print_info "Step 6: Cleaning old backups..."
find "$BACKUP_DIR" -name "nightscout-${INSTANCE_NAME}-*" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
print_status "Cleaned backups older than ${RETENTION_DAYS} days"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Backup complete!"
echo "  File: $BACKUP_DIR/$BACKUP_FILE"
echo "  Size: $(du -h "$BACKUP_DIR/$BACKUP_FILE" | cut -f1)"
echo ""
echo "To restore:"
echo "  # Decrypt (if encrypted):"
[ "$ENCRYPT_BACKUP" = true ] && echo "  openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in $BACKUP_FILE -out ${BACKUP_FILE%.enc} -pass file:$ENCRYPTION_KEY_FILE"
echo "  # Extract (if compressed):"
echo "  tar xzf ${BACKUP_FILE%.enc} -C /tmp/"
echo "  # Restore:"
echo "  docker cp /tmp/${BACKUP_NAME}/mongo.archive \$(docker-compose ps -q mongo):/tmp/"
echo "  docker-compose exec mongo mongorestore --username root --password \$MONGO_PASSWORD --authenticationDatabase admin --archive=/tmp/mongo.archive --gzip --drop"
