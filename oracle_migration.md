# Oracle Cloud VPS Migration — Always Free Tier

> **Status:** Template — fill in inventory results from `oracle_inventory.sh`
> **Generated:** 2026-06-03
> **Trigger:** $48.66 invoice for E5 paid compute shape

---

## 1. Service Inventory

> Run `bash oracle_inventory.sh | tee ~/server_inventory.txt` on the server, then
> fill in the table below.

### 1.1 Systemd Services

| Service | Enabled | Running | Description / Purpose |
|---------|---------|---------|----------------------|
| _fill from `systemctl list-unit-files`_ | | | |

### 1.2 Docker Containers

| Container Name | Image | Status | Exposed Ports | Purpose |
|----------------|-------|--------|---------------|---------|
| _fill from `docker ps -a`_ | | | | |

### 1.3 Docker Compose Projects

| File Path | Services | Notes |
|-----------|----------|-------|
| _fill from `find / -name docker-compose.yml`_ | | |

### 1.4 Open Ports

| Port | Protocol | Process | Public? |
|------|----------|---------|---------|
| _fill from `ss -tlnp`_ | | | |

### 1.5 Web Server Virtual Hosts

| Domain | Backend | SSL | Config File |
|--------|---------|-----|-------------|
| _fill from nginx/caddy config_ | | | |

### 1.6 Cron Jobs

| Schedule | Command | User | Purpose |
|----------|---------|------|---------|
| _fill from `crontab -l` and `/etc/cron.d/`_ | | | |

### 1.7 Cloudflare Tunnel

| Tunnel ID | Config File | Services Exposed |
|-----------|-------------|-----------------|
| _fill if present_ | | |

---

## 2. Resource Footprint

> Fill in from `free -h` and `df -h` output.

| Metric | Current Value | Notes |
|--------|---------------|-------|
| Total RAM | | |
| RAM in use | | |
| Swap used | | |
| Disk total | | |
| Disk used | | |
| CPU cores | | |

---

## 3. Target Shape Recommendation

### Option A — VM.Standard.E2.1.Micro (x86)
- **Specs:** 1 OCPU (1 vCPU), 1 GB RAM, 50 GB boot disk
- **Cost:** Always Free
- **Pros:** x86 compatibility, simpler Docker image compatibility
- **Cons:** Very limited RAM — only viable if total container RSS < ~700 MB
- **Verdict:** Only choose this if the inventory shows a single lightweight service
  (e.g., a small static site with Nginx, or one lightweight Node/Python app)

### Option B — VM.Standard.A1.Flex ARM (Recommended in most cases)
- **Specs:** Up to 4 OCPU + 24 GB RAM total across all A1 instances in the tenancy
- **Cost:** Always Free (4 OCPUs + 24 GB total free allocation)
- **Recommended config:** 2 OCPU + 4–8 GB RAM (leaves headroom for more free instances)
- **Pros:** Far more headroom, handles Docker stacks comfortably
- **Cons:** ARM architecture — most popular Docker images have `linux/arm64` variants,
  but some niche images may need `--platform linux/amd64` emulation via QEMU
- **Verdict:** **Choose A1.Flex** unless you have a hard x86-only dependency

### Decision Matrix

| Condition | Recommendation |
|-----------|---------------|
| RAM used > 600 MB | **A1.Flex** (required) |
| Any Docker containers running | **A1.Flex** (strongly preferred) |
| Only static site / simple reverse proxy | Either (E2.Micro is fine) |
| ARM-incompatible binaries | E2.Micro (or fix images) |

**Selected target:** `VM.Standard.A1.Flex` — _confirm after filling inventory_
**Suggested shape config:** 2 OCPU, 4 GB RAM (can expand to 4/24 later within free tier)

---

## 4. Migration Plan

### Phase 0 — Pre-migration (on old server)

```bash
# 1. Run inventory
bash oracle_inventory.sh | tee ~/server_inventory.txt

# 2. Run backup
sudo bash backup_before_migration.sh

# 3. Copy archive to local machine
scp -i ~/.ssh/YOUR_KEY ubuntu@OLD_SERVER_IP:~/oracle_backup_*.tar.gz .

# 4. Verify archive is intact
tar tzf oracle_backup_*.tar.gz | head -50
```

