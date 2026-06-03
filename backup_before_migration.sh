#!/usr/bin/env bash
# backup_before_migration.sh — Run ON the server before migrating.
# Creates a single timestamped archive of all critical data.
# Usage: sudo bash backup_before_migration.sh
# Then scp the resulting file off the server:
#   scp -i ~/.ssh/your_key user@SERVER_IP:~/oracle_backup_*.tar.gz .

set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/oracle_backup_staging_${TIMESTAMP}"
ARCHIVE_NAME="oracle_backup_${TIMESTAMP}.tar.gz"
DEST=~/"${ARCHIVE_NAME}"

echo "=== Oracle VPS Backup Script ==="
echo "Staging directory: $BACKUP_DIR"
echo "Final archive: $DEST"
echo

mkdir -p "$BACKUP_DIR"

# ── Helper ──────────────────────────────────────────────────────────────────
copy_if_exists() {
  local src="$1"
  local dst="$BACKUP_DIR/$2"
  if [ -e "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst" 2>/dev/null && echo "  [OK] $src" || echo "  [WARN] Could not copy $src"
  fi
}

copy_dir_if_exists() {
  local src="$1"
  local dst="$BACKUP_DIR/$2"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    cp -a "$src/." "$dst/" 2>/dev/null && echo "  [OK] $src" || echo "  [WARN] Could not copy $src"
  fi
}

# ── System config ────────────────────────────────────────────────────────────
echo "[1/10] System configuration files..."
copy_if_exists /etc/hosts                    etc/hosts
copy_if_exists /etc/resolv.conf              etc/resolv.conf
copy_if_exists /etc/fstab                    etc/fstab
copy_if_exists /etc/environment              etc/environment
copy_if_exists /etc/profile                  etc/profile
copy_dir_if_exists /etc/profile.d            etc/profile.d
copy_if_exists /etc/ssh/sshd_config          etc/ssh/sshd_config
copy_dir_if_exists /etc/ssh/sshd_config.d    etc/ssh/sshd_config.d

# ── User SSH keys ────────────────────────────────────────────────────────────
echo "[2/10] SSH authorized keys..."
copy_dir_if_exists /root/.ssh                root/ssh
for u in /home/*/; do
  uname=$(basename "$u")
  copy_dir_if_exists "$u/.ssh"  "home/${uname}/ssh"
done

# ── Nginx ────────────────────────────────────────────────────────────────────
echo "[3/10] Nginx config..."
copy_dir_if_exists /etc/nginx                etc/nginx

# ── Caddy ────────────────────────────────────────────────────────────────────
echo "[4/10] Caddy config..."
copy_dir_if_exists /etc/caddy                etc/caddy
copy_dir_if_exists /usr/local/etc/caddy      usr/local/etc/caddy

# ── Cloudflare Tunnel ────────────────────────────────────────────────────────
echo "[5/10] Cloudflare tunnel config..."
copy_dir_if_exists /etc/cloudflared                     etc/cloudflared
copy_dir_if_exists /root/.cloudflared                   root/cloudflared
for u in /home/*/; do
  uname=$(basename "$u")
  copy_dir_if_exists "$u/.cloudflared"  "home/${uname}/cloudflared"
done

# ── SSL certificates ─────────────────────────────────────────────────────────
echo "[6/10] SSL certificates..."
copy_dir_if_exists /etc/letsencrypt          etc/letsencrypt
copy_dir_if_exists /root/.acme.sh            root/acme.sh
for u in /home/*/; do
  uname=$(basename "$u")
  copy_dir_if_exists "$u/.acme.sh"   "home/${uname}/acme.sh"
done

# ── Custom systemd units ──────────────────────────────────────────────────────
echo "[7/10] Custom systemd unit files..."
mkdir -p "$BACKUP_DIR/etc/systemd/system"
# Copy only non-package-managed unit files
find /etc/systemd/system /lib/systemd/system /usr/local/lib/systemd \
     -name "*.service" -o -name "*.timer" -o -name "*.socket" 2>/dev/null \
  | while read -r f; do
      dpkg -S "$f" &>/dev/null 2>&1 || {
        cp -a "$f" "$BACKUP_DIR/etc/systemd/system/" 2>/dev/null && echo "  [OK] $f" || true
      }
    done

# ── Cron jobs ────────────────────────────────────────────────────────────────
echo "[8/10] Cron jobs..."
mkdir -p "$BACKUP_DIR/cron"
crontab -l 2>/dev/null > "$BACKUP_DIR/cron/root_crontab" || touch "$BACKUP_DIR/cron/root_crontab"
copy_if_exists /etc/crontab       etc/crontab
copy_dir_if_exists /etc/cron.d    etc/cron.d
for u in $(cut -d: -f1 /etc/passwd); do
  tab=$(crontab -l -u "$u" 2>/dev/null) && {
    echo "$tab" > "$BACKUP_DIR/cron/${u}_crontab"
    echo "  [OK] crontab for $u"
  } || true
done

# ── Docker: volumes and compose files ────────────────────────────────────────
echo "[9/10] Docker compose files and volumes..."
# Compose files
mkdir -p "$BACKUP_DIR/docker/compose"
find / -name "docker-compose.yml" -o -name "docker-compose.yaml" \
       -o -name "compose.yml" -o -name "compose.yaml" 2>/dev/null \
  | grep -v '/proc/' | grep -v '/sys/' \
  | while read -r f; do
      dir=$(dirname "$f")
      safe=$(echo "$dir" | tr '/' '_')
      dest="$BACKUP_DIR/docker/compose/$safe"
      mkdir -p "$dest"
      # Also grab .env files next to compose files
      cp -a "$f" "$dest/" 2>/dev/null || true
      [ -f "$dir/.env" ] && cp -a "$dir/.env" "$dest/dotenv" 2>/dev/null || true
      # Grab entire app directory if small enough (<500MB)
      size_mb=$(du -sm "$dir" 2>/dev/null | cut -f1 || echo 9999)
      if [ "$size_mb" -lt 500 ]; then
        cp -a "$dir" "$dest/app_dir" 2>/dev/null || true
        echo "  [OK] $f (+ app dir, ${size_mb}MB)"
      else
        echo "  [OK] $f only (app dir too large: ${size_mb}MB — back up manually)"
      fi
    done

# Docker volumes (named volumes via docker cp)
if command -v docker &>/dev/null; then
  mkdir -p "$BACKUP_DIR/docker/volumes"
  docker volume ls -q 2>/dev/null | while read -r vol; do
    echo "  Backing up Docker volume: $vol"
    docker run --rm \
      -v "${vol}:/data:ro" \
      -v "$BACKUP_DIR/docker/volumes:/backup" \
      alpine tar czf "/backup/${vol}.tar.gz" -C /data . 2>/dev/null \
      && echo "  [OK] volume $vol" \
      || echo "  [WARN] Could not back up volume $vol"
  done
fi

# ── App data directories ─────────────────────────────────────────────────────
echo "[10/10] /opt, /srv, /var/www, /app, /data..."
for d in /opt /srv /var/www /app /data; do
  if [ -d "$d" ]; then
    size_mb=$(du -sm "$d" 2>/dev/null | cut -f1 || echo 9999)
    if [ "$size_mb" -lt 2000 ]; then
      copy_dir_if_exists "$d" "${d#/}"
    else
      echo "  [WARN] $d is ${size_mb}MB — too large to auto-include. Back up manually."
      # Still grab any .env / config files within it
      find "$d" -name ".env" -o -name "*.env" -o -name "*.conf" -o -name "*.yml" \
                -o -name "*.yaml" -o -name "*.toml" -o -name "*.json" 2>/dev/null \
        | head -200 | while read -r f; do
            rel="${f#/}"
            mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
            cp -a "$f" "$BACKUP_DIR/$rel" 2>/dev/null || true
          done
      echo "  [OK] Config/env files from $d extracted"
    fi
  fi
done

# ── Dump inventory snapshot ───────────────────────────────────────────────────
echo
echo "Generating quick inventory snapshot..."
mkdir -p "$BACKUP_DIR/inventory"
{
  echo "=== SYSTEMD ENABLED SERVICES ==="
  systemctl list-unit-files --state=enabled --no-pager 2>/dev/null || true
  echo
  echo "=== DOCKER CONTAINERS ==="
  docker ps -a 2>/dev/null || echo "Docker not available"
  echo
  echo "=== OPEN PORTS ==="
  ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true
  echo
  echo "=== DISK USAGE ==="
  df -h
  echo
  echo "=== MEMORY ==="
  free -h
  echo
  echo "=== ENV FILE LOCATIONS (keys only, no values) ==="
  find /etc /opt /srv /var/www /home /root /app /data \
       -name ".env" -o -name "*.env" -o -name ".env.*" 2>/dev/null \
    | grep -v '/proc/' | while read -r f; do
        echo "--- $f ---"
        grep -E '^[A-Z_][A-Z0-9_]*=' "$f" 2>/dev/null | cut -d= -f1 | sort || true
      done
} > "$BACKUP_DIR/inventory/snapshot.txt" 2>&1

# ── Create archive ────────────────────────────────────────────────────────────
echo
echo "Creating archive: $DEST"
tar czf "$DEST" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")"

# Cleanup staging
rm -rf "$BACKUP_DIR"

ARCHIVE_SIZE=$(du -sh "$DEST" | cut -f1)
echo
echo "============================================================"
echo "  BACKUP COMPLETE"
echo "  Archive: $DEST"
echo "  Size:    $ARCHIVE_SIZE"
echo "============================================================"
echo
echo "Transfer to your local machine:"
echo "  scp -i ~/.ssh/YOUR_KEY $(whoami)@YOUR_SERVER_IP:$DEST ."
echo
echo "NOTE: Docker volumes with databases may need a logical dump too."
echo "For PostgreSQL:  docker exec CONTAINER pg_dumpall -U postgres > pg_backup.sql"
echo "For MySQL:       docker exec CONTAINER mysqldump -u root -p --all-databases > mysql_backup.sql"
echo "For MongoDB:     docker exec CONTAINER mongodump --archive --gzip > mongo_backup.gz"
