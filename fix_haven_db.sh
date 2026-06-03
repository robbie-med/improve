#!/usr/bin/env bash
# fix_haven_db.sh
# Fixes the Haven DB connection by syncing the haven_user password between
# Postgres and the docker-compose .env file, then restarts Haven.
#
# Run ON THE SERVER with: sudo bash fix_haven_db.sh

set -euo pipefail

ENV_FILE="/home/ubuntu/docker/home-lifestyle/.env"
COMPOSE_DIR="/home/ubuntu/docker/home-lifestyle"

echo "=== Haven DB Fix ==="

# Read current password from .env
HAVEN_DB_PASSWORD=$(grep '^HAVEN_DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)

if [ -z "$HAVEN_DB_PASSWORD" ]; then
  echo "ERROR: HAVEN_DB_PASSWORD not found in $ENV_FILE"
  exit 1
fi

echo "HAVEN_DB_PASSWORD found: ${HAVEN_DB_PASSWORD:0:8}..."

# Update haven_user in Postgres
echo "Updating haven_user password in shared-postgres..."
docker exec shared-postgres psql -U postgres -d postgres \
  -c "ALTER USER haven_user WITH PASSWORD '${HAVEN_DB_PASSWORD}';" \
  && echo "  Postgres updated OK" \
  || { echo "  ERROR updating Postgres"; exit 1; }

# Also ensure haven_user has CREATEDB (needed for Rails db:create)
echo "Granting CREATEDB to haven_user..."
docker exec shared-postgres psql -U postgres -d postgres \
  -c "ALTER USER haven_user CREATEDB;" \
  && echo "  CREATEDB granted OK"

# Check if haven DB exists; create if not
echo "Checking if 'haven' database exists..."
DB_EXISTS=$(docker exec shared-postgres psql -U postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='haven';" 2>/dev/null || echo "")

if [ "$DB_EXISTS" != "1" ]; then
  echo "Creating 'haven' database..."
  docker exec shared-postgres psql -U postgres -d postgres \
    -c "CREATE DATABASE haven OWNER haven_user;" \
    && echo "  Database created OK"
else
  echo "  Database 'haven' already exists"
fi

# Force recreate haven container
echo "Force-recreating Haven container..."
cd "$COMPOSE_DIR"
docker compose up -d --force-recreate haven
echo "  Haven restarted"

# Wait and check logs
echo "Waiting 15 seconds for Haven to initialize..."
sleep 15

echo "Haven container status:"
docker ps --format '{{.Names}}\t{{.Status}}' | grep '^haven'

echo
echo "Recent Haven logs:"
docker logs --tail 30 haven 2>&1 || true

echo
echo "=== Done ==="
echo "If Haven still shows restart loops, check: docker logs haven"
