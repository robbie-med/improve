#!/usr/bin/env bash
# migrate_backup.sh — Run ON THE OLD SERVER (shocknode / E5.Flex)
# Creates a complete, restorable backup of the entire self-hosted stack.
#
# Usage: sudo bash migrate_backup.sh
# Then transfer the output file off the server:
#   scp -i ~/.ssh/YOUR_KEY ubuntu@163.192.204.116:~/migration_backup_*.tar.gz .

set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STAGING="/tmp/migration_${TIMESTAMP}"
ARCHIVE=~/migration_backup_${TIMESTAMP}.tar.gz

echo "============================================================"
echo "  shocknode Migration Backup"
echo "  Staging: $STAGING"
echo "  Output:  $ARCHIVE"
echo "============================================================"
echo

mkdir -p "$STAGING"/{compose,env,db-dumps,volumes,system,npm}

# ── 1. All docker-compose files and .env files ────────────────────────────────
echo "[1/8] Copying compose files and .env files..."
for d in /home/ubuntu/docker/*/; do
  name=$(basename "$d")
  dest="$STAGING/compose/$name"
  mkdir -p "$dest"
  [ -f "$d/docker-compose.yml" ]  && cp "$d/docker-compose.yml"  "$dest/"
  [ -f "$d/docker-compose.yaml" ] && cp "$d/docker-compose.yaml" "$dest/"
  [ -f "$d/.env" ]                && cp "$d/.env"                "$dest/dotenv"
  # Any other yaml/config files
  find "$d" -maxdepth 1 -name "*.yml" -o -name "*.yaml" -o -name "*.json" \
    -o -name "*.toml" -o -name "*.conf" 2>/dev/null | while read -r f; do
      cp "$f" "$dest/" 2>/dev/null || true
    done
  echo "  Saved: $d"
done

# ── 2. Secrets file ───────────────────────────────────────────────────────────
echo "[2/8] Copying secrets..."
for f in /home/ubuntu/docker/SECRETS-*.md; do
  [ -f "$f" ] && cp "$f" "$STAGING/env/" && echo "  Saved: $f"
done

# ── 3. PostgreSQL logical dump (all databases) ────────────────────────────────
echo "[3/8] Dumping PostgreSQL (all databases)..."
docker exec shared-postgres pg_dumpall -U postgres \
  > "$STAGING/db-dumps/postgres_all.sql" \
  && echo "  postgres_all.sql: $(du -sh "$STAGING/db-dumps/postgres_all.sql" | cut -f1)"

# Individual per-database dumps for easier selective restore
for db in gitea keycloak n8n twenty haven; do
  docker exec shared-postgres pg_dump -U postgres "$db" \
    > "$STAGING/db-dumps/postgres_${db}.sql" 2>/dev/null \
    && echo "  postgres_${db}.sql: $(du -sh "$STAGING/db-dumps/postgres_${db}.sql" | cut -f1)" \
    || echo "  WARN: $db not found in postgres (skip)"
done

# ── 4. MariaDB logical dump ───────────────────────────────────────────────────
echo "[4/8] Dumping MariaDB..."
MARIADB_ROOT_PW=$(grep MARIADB_ROOT_PASSWORD /home/ubuntu/docker/shared-db/.env | cut -d= -f2-)
docker exec shared-mariadb mariadb-dump \
  -uroot -p"${MARIADB_ROOT_PW}" \
  --all-databases --single-transaction \
  > "$STAGING/db-dumps/mariadb_all.sql" \
  && echo "  mariadb_all.sql: $(du -sh "$STAGING/db-dumps/mariadb_all.sql" | cut -f1)"

# Individual per-database dumps
for db in nextcloud bookstack myidlers; do
  docker exec shared-mariadb mariadb-dump \
    -uroot -p"${MARIADB_ROOT_PW}" --single-transaction "$db" \
    > "$STAGING/db-dumps/mariadb_${db}.sql" 2>/dev/null \
    && echo "  mariadb_${db}.sql: $(du -sh "$STAGING/db-dumps/mariadb_${db}.sql" | cut -f1)" \
    || echo "  WARN: $db not found in mariadb (skip)"
done

# ── 5. Named Docker volumes (app data) ───────────────────────────────────────
echo "[5/8] Backing up Docker volumes..."
VOLUMES=(
  home-lifestyle_traggo_data
  home-lifestyle_homebox_data
  home-lifestyle_wedding_uploads
  home-lifestyle_lubelog_data
  home-lifestyle_haven_storage
  home-lifestyle_karakeep_data
  home-lifestyle_karakeep_meili
  dev-identity_gitea_data
  dev-identity_pb_data
  dev-identity_pb_public
  dev-identity_pb_hooks
  docs_bookstack_config
  docs_privatebin_data
  boards-crm_wekan_db
  boards-crm_twenty_local
  automation_n8n_data
  nextcloud_nextcloud_config
  nextcloud_nextcloud_data
  shared-cache_shared_redis_data
)

for vol in "${VOLUMES[@]}"; do
  if docker volume inspect "$vol" &>/dev/null; then
    echo -n "  $vol ... "
    docker run --rm \
      -v "${vol}:/data:ro" \
      -v "$STAGING/volumes:/backup" \
      alpine tar czf "/backup/${vol}.tar.gz" -C /data . \
      && echo "$(du -sh "$STAGING/volumes/${vol}.tar.gz" | cut -f1)" \
      || echo "FAILED"
  else
    echo "  SKIP: $vol (not found)"
  fi
done

# Also check for any volumes we might have missed
echo "  Checking for unlisted volumes..."
docker volume ls -q | grep -E '^(home-lifestyle|dev-identity|docs|boards-crm|automation|nextcloud|shared)' \
  | while read -r vol; do
    if [ ! -f "$STAGING/volumes/${vol}.tar.gz" ]; then
      echo -n "  (unlisted) $vol ... "
      docker run --rm \
        -v "${vol}:/data:ro" \
        -v "$STAGING/volumes:/backup" \
        alpine tar czf "/backup/${vol}.tar.gz" -C /data . \
        && echo "$(du -sh "$STAGING/volumes/${vol}.tar.gz" | cut -f1)" \
        || echo "FAILED"
    fi
  done

# ── 6. NPM proxy host list (export via API) ───────────────────────────────────
echo "[6/8] Exporting NPM proxy host list..."
# Try to get token (update if you changed creds)
NPM_EMAIL="${NPM_EMAIL:-admin@example.com}"
NPM_PASS="${NPM_PASS:-changeme}"

TOKEN=$(curl -s -X POST "http://127.0.0.1:81/api/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${NPM_EMAIL}\",\"secret\":\"${NPM_PASS}\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null \
  || echo "")

if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
  curl -s "http://127.0.0.1:81/api/nginx/proxy-hosts" \
    -H "Authorization: Bearer ${TOKEN}" \
    > "$STAGING/npm/proxy_hosts.json" \
    && echo "  Saved $(python3 -c "import json,sys; h=json.load(open('$STAGING/npm/proxy_hosts.json')); print(len(h))" 2>/dev/null || echo '?') proxy hosts"
else
  echo "  WARN: Could not auth to NPM — skipping proxy host export"
  echo "  Set NPM_EMAIL and NPM_PASS env vars before running if needed"
fi

# ── 7. Homarr database ────────────────────────────────────────────────────────
echo "[7/8] Backing up Homarr..."
mkdir -p "$STAGING/homarr"
if [ -d /home/ubuntu/homarr/appdata ]; then
  cp -a /home/ubuntu/homarr/appdata "$STAGING/homarr/" 2>/dev/null \
    || sudo cp -a /home/ubuntu/homarr/appdata "$STAGING/homarr/" \
    && echo "  Homarr appdata saved"
fi

# ── 8. System / SSH / host config ────────────────────────────────────────────
echo "[8/8] System config..."
cp /etc/hosts "$STAGING/system/" 2>/dev/null || true
cp /etc/environment "$STAGING/system/" 2>/dev/null || true
for u in /home/ubuntu /root; do
  if [ -d "$u/.ssh" ]; then
    name=$(basename "$u")
    mkdir -p "$STAGING/system/ssh_$name"
    cp -a "$u/.ssh/authorized_keys" "$STAGING/system/ssh_$name/" 2>/dev/null || true
  fi
done

# Also grab the selfhost-plan directory
if [ -d /home/ubuntu/selfhost-plan ]; then
  cp -a /home/ubuntu/selfhost-plan "$STAGING/system/" \
    && echo "  Saved selfhost-plan"
fi

# ── Create archive ────────────────────────────────────────────────────────────
echo
echo "Creating archive..."
tar czf "$ARCHIVE" -C "$(dirname "$STAGING")" "$(basename "$STAGING")"
rm -rf "$STAGING"

ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | cut -f1)

echo
echo "============================================================"
echo "  BACKUP COMPLETE"
echo "  Archive: $ARCHIVE"
echo "  Size:    $ARCHIVE_SIZE"
echo "============================================================"
echo
echo "Transfer to your local machine:"
echo "  scp -i ~/.ssh/YOUR_KEY ubuntu@163.192.204.116:$ARCHIVE ."
echo
echo "Then scp to new server after provisioning:"
echo "  scp -i ~/.ssh/YOUR_KEY $ARCHIVE ubuntu@NEW_SERVER_IP:~/"