### Phase 1 — Provision New Instance (Oracle Cloud Console)

1. Open Oracle Cloud Console → Compute → Instances → Create Instance
2. **Name:** `vps-free` (or your preference)
3. **Compartment:** (root or your compartment)
4. **Image:** Ubuntu 22.04 (Canonical Ubuntu) — arm64 build
5. **Shape:** VM.Standard.A1.Flex → 2 OCPU, 4 GB RAM
6. **Networking:**
   - Create new VCN or use existing
   - Assign public IP (ephemeral is fine, or reserve a static one)
7. **Boot volume:** 50 GB (free tier limit is 200 GB total across all instances)
8. **SSH keys:** Upload your existing public key
9. Click Create — wait ~3 minutes for provisioning
10. Note the new public IP address

### Phase 2 — Open Firewall in Oracle Security List

In the VCN's Security List (or Network Security Group), ensure inbound rules allow:

| Protocol | Port | Source | Purpose |
|----------|------|--------|---------|
| TCP | 22 | 0.0.0.0/0 | SSH |
| TCP | 80 | 0.0.0.0/0 | HTTP |
| TCP | 443 | 0.0.0.0/0 | HTTPS |
| _others_ | | | |

### Phase 3 — Base Setup on New Server

```bash
ssh ubuntu@NEW_SERVER_IP

# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu
newgrp docker

# Install Docker Compose v2
sudo apt install -y docker-compose-plugin

# Install other base packages
sudo apt install -y \
  git curl wget jq unzip \
  nginx certbot python3-certbot-nginx \
  fail2ban ufw
```

### Phase 4 — Transfer Config and Data

```bash
# From local machine — copy backup archive to new server
scp -i ~/.ssh/YOUR_KEY oracle_backup_*.tar.gz ubuntu@NEW_SERVER_IP:~/

# On new server — extract
cd ~
tar xzf oracle_backup_*.tar.gz
ls oracle_backup_staging_*/
```

### Phase 5 — Restore Services (in order)

