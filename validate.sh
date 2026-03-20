#!/bin/bash

# Nightscout Configuration Validation Script
# This script validates the environment and Docker setup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared utilities (provides mongo_shell)
source "$SCRIPT_DIR/lib/instance-utils.sh"

echo "🔍 Nightscout Configuration Validation"
echo "====================================="

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

# Check if .env file exists
if [ ! -f ".env" ]; then
    print_error ".env file not found!"
    echo "Run ./setup.sh to create and configure your environment file."
    exit 1
fi

print_status ".env file found"

# Check for required environment variables
print_info "Checking required environment variables..."

REQUIRED_VARS=("API_SECRET" "MONGO_INITDB_ROOT_PASSWORD" "MONGO_CONNECTION" "TZ" "DISPLAY_UNITS")

for var in "${REQUIRED_VARS[@]}"; do
    if grep -q "^${var}=" .env; then
        value=$(grep "^${var}=" .env | cut -d'=' -f2)
        if [[ "$value" == *"change_this"* ]]; then
            print_error "$var still has default value"
        else
            print_status "$var is configured"
        fi
    else
        print_error "$var is missing"
    fi
done

# Check API_SECRET length
API_SECRET=$(grep "^API_SECRET=" .env | cut -d'=' -f2)
if [ ${#API_SECRET} -lt 12 ]; then
    print_error "API_SECRET is too short (minimum 12 characters, current: ${#API_SECRET})"
else
    print_status "API_SECRET length is adequate (${#API_SECRET} characters)"
fi

# Check MongoDB password
MONGO_PASSWORD=$(grep "^MONGO_INITDB_ROOT_PASSWORD=" .env | cut -d'=' -f2)
if [ ${#MONGO_PASSWORD} -lt 8 ]; then
    print_error "MONGO_INITDB_ROOT_PASSWORD is too short (minimum 8 characters, current: ${#MONGO_PASSWORD})"
else
    print_status "MONGO_INITDB_ROOT_PASSWORD length is adequate (${#MONGO_PASSWORD} characters)"
fi

# Check Docker installation
print_info "Checking Docker installation..."

if command -v docker &> /dev/null; then
    print_status "Docker is installed"
    
    # Check Docker daemon
    if docker info &> /dev/null; then
        print_status "Docker daemon is running"
    else
        print_error "Docker daemon is not running"
        echo "Start Docker and try again."
        exit 1
    fi
else
    print_error "Docker is not installed"
    echo "Install Docker and try again."
    exit 1
fi

# Check Docker Compose
if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
    print_status "Docker Compose is available"
else
    print_error "Docker Compose is not available"
    echo "Install Docker Compose and try again."
    exit 1
fi

# Check if containers are running
print_info "Checking container status..."

# Detect container names from compose project (handles multi-instance)
COMPOSE_PROJECT=$(basename "$(pwd)")
NS_CONTAINER=$(docker-compose ps -q nightscout 2>/dev/null || echo "")
MONGO_CONTAINER=$(docker-compose ps -q mongo 2>/dev/null || echo "")

if [ -n "$NS_CONTAINER" ]; then
    NS_NAME=$(docker inspect --format='{{.Name}}' "$NS_CONTAINER" 2>/dev/null | sed 's/^\///')
    NS_RUNNING=$(docker ps -q --filter "id=$NS_CONTAINER" 2>/dev/null)
    if [ -n "$NS_RUNNING" ]; then
        print_status "Nightscout container ($NS_NAME) is running"

        # Check health status
        HEALTH_STATUS=$(docker inspect "$NS_CONTAINER" --format='{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
        if [ "$HEALTH_STATUS" = "healthy" ]; then
            print_status "Nightscout container is healthy"
        elif [ "$HEALTH_STATUS" = "unhealthy" ]; then
            print_error "Nightscout container is unhealthy"
            print_info "Check logs: docker-compose logs nightscout"
        else
            print_warning "Nightscout health status: $HEALTH_STATUS"
        fi
    else
        print_warning "Nightscout container exists but is not running"
        echo "Start containers with: docker-compose up -d"
    fi
else
    print_warning "Nightscout container is not running"
    echo "Start containers with: docker-compose up -d"
fi

if [ -n "$MONGO_CONTAINER" ]; then
    MONGO_NAME=$(docker inspect --format='{{.Name}}' "$MONGO_CONTAINER" 2>/dev/null | sed 's/^\///')
    MONGO_RUNNING=$(docker ps -q --filter "id=$MONGO_CONTAINER" 2>/dev/null)
    if [ -n "$MONGO_RUNNING" ]; then
        print_status "MongoDB container ($MONGO_NAME) is running"

        # Test MongoDB connectivity
        if mongo_shell "$MONGO_CONTAINER" --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            print_status "MongoDB is responding to connections"
        else
            print_warning "MongoDB is not responding properly"
            print_info "Check logs: docker-compose logs mongo"
        fi
    else
        print_warning "MongoDB container exists but is not running"
        echo "Start containers with: docker-compose up -d"
    fi
else
    print_warning "MongoDB container is not running"
    echo "Start containers with: docker-compose up -d"
fi

# Check port availability
print_info "Checking port availability..."

# Check the configured host port (from .env or default 8080)
HOST_PORT=$(grep "^HOST_PORT=" .env 2>/dev/null | cut -d'=' -f2)
HOST_PORT=${HOST_PORT:-8080}

if netstat -an 2>/dev/null | grep -q ":${HOST_PORT} " || ss -tln 2>/dev/null | grep -q ":${HOST_PORT} "; then
    print_warning "Port $HOST_PORT is in use (expected if Nightscout is already running)"
else
    print_status "Port $HOST_PORT is available"
fi

# Check disk space
print_info "Checking disk space..."

DISK_USAGE=$(df . | tail -1 | awk '{print $5}' | sed 's/%//')
if [ "$DISK_USAGE" -gt 90 ]; then
    print_error "Disk usage is high (${DISK_USAGE}%)"
elif [ "$DISK_USAGE" -gt 80 ]; then
    print_warning "Disk usage is moderate (${DISK_USAGE}%)"
else
    print_status "Disk usage is acceptable (${DISK_USAGE}%)"
fi

# Check Docker images
print_info "Checking Docker images..."

if docker images | grep -q "nightscout/cgm-remote-monitor"; then
    print_status "Nightscout Docker image is available"
else
    print_warning "Nightscout Docker image not found"
    echo "Images will be pulled when starting containers"
fi

MONGO_VERSION=$(grep "^MONGO_VERSION=" .env 2>/dev/null | cut -d'=' -f2)
MONGO_VERSION=${MONGO_VERSION:-7.0}
if docker images | grep -q "mongo.*${MONGO_VERSION}"; then
    print_status "MongoDB Docker image (${MONGO_VERSION}) is available"
else
    print_warning "MongoDB Docker image (${MONGO_VERSION}) not found"
    echo "Images will be pulled when starting containers"
fi

# Summary
echo
echo "📊 Validation Summary"
echo "===================="

print_status "Configuration validation completed"
echo
echo "🎉 Your Nightscout setup appears to be ready!"
echo
echo "Next steps:"
echo "1. Start containers: docker-compose up -d"
echo "2. Check logs: docker-compose logs -f"
echo "3. Access Nightscout: http://localhost:${HOST_PORT}"

# Show all instances
echo
echo "📊 All Instances"
echo "================"
print_instance_table 2>/dev/null || true 