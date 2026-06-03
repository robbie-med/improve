#!/usr/bin/env bash
# oracle_inventory.sh — Run this ON the server to collect a full audit.
# Output is saved to ~/server_inventory.txt and printed to stdout.
# Usage: bash oracle_inventory.sh | tee ~/server_inventory.txt

set -euo pipefail
OUT=~/server_inventory.txt
exec > >(tee "$OUT") 2>&1

HR="============================================================"
section() { echo; echo "$HR"; echo "  $1"; echo "$HR"; }

section "DATE / HOSTNAME / UPTIME"
date; hostname -f; uptime; uname -a

section "RESOURCE USAGE — CPU / RAM / DISK"
free -h
echo "---"
df -h
echo "---"
echo "Top processes by RAM:"
ps aux --sort=-%mem | head -20

section "SYSTEMD SERVICES — ENABLED"
systemctl list-unit-files --state=enabled --no-pager 2>/dev/null || true

section "SYSTEMD SERVICES — RUNNING"
systemctl list-units --type=service --state=running --no-pager 2>/dev/null || true

section "SYSTEMD TIMERS"
systemctl list-timers --all --no-pager 2>/dev/null || true

section "OPEN PORTS (ss -tlnp)"
ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "Neither ss nor netstat available"

section "OPEN UDP PORTS (ss -ulnp)"
ss -ulnp 2>/dev/null || true

section "FIREWALL RULES"
if command -v iptables &>/dev/null; then iptables -L -n --line-numbers 2>/dev/null || true; fi
if command -v ufw &>/dev/null; then ufw status verbose 2>/dev/null || true; fi
if command -v firewall-cmd &>/dev/null; then firewall-cmd --list-all 2>/dev/null || true; fi

section "DOCKER — CONTAINERS (docker ps -a)"
if command -v docker &>/dev/null; then
  docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
  echo "---"
  echo "Docker images:"
  docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
  echo "---"
  echo "Docker volumes:"
  docker volume ls
  echo "---"
  echo "Docker networks:"
  docker network ls
else
  echo "Docker not installed"
fi

section "DOCKER COMPOSE PROJECTS"
find / -name "docker-compose.yml" -o -name "docker-compose.yaml" \
       -o -name "compose.yml" -o -name "compose.yaml" 2>/dev/null \
  | grep -v '/proc/' | grep -v '/sys/' || echo "None found"

section "DOCKER COMPOSE — CONTENT OF EACH FILE"
for f in $(find / -name "docker-compose.yml" -o -name "docker-compose.yaml" \
                  -o -name "compose.yml" -o -name "compose.yaml" 2>/dev/null \
           | grep -v '/proc/' | grep -v '/sys/'); do
  echo; echo ">>> $f"; cat "$f"
done

