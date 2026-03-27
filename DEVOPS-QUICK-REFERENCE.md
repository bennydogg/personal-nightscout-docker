# DevOps Quick Reference

**Unified CLI:** run `./ns help` from the repo or an instance directory. Prefer `./ns <command>` over remembering each `*.sh` name.

All commands below assume you're in an instance directory (e.g., `/opt/nightscout/alice/`) unless noted.

## Daily Operations

```bash
# Instance overview (all instances; run from repo or instance dir)
./ns list

# Start / stop / restart
docker compose up -d
docker compose down
docker compose restart

# Logs
docker compose logs -f
docker compose logs -f nightscout
docker compose logs -f mongo

# Health check
docker compose ps
curl -f http://localhost:${HOST_PORT:-8080}/api/v1/status
./ns validate
```

## Instance Management

```bash
# Create new instance
./ns migrate --name alice --domain alice-ns.example.com --port 8081

# Migrate with data from existing instance
./ns migrate --name alice --domain alice-ns.example.com --port 8081 \
  --source /opt/nightscout/old-instance

# Restore from dump file
./ns migrate --name alice --domain alice-ns.example.com --port 8081 \
  --dump /tmp/backup.gz

# Destroy instance (interactive confirmation required)
cd /opt/nightscout/alice && ./ns cleanup
```

## Database

```bash
# Test connectivity
docker compose exec mongo mongosh --eval "db.adminCommand('ping')"

# Database stats
docker compose exec mongo mongosh --eval "db.stats()"

# Server status
docker compose exec mongo mongosh --eval "db.serverStatus()"

# Manual mongodump (with auth)
docker compose exec mongo mongodump \
  --username root \
  --password "$(grep '^MONGO_INITDB_ROOT_PASSWORD=' .env | sed 's/^MONGO_INITDB_ROOT_PASSWORD=//')" \
  --authenticationDatabase admin \
  --archive=/tmp/dump.gz --gzip

# Copy dump out of container
docker cp "$(docker compose ps -q mongo):/tmp/dump.gz" ./backup.gz
```

## Cloudflare Tunnel

```bash
# Service management
sudo systemctl status cloudflared
sudo systemctl restart cloudflared
sudo journalctl -u cloudflared -f

# Tunnel info
cloudflared tunnel list
cloudflared tunnel info <tunnel-name>

# Add a new hostname to existing tunnel
cloudflared tunnel route dns <tunnel-name> new-hostname.example.com
# Then add ingress rule to ~/.cloudflared/config.yml and restart

# Debug / fix
./debug-tunnel.sh
./fix-tunnel.sh

# Recreate tunnel from scratch
./cleanup-tunnels.sh
./setup-cloudflare.sh --domain your.domain.com
```

## Networking

```bash
# Check port bindings
ss -tlnp | grep -E ':(8080|8081|8082) '

# Check what's using a specific port
ss -tlnp | grep :8081
# or
lsof -i :8081

# Test internal container connectivity
docker compose exec nightscout curl -f http://mongo:27017/ 2>&1 || echo "mongo reachable"
```

## Updates

```bash
# Update Nightscout image
docker compose down
docker compose pull
docker compose up -d

# Update all instances
for dir in /opt/nightscout/*/; do
  echo "=== Updating $(basename "$dir") ==="
  (cd "$dir" && docker compose down && docker compose pull && docker compose up -d)
done
```

## MongoDB Upgrade

```bash
# Preview upgrade plan
./upgrade-mongodb.sh --dry-run

# Upgrade to 7.0 (handles 4.4 → 5.0 → 6.0 → 7.0 stepping)
./upgrade-mongodb.sh

# Stop at an intermediate version
./upgrade-mongodb.sh --target 5.0

# Check current FCV after upgrade
docker compose exec mongo mongosh --eval "db.adminCommand({getParameter:1, featureCompatibilityVersion:1})"
```

## Resource Monitoring

```bash
# Container resource usage
docker stats --no-stream

# System resources
df -h
free -h

# Docker disk usage
docker system df

# MongoDB WiredTiger cache is capped per instance via MONGO_CACHE_SIZE_GB (default 0.25)
```

## Credentials

```bash
# Generate new secrets
openssl rand -base64 32    # API secret
openssl rand -base64 24    # MongoDB password

# Rotate credentials: edit .env, then restart
nano .env
docker compose down
docker compose up -d
```

## Emergency

```bash
# Quick restart
docker compose restart

# Full restart
docker compose down && docker compose up -d

# Emergency tunnel restart
sudo systemctl restart cloudflared

# Emergency backup before destructive action
docker compose exec mongo mongodump \
  --username root \
  --password "$(grep '^MONGO_INITDB_ROOT_PASSWORD=' .env | sed 's/^MONGO_INITDB_ROOT_PASSWORD=//')" \
  --authenticationDatabase admin \
  --archive=/tmp/emergency-backup.gz --gzip
docker cp "$(docker compose ps -q mongo):/tmp/emergency-backup.gz" ./

# Nuclear option (destroys data)
./cleanup.sh
./setup.sh --domain your.domain.com
docker compose up -d
```

## Useful Aliases

```bash
# Add to ~/.bashrc or ~/.zshrc
alias ns-status='./list-instances.sh'
alias ns-logs='docker compose logs -f'
alias ns-restart='docker compose restart'
alias ns-up='docker compose up -d'
alias ns-down='docker compose down'
alias ns-validate='./validate.sh'
```
