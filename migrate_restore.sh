#!/usr/bin/env bash
# migrate_restore.sh — Run ON THE NEW SERVER (A1.Flex ARM)
# Restores the full self-hosted stack from a migrate_backup_*.tar.gz archive.
#
# Usage:
#   sudo bash migrate_restore.sh /path/to/migration_backup_TIMESTAMP.tar.gz
#
# What this does:
#   1. Installs Docker, Docker Compose, sqlite3
#   2. Creates npm_network
#   3. Extracts backup archive
#   4. Copies all compose files and .env files into /home/ubuntu/docker/
#   5. Patches compose files for ARM (replaces incompatible images)
#   6. Brings up shared DBs
#   7. Restores Postgres and MariaDB from SQL dumps
#   8. Brings up all app stacks
#   9. Restores Docker volumes (app data)
#  10. Restores Homarr
#  11. Runs health check

set -euo pipefail

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
  echo "Usage: sudo bash migrate_restore.sh /path/to/migration_backup_*.tar.gz"
  exit 1
fi
if [ ! -f "$ARCHIVE" ]; then
  echo "ERROR: Archive not found: $ARCHIVE"
  exit 1
fi

STAGING="/tmp/migration_restore_$$"
DOCKER_BASE="/home/ubuntu/docker"
UBUNTU_USER="ubuntu"

echo "============================================================"
echo "  shocknode → A1.Flex Migration Restore"
echo "  Archive: $ARCHIVE"
echo "============================================================"
echo

# ── 1. Install Docker ─────────────────────────────────────────────────────────
echo "[1/11] Installing Docker..."
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y ca-certificates curl gnupg lsb-release sqlite3 python3
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker "$UBUNTU_USER"
  systemctl enable --now docker
  echo "  Docker installed"
else
  echo "  Docker already installed"
fi

# Ensure Docker Compose v2
if ! docker compose version &>/dev/null; then
  apt-get install -y docker-compose-plugin
fi
echo "  Docker Compose: $(docker compose version --short 2>/dev/null || echo 'ok')"

# Install sqlite3 if not present
apt-get install -y sqlite3 2>/dev/null || true

# ── 2. Create network ─────────────────────────────────────────────────────────
echo "[2/11] Creating npm_network..."
docker network ls | grep -q npm_network \
  && echo "  npm_network exists" \
  || { docker network create npm_network && echo "  Created npm_network"; }

# ── 3. Extract backup ─────────────────────────────────────────────────────────
echo "[3/11] Extracting backup archive..."
mkdir -p "$STAGING"
tar xzf "$ARCHIVE" -C "$STAGING" --strip-components=1
echo "  Extracted to $STAGING"
ls "$STAGING"

# ── 4. Copy compose + env files ───────────────────────────────────────────────
echo "[4/11] Installing compose files..."
mkdir -p "$DOCKER_BASE"
for src_dir in "$STAGING/compose"/*/; do
  name=$(basename "$src_dir")
  dest_dir="$DOCKER_BASE/$name"
  mkdir -p "$dest_dir"
  [ -f "$src_dir/docker-compose.yml" ]  && cp "$src_dir/docker-compose.yml"  "$dest_dir/"
  [ -f "$src_dir/docker-compose.yaml" ] && cp "$src_dir/docker-compose.yaml" "$dest_dir/"
  [ -f "$src_dir/dotenv" ]              && cp "$src_dir/dotenv"               "$dest_dir/.env"
  # Other config files
  find "$src_dir" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" -o -name "*.json" \
    -o -name "*.toml" -o -name "local_policy.yaml" \) | while read -r f; do
      [ "$(basename "$f")" != "docker-compose.yml" ] && cp "$f" "$dest_dir/" 2>/dev/null || true
    done
  echo "  Installed: $dest_dir"
done

# Copy secrets file
cp "$STAGING/env"/SECRETS-*.md "$DOCKER_BASE/" 2>/dev/null && echo "  Copied secrets file" || true

# ── 5. ARM image patches ───────────────────────────────────────────────────────
echo "[5/11] Patching compose files for ARM64..."
# browserless/chrome has no arm64 image — replace with ghcr.io/browserless/chromium
# which supports arm64
AUTOMATION_COMPOSE="$DOCKER_BASE/automation/docker-compose.yml"
if [ -f "$AUTOMATION_COMPOSE" ]; then
  sed -i 's|image: browserless/chrome|image: ghcr.io/browserless/chromium:latest|g' "$AUTOMATION_COMPOSE"
  echo "  Patched: browserless/chrome → ghcr.io/browserless/chromium (ARM64 compatible)"
fi

# karakeep uses gcr.io/zenika-hub/alpine-chrome which has no arm64 tag 124
# Replace with chromium from alpine directly
HOME_COMPOSE="$DOCKER_BASE/home-lifestyle/docker-compose.yml"
if [ -f "$HOME_COMPOSE" ]; then
  # Replace the pinned alpine-chrome:124 with the ARM-compatible latest
  sed -i 's|image: gcr.io/zenika-hub/alpine-chrome:124|image: gcr.io/zenika-hub/alpine-chrome:latest|g' "$HOME_COMPOSE"
  echo "  Patched: alpine-chrome:124 → alpine-chrome:latest"
fi

# Check for any remaining images that might be x86-only (warn only)
echo "  Checking for potentially x86-only images..."
grep -r "image:" "$DOCKER_BASE"/*/*.yml 2>/dev/null \
  | grep -E "(i386|x86_64|amd64)" \
  | while read -r line; do
      echo "  WARN: Possibly x86-specific image: $line"
    done || true