1. **Restore SSH config** (carefully — don't lock yourself out)
   ```bash
   # Review first, don't blindly overwrite
   diff oracle_backup_staging_*/etc/ssh/sshd_config /etc/ssh/sshd_config
   ```

2. **Restore Nginx config**
   ```bash
   sudo cp -a oracle_backup_staging_*/etc/nginx/. /etc/nginx/
   sudo nginx -t && sudo systemctl reload nginx
   ```

3. **Restore Cloudflare Tunnel**
   ```bash
   sudo mkdir -p /etc/cloudflared
   sudo cp -a oracle_backup_staging_*/etc/cloudflared/. /etc/cloudflared/
   # Reinstall cloudflared binary
   curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
     -o /usr/local/bin/cloudflared
   chmod +x /usr/local/bin/cloudflared
   sudo cloudflared service install
   sudo systemctl enable --now cloudflared
   ```

4. **Restore Docker Compose projects**
   ```bash
   # For each project found in backup:
   sudo mkdir -p /opt/YOUR_APP
   sudo cp -a oracle_backup_staging_*/docker/compose/_opt_YOUR_APP/app_dir/. /opt/YOUR_APP/
   cd /opt/YOUR_APP
   # Verify/update .env
   docker compose pull
   docker compose up -d
   ```

5. **Restore Docker volumes**
   ```bash
   # For each volume in backup:
   docker volume create VOLUME_NAME
   docker run --rm \
     -v VOLUME_NAME:/data \
     -v ~/oracle_backup_staging_*/docker/volumes:/backup:ro \
     alpine tar xzf /backup/VOLUME_NAME.tar.gz -C /data
   ```

6. **Restore cron jobs**
   ```bash
   crontab oracle_backup_staging_*/cron/root_crontab
   sudo cp oracle_backup_staging_*/etc/cron.d/* /etc/cron.d/
   ```

7. **Restore SSL certs / Let's Encrypt**
   ```bash
   sudo cp -a oracle_backup_staging_*/etc/letsencrypt/. /etc/letsencrypt/
   sudo certbot renew --dry-run
   ```

### Phase 6 — DNS Cutover

1. Log in to your DNS provider (Cloudflare, etc.)
2. Update A record(s) to point to new server IP
3. If using Cloudflare Tunnel, no DNS change needed (tunnel handles routing)
4. TTL flush may take 0–48 hours depending on previous TTL setting

### Phase 7 — Verify (see checklist below)

### Phase 8 — Decommission Old Server

Only after verifying the new server is fully operational:
1. Stop the old OCI instance (do not terminate yet)
2. Monitor for 24–48 hours
3. Terminate the old instance once confident
4. Check OCI billing console to confirm the E5 shape charge stops

---

## 5. Rebuild Script

> This script recreates the base environment on a fresh Ubuntu 22.04 ARM instance.
> Customize the `## CONFIGURATION` section before running.

```bash
#!/usr/bin/env bash
# rebuild.sh — Run on fresh Ubuntu 22.04 ARM (A1.Flex)
set -euo pipefail

## CONFIGURATION — edit these before running
DOMAIN="yourdomain.com"
APP_USER="ubuntu"
CLOUDFLARE_TUNNEL_TOKEN=""   # from Cloudflare Zero Trust dashboard

# ── System updates ──────────────────────────────────────────────────────────
apt update && apt upgrade -y
apt install -y git curl wget jq unzip python3-pip fail2ban

# ── Docker ──────────────────────────────────────────────────────────────────
curl -fsSL https://get.docker.com | sh
usermod -aG docker "$APP_USER"
systemctl enable --now docker

# ── Docker Compose v2 ────────────────────────────────────────────────────────
apt install -y docker-compose-plugin

# ── UFW Firewall ─────────────────────────────────────────────────────────────
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
# Add other ports as needed
ufw --force enable

# ── Fail2ban ─────────────────────────────────────────────────────────────────
systemctl enable --now fail2ban

# ── Nginx ────────────────────────────────────────────────────────────────────
apt install -y nginx
systemctl enable --now nginx

# ── Certbot / Let's Encrypt ──────────────────────────────────────────────────
apt install -y certbot python3-certbot-nginx
# certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN"

# ── Cloudflare Tunnel ────────────────────────────────────────────────────────
if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
    -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
  cloudflared service install "$CLOUDFLARE_TUNNEL_TOKEN"
  systemctl enable --now cloudflared
fi

# ── App-specific setup ────────────────────────────────────────────────────────
# TODO: Add app-specific steps here based on inventory results
# Example for a docker-compose app:
# mkdir -p /opt/myapp
# cp /path/to/docker-compose.yml /opt/myapp/
# cp /path/to/.env /opt/myapp/
# cd /opt/myapp && docker compose up -d

echo "Base setup complete."
```

---

## 6. Config Files to Back Up and Transfer

> Confirm each of these exists on your server by checking the inventory output.

| File / Directory | Priority | Notes |
|-----------------|----------|-------|
| `/etc/nginx/` | Critical | All vhost configs |
| `/etc/caddy/Caddyfile` | Critical | If using Caddy |
| `/etc/cloudflared/` | Critical | Tunnel credentials & config |
| `/root/.cloudflared/` | Critical | Tunnel credentials (may be here instead) |
| `/etc/letsencrypt/` | High | SSL certs + renewal config |
| `/root/.acme.sh/` | High | If using acme.sh instead |
| `/opt/*` | High | App code and data |
| `/srv/*` | High | App data |
| `/var/www/*` | High | Web content |
| `/etc/cron.d/` | Medium | System cron jobs |
| `crontab -l` (root) | Medium | Root user cron |
| `/etc/systemd/system/*.service` | Medium | Custom service units |
| `/etc/ssh/sshd_config` | Medium | SSH configuration |
| `/etc/environment` | Medium | System-wide env vars |
| `~/.ssh/authorized_keys` | Medium | SSH access keys |
| All `.env` files | Critical | App secrets/config |

---

## 7. Secrets and Environment Variables to Carry Over

> **Values are NOT listed here for security.** After running `oracle_inventory.sh`,
> the `ENV FILES` section lists variable names (not values) from each `.env` file.
> Transfer these securely (not via email or unencrypted chat).

Recommended transfer method:
```bash
# Option A: Direct scp (encrypted in transit)
scp -i ~/.ssh/YOUR_KEY ubuntu@OLD_IP:/path/to/.env ./backup.env
scp -i ~/.ssh/YOUR_KEY ./backup.env ubuntu@NEW_IP:/path/to/.env

# Option B: Use age or gpg to encrypt before moving
age -r NEW_SERVER_PUBLIC_KEY .env > .env.age
# Transfer .env.age, then decrypt on new server
```

Variable categories to ensure are captured:
- Database credentials (DB_HOST, DB_USER, DB_PASSWORD, DB_NAME)
- API keys (third-party services, webhooks)
- App secrets (SECRET_KEY, JWT_SECRET, etc.)
- OAuth credentials (CLIENT_ID, CLIENT_SECRET)
- SMTP / email credentials
- Cloudflare API tokens
- Any monitoring/alerting tokens (Sentry, etc.)

---

## 8. Post-Migration Checklist

### Connectivity
- [ ] SSH into new server works
- [ ] `sudo` works for ubuntu/opc user
- [ ] Public IP is reachable (ping or curl)

### Services
- [ ] `systemctl status` shows no failed services
- [ ] Docker daemon is running: `docker ps`
- [ ] All containers are `Up` (not `Exited`): `docker ps -a`
- [ ] No containers in restart loop: `docker ps` shows healthy uptimes

### Web / Networking
- [ ] HTTP port 80 responds (curl http://NEW_IP)
- [ ] HTTPS port 443 responds with valid certificate
- [ ] All domains resolve to new IP (or tunnel is routing correctly)
- [ ] Nginx/Caddy config test passes: `nginx -t`
- [ ] Cloudflare Tunnel is connected: `cloudflared tunnel info`

### Data Integrity
- [ ] Database(s) respond to queries
- [ ] App can read/write data without errors
- [ ] Uploaded files / media are present
- [ ] Logs show no data errors

### Cron / Scheduled Tasks
- [ ] `crontab -l` matches original
- [ ] `systemctl list-timers` shows expected timers

### Security
- [ ] UFW/iptables rules are correct: `ufw status` or `iptables -L`
- [ ] SSH password login is disabled (if it was before)
- [ ] Fail2ban is running: `systemctl status fail2ban`
- [ ] Oracle Security List has the right ingress rules

### Billing
- [ ] Old E5 instance is **stopped** (not just shut down from within — stop via OCI console)
- [ ] OCI console shows old instance is terminated (after verification period)
- [ ] New instance shape shows as `VM.Standard.A1.Flex` or `VM.Standard.E2.1.Micro`
- [ ] Billing estimate in OCI console shows $0 for compute

---

## 9. Notes and Gotchas

### ARM Architecture (A1.Flex)
- Most Docker Hub images have `linux/arm64` variants and will pull automatically.
- If an image fails: `docker pull --platform linux/arm64 IMAGE` or check if arm64 tag exists.
- For images with no arm64 variant, you can run x86 via QEMU emulation:
  ```bash
  docker run --platform linux/amd64 IMAGE  # slower, but works
  ```
- Or find ARM-compatible alternatives (e.g., `arm64v8/` prefixed images).

### Oracle Cloud Ingress Firewall
OCI has TWO layers of firewall — both must allow traffic:
1. **OCI Security List / NSG** (in the VCN) — configured in the Console
2. **OS-level firewall** (iptables/ufw) — configured on the instance

If a port is open in one but not the other, traffic is blocked.

### Always Free Limits
- **A1.Flex total:** 4 OCPUs + 24 GB RAM across ALL A1 instances in tenancy
- **E2.Micro:** 2 instances max
- **Boot volumes:** 200 GB total free across all instances
- **Outbound data transfer:** 10 TB/month free

### Cloudflare Tunnel
If using Cloudflare Tunnel, you do NOT need to open ports 80/443 in the Oracle
Security List at all — traffic flows through the tunnel. This is actually more
secure. The tunnel connector authenticates to Cloudflare and creates an outbound
connection, so no inbound ports needed except SSH (22).

---

_Last updated: 2026-06-03 | Generate fresh inventory with `oracle_inventory.sh`_