section "NGINX CONFIG"
if command -v nginx &>/dev/null; then
  echo "Nginx version: $(nginx -v 2>&1)"
  echo "--- /etc/nginx/nginx.conf ---"
  cat /etc/nginx/nginx.conf 2>/dev/null || true
  echo "--- sites-enabled ---"
  ls -la /etc/nginx/sites-enabled/ 2>/dev/null || true
  for f in /etc/nginx/sites-enabled/*; do
    [ -f "$f" ] && echo && echo ">>> $f" && cat "$f"
  done
  echo "--- conf.d ---"
  for f in /etc/nginx/conf.d/*; do
    [ -f "$f" ] && echo && echo ">>> $f" && cat "$f"
  done
else
  echo "Nginx not installed"
fi

section "CADDY CONFIG"
if command -v caddy &>/dev/null; then
  echo "Caddy version: $(caddy version 2>&1)"
  for f in /etc/caddy/Caddyfile /usr/local/etc/caddy/Caddyfile ~/.config/caddy/Caddyfile; do
    [ -f "$f" ] && echo ">>> $f" && cat "$f"
  done
else
  echo "Caddy not installed"
fi

section "APACHE CONFIG"
if command -v apache2 &>/dev/null || command -v httpd &>/dev/null; then
  for dir in /etc/apache2 /etc/httpd; do
    [ -d "$dir" ] && find "$dir" -name "*.conf" -exec echo ">>> {}" \; -exec cat {} \;
  done
else
  echo "Apache not installed"
fi

section "CLOUDFLARE TUNNEL"
for d in ~/.cloudflared /etc/cloudflared /root/.cloudflared; do
  if [ -d "$d" ]; then
    echo "Found: $d"
    ls -la "$d"
    for f in "$d"/*.json "$d"/*.yml "$d"/*.yaml "$d"/*.toml; do
      [ -f "$f" ] && echo ">>> $f" && cat "$f"
    done
  fi
done
# Check systemd service
systemctl cat cloudflared 2>/dev/null || true

section "CRON JOBS — ALL USERS"
echo "=== root crontab ==="
crontab -l 2>/dev/null || echo "(empty)"
echo "=== /etc/crontab ==="
cat /etc/crontab 2>/dev/null || true
echo "=== /etc/cron.d/* ==="
for f in /etc/cron.d/*; do [ -f "$f" ] && echo ">>> $f" && cat "$f"; done
echo "=== /etc/cron.daily/* ==="
ls /etc/cron.daily/ 2>/dev/null || true
echo "=== Other user crontabs ==="
for user in $(cut -d: -f1 /etc/passwd); do
  tab=$(crontab -l -u "$user" 2>/dev/null) && echo "--- $user ---" && echo "$tab" || true
done

section "ENV FILES (paths only — values redacted)"
find /etc /opt /srv /var/www /home /root /app /data \
     -name ".env" -o -name "*.env" -o -name ".env.*" 2>/dev/null \
  | grep -v '/proc/' | grep -v '/sys/' \
  | while read -r f; do
      echo ">>> $f"
      # Print only the variable NAMES, not values
      grep -E '^[A-Z_][A-Z0-9_]*=' "$f" 2>/dev/null | cut -d= -f1 | sort || true
    done

section "INSTALLED PACKAGES (user-relevant, non-base)"
if command -v dpkg &>/dev/null; then
  dpkg --get-selections | grep -v deinstall
elif command -v rpm &>/dev/null; then
  rpm -qa --qf '%{NAME}\n' | sort
fi

section "SNAP PACKAGES"
snap list 2>/dev/null || echo "Snap not available"

section "PIP / PYTHON PACKAGES (global)"
pip3 list 2>/dev/null || pip list 2>/dev/null || echo "pip not found"

section "NODE / NPM GLOBAL PACKAGES"
npm list -g --depth=0 2>/dev/null || echo "npm not found"

section "DIRECTORIES — /opt"
find /opt -maxdepth 3 -ls 2>/dev/null || echo "(empty or missing)"

section "DIRECTORIES — /srv"
find /srv -maxdepth 3 -ls 2>/dev/null || echo "(empty or missing)"

section "DIRECTORIES — /var/www"
find /var/www -maxdepth 3 -ls 2>/dev/null || echo "(empty or missing)"

section "DIRECTORIES — /app /data /home"
for d in /app /data; do
  [ -d "$d" ] && find "$d" -maxdepth 3 -ls 2>/dev/null || true
done
ls -la /home/ 2>/dev/null || true
for u in /home/*/; do
  echo "=== $u ==="; ls -la "$u" 2>/dev/null || true
done

section "ROOT HOME"
ls -la /root/ 2>/dev/null || echo "(no access or empty)"

section "SYSTEMD SERVICE FILES (custom, non-package)"
find /etc/systemd /lib/systemd/system /usr/local/lib/systemd \
     -name "*.service" 2>/dev/null \
  | xargs grep -l "ExecStart" 2>/dev/null \
  | while read -r f; do
      # Only show non-package services (heuristic: no dpkg owner)
      dpkg -S "$f" &>/dev/null || { echo ">>> $f (custom)"; cat "$f"; }
    done

section "SSL CERTIFICATES"
find /etc/ssl /etc/letsencrypt /root/.acme.sh ~/.acme.sh \
     -name "*.crt" -o -name "*.pem" -o -name "fullchain.pem" 2>/dev/null \
  | grep -v '/proc/' | while read -r f; do
      echo ">>> $f"
      openssl x509 -in "$f" -noout -subject -dates 2>/dev/null || true
    done

section "NETWORK INTERFACES"
ip addr show
ip route show

section "HOSTS FILE"
cat /etc/hosts

section "RESOLV.CONF"
cat /etc/resolv.conf

section "SSHD CONFIG (key settings)"
grep -E '^(Port|PermitRootLogin|PasswordAuthentication|AuthorizedKeysFile|AllowUsers|AllowGroups)' \
  /etc/ssh/sshd_config 2>/dev/null || true

section "AUTHORIZED KEYS"
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [ -f "$f" ] && echo ">>> $f" && cat "$f"
done

echo
echo "$HR"
echo "  INVENTORY COMPLETE — saved to $OUT"
echo "$HR"