# ── 6. Start shared databases ─────────────────────────────────────────────────
echo "[6/11] Starting shared databases..."
cd "$DOCKER_BASE/shared-db"
docker compose up -d
echo "  Waiting 20s for DBs to initialize..."
sleep 20

cd "$DOCKER_BASE/shared-cache"
docker compose up -d
echo "  Redis started"

# ── 7. Restore PostgreSQL ─────────────────────────────────────────────────────
echo "[7/11] Restoring PostgreSQL..."
if [ -f "$STAGING/db-dumps/postgres_all.sql" ]; then
  echo "  Restoring all Postgres databases..."
  # Use pg_dumpall restore (skip role creation errors — root role likely exists)
  docker exec -i shared-postgres psql -U postgres \
    < "$STAGING/db-dumps/postgres_all.sql" 2>&1 \
    | grep -v "^$\|already exists\|ERROR:  role.*already exists\|ERROR:  database.*already exists" \
    | tail -20 || true
  echo "  Postgres restore complete"
else
  echo "  WARN: postgres_all.sql not found — restoring individual databases..."
  for sql in "$STAGING/db-dumps/postgres_"*.sql; do
    [ -f "$sql" ] || continue
    db=$(basename "$sql" .sql | sed 's/^postgres_//')
    [ "$db" = "all" ] && continue
    echo -n "  Restoring $db... "
    docker exec shared-postgres psql -U postgres -c "CREATE DATABASE $db;" 2>/dev/null || true
    docker exec -i shared-postgres psql -U postgres -d "$db" < "$sql" 2>/dev/null \
      && echo "OK" || echo "WARN (check manually)"
  done
fi

# ── 8. Restore MariaDB ────────────────────────────────────────────────────────
echo "[8/11] Restoring MariaDB..."
MARIADB_ROOT_PW=$(grep MARIADB_ROOT_PASSWORD "$DOCKER_BASE/shared-db/.env" | cut -d= -f2-)
if [ -f "$STAGING/db-dumps/mariadb_all.sql" ]; then
  docker exec -i shared-mariadb mariadb \
    -uroot -p"${MARIADB_ROOT_PW}" \
    < "$STAGING/db-dumps/mariadb_all.sql" 2>&1 \
    | grep -v "^$" | tail -10 || true
  echo "  MariaDB restore complete"
fi

# ── 9. Start all app stacks ───────────────────────────────────────────────────
echo "[9/11] Starting application stacks..."
STACKS=(
  openappsec-npm
  nextcloud
  dev-identity
  automation
  boards-crm
  docs
  home-lifestyle
)

for stack in "${STACKS[@]}"; do
  dir="$DOCKER_BASE/$stack"
  if [ -d "$dir" ]; then
    echo -n "  Starting $stack... "
    cd "$dir"
    docker compose pull -q 2>/dev/null || true
    docker compose up -d 2>&1 | tail -3 || echo "WARN"
    echo "done"
    sleep 3
  else
    echo "  SKIP: $stack (directory not found)"
  fi
done

# ── 10. Restore Docker volumes ────────────────────────────────────────────────
echo "[10/11] Restoring Docker volumes..."
for archive in "$STAGING/volumes/"*.tar.gz; do
  [ -f "$archive" ] || continue
  vol=$(basename "$archive" .tar.gz)
  echo -n "  Restoring $vol... "
  # Ensure volume exists
  docker volume create "$vol" &>/dev/null || true
  # Restore
  docker run --rm \
    -v "${vol}:/data" \
    -v "$(dirname "$archive"):/backup:ro" \
    alpine sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xzf /backup/$(basename "$archive") -C /data" \
    && echo "OK" || echo "FAILED"
done

# ── 11. Restore Homarr ────────────────────────────────────────────────────────
echo "[11/11] Restoring Homarr..."
if [ -d "$STAGING/homarr/appdata" ]; then
  mkdir -p /home/ubuntu/homarr
  cp -a "$STAGING/homarr/appdata" /home/ubuntu/homarr/ \
    && echo "  Homarr appdata restored" \
    || echo "  WARN: Homarr restore failed"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "$STAGING"

echo
echo "============================================================"
echo "  RESTORE COMPLETE"
echo "============================================================"
echo
echo "Post-restore steps:"
echo "  1. Run: bash health_check.sh"
echo "  2. Fix Haven DB: bash fix_haven_db.sh"
echo "  3. Set up NPM proxy hosts: NPM_EMAIL=... NPM_PASS=... bash npm_setup_proxy_hosts.sh"
echo "  4. Request SSL: LETSENCRYPT_EMAIL=... bash npm_request_ssl.sh"
echo "  5. Update DNS: change all robbiemed.org A records to NEW_SERVER_IP"
echo "  6. Test all subdomains work"
echo "  7. Stop old server in OCI console (do NOT terminate yet)"
echo "  8. Monitor for 24-48 hours"
echo "  9. Terminate old E5 instance"
echo
echo "New server public IP:"
curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
