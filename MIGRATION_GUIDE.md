# shocknode → A1.Flex Migration Guide

**From:** VM.Standard.E5.Flex (paid, 1 OCPU / 12 GB RAM) — 163.192.204.116  
**To:** VM.Standard.A1.Flex (free tier, ARM64, 2 OCPU / 6 GB RAM recommended)  
**Reason:** $48.66/month invoice; E5.Flex is not part of Always Free

---

## ARM64 Image Notes

Before migrating, be aware of two images that need patching for ARM:

| Old Image | Issue | Replacement |
|-----------|-------|-------------|
| `browserless/chrome` | x86 only | `ghcr.io/browserless/chromium:latest` |
| `gcr.io/zenika-hub/alpine-chrome:124` | Tag 124 has no arm64 | `gcr.io/zenika-hub/alpine-chrome:latest` |

`migrate_restore.sh` patches these automatically.

---

## Migration Checklist

### Phase 0 — Pre-flight (do this now, on old server)

- [ ] **Verify all services working** on old server before backup
- [ ] **Check disk space**: `df -h` — need ~2x your data size free in `/tmp`
- [ ] **Note current NPM credentials** (you changed from admin@example.com/changeme)
- [ ] **Note DNS TTL** — lower it to 60s now so cutover is fast later

```bash
# Check disk space
df -h /tmp /home

# Check total Docker data size
du -sh /var/lib/docker/volumes/
```

---

### Phase 1 — Backup Old Server

```bash
# 1. Copy backup script to server
scp -i ~/.ssh/YOUR_KEY migrate_backup.sh ubuntu@163.192.204.116:~/

# 2. Run backup (takes 5-15 min depending on data size)
ssh -i ~/.ssh/YOUR_KEY ubuntu@163.192.204.116
NPM_EMAIL="your@email.com" NPM_PASS="yourpassword" sudo bash ~/migrate_backup.sh

# 3. Download archive to local machine
scp -i ~/.ssh/YOUR_KEY ubuntu@163.192.204.116:~/migration_backup_*.tar.gz .

# Verify archive is intact
tar tzf migration_backup_*.tar.gz | head -20
```

---

### Phase 2 — Provision New A1.Flex Instance

In OCI Console → Compute → Instances → **Create Instance**:

| Setting | Value |
|---------|-------|
| Name | `shocknode-free` (or `shocknode`) |
| Image | **Canonical Ubuntu 22.04** (select ARM64/aarch64 build) |
| Shape | VM.Standard.A1.Flex |
| OCPU | 2 |
| RAM | 6 GB (or up to 24 GB — all free) |
| Boot volume | 100 GB (free tier total: 200 GB across all instances) |
| SSH key | Upload your existing public key |
| Public IP | Assign (ephemeral or reserved) |

**After creation, update Security List / NSG inbound rules:**

| Protocol | Port | Source |
|----------|------|--------|
| TCP | 22 | 0.0.0.0/0 |
| TCP | 80 | 0.0.0.0/0 |
| TCP | 443 | 0.0.0.0/0 |
| TCP | 81 | 0.0.0.0/0 (restrict to your IP for safety) |

---

### Phase 3 — Restore on New Server

```bash
# 1. Copy archive and restore script to new server
NEW_IP="<NEW_SERVER_IP>"
scp -i ~/.ssh/YOUR_KEY migration_backup_*.tar.gz ubuntu@${NEW_IP}:~/
scp -i ~/.ssh/YOUR_KEY migrate_restore.sh fix_haven_db.sh \
    health_check.sh npm_setup_proxy_hosts.sh npm_request_ssl.sh \
    ubuntu@${NEW_IP}:~/

# 2. SSH in and run restore (takes 10-30 min — pulls all ARM images)
ssh -i ~/.ssh/YOUR_KEY ubuntu@${NEW_IP}
sudo bash ~/migrate_restore.sh ~/migration_backup_*.tar.gz

# 3. Fix Haven DB (known issue from original setup)
sudo bash ~/fix_haven_db.sh

# 4. Set up NPM proxy hosts
NPM_EMAIL="admin@example.com" NPM_PASS="changeme" bash ~/npm_setup_proxy_hosts.sh
```

---

### Phase 4 — Verify Before DNS Cutover

```bash
# Full health check
bash ~/health_check.sh | tee ~/health_check.txt

# Quick container status
docker ps --format "table {{.Names}}\t{{.Status}}" | sort

# Test a few services directly by IP (before DNS change)
curl -sk https://NEW_IP:443 -o /dev/null -w "%{http_code}"
```

Access NPM at `http://NEW_SERVER_IP:81` and verify:
- [ ] Can log in
- [ ] All 18 proxy hosts exist
- [ ] SSL certs can be requested (needs DNS first)

Test a few apps via container name (from inside npm_network):
```bash
docker run --rm --network npm_network alpine sh -c "
apk add --no-cache netcat-openbsd -q >/dev/null &&
nc -z -w3 gitea 3000 && echo 'gitea OK' || echo 'gitea FAIL'
nc -z -w3 n8n 5678 && echo 'n8n OK' || echo 'n8n FAIL'
nc -z -w3 twenty-server 3000 && echo 'twenty OK' || echo 'twenty FAIL'
"
```

---

### Phase 5 — DNS Cutover

Update **all** A records for `robbiemed.org` subdomains to the new IP.

All subdomains to update:
```
waf.robbiemed.org      → NEW_IP
time.robbiemed.org     → NEW_IP
git.robbiemed.org      → NEW_IP
db.robbiemed.org       → NEW_IP
auth.robbiemed.org     → NEW_IP
bin.robbiemed.org      → NEW_IP
rss.robbiemed.org      → NEW_IP
boards.robbiemed.org   → NEW_IP
cloud.robbiemed.org    → NEW_IP
wedding.robbiemed.org  → NEW_IP
inventory.robbiemed.org → NEW_IP
idlers.robbiemed.org   → NEW_IP
flow.robbiemed.org     → NEW_IP
haven.robbiemed.org    → NEW_IP
kara.robbiemed.org     → NEW_IP
auto.robbiemed.org     → NEW_IP
crm.robbiemed.org      → NEW_IP
docs.robbiemed.org     → NEW_IP
```

If using **Cloudflare Proxy (orange cloud)**, DNS propagates instantly.  
If not, wait for TTL to expire (set to 60s in Phase 0).

---

### Phase 6 — Request SSL Certificates

After DNS is propagated:

```bash
LETSENCRYPT_EMAIL="admin@robbiemed.org" \
NPM_EMAIL="your@email.com" \
NPM_PASS="yourpassword" \
bash ~/npm_request_ssl.sh
```

Or do it manually in NPM UI: each proxy host → SSL tab → Request cert → Force SSL.

---

### Phase 7 — Final Verification

- [ ] `https://waf.robbiemed.org` loads NPM admin (with valid SSL)
- [ ] `https://time.robbiemed.org` loads Traggo (login: admin/admin — **change this**)
- [ ] `https://git.robbiemed.org` loads Gitea
- [ ] `https://flow.robbiemed.org` loads n8n
- [ ] `https://cloud.robbiemed.org` loads Nextcloud (complete first-run setup if needed)
- [ ] `https://docs.robbiemed.org` loads BookStack
- [ ] `https://crm.robbiemed.org` loads Twenty
- [ ] `https://kara.robbiemed.org` loads Karakeep
- [ ] `https://haven.robbiemed.org` loads Haven
- [ ] Homarr dashboard shows all apps as online (ping checks green)
- [ ] Paperless-ngx is accessible and documents are intact
- [ ] Check OCI billing console shows new instance as A1.Flex (free tier)

---

### Phase 8 — Decommission Old Server

Only after verifying everything works on the new server:

```bash
# 1. STOP (not terminate) old instance in OCI Console
# Compute → Instances → shocknode → Stop

# 2. Monitor new server for 24-48 hours

# 3. Terminate old instance
# Compute → Instances → shocknode → Terminate
#   ✓ Check "Permanently delete the attached boot volume"
```

Check OCI billing console 1-2 days after termination to confirm E5.Flex charges stop.

---

## Troubleshooting

### Container won't start on ARM
```bash
docker logs CONTAINER_NAME | tail -30
# If "exec format error" → image has no ARM64 variant
# Check: docker manifest inspect IMAGE | grep architecture
```

### Database connection errors after restore
```bash
# Re-run the password sync for all DB users
docker exec shared-postgres psql -U postgres -d postgres -c "\du"
# Compare with passwords in /home/ubuntu/docker/SECRETS-*.md
# Re-run ALTER USER commands as needed
```

### Haven still crashing
```bash
sudo bash ~/fix_haven_db.sh
# If still failing: docker logs haven | tail -50
```

### NPM proxy hosts missing after restore
```bash
NPM_EMAIL="..." NPM_PASS="..." bash ~/npm_setup_proxy_hosts.sh
```

### Nextcloud first-run setup
Open `https://cloud.robbiemed.org` and choose:
- DB type: MySQL/MariaDB
- Host: `shared-mariadb`
- Database: `nextcloud`
- User: `nc_user`
- Password: (from SECRETS file — look for `NEXTCLOUD_DB_PASSWORD` or `NC_USER_PASSWORD`)

---

## Resource Budget on A1.Flex

With 2 OCPU / 6 GB RAM (recommended), expected usage:

| Component | Est. RAM |
|-----------|----------|
| Shared Postgres + MariaDB + Redis | ~500 MB |
| NPM + appsec-agent | ~300 MB |
| Nextcloud | ~200 MB |
| Gitea | ~150 MB |
| Keycloak | ~600 MB |
| n8n | ~300 MB |
| Twenty (server + worker) | ~600 MB |
| Wekan + Mongo | ~400 MB |
| Karakeep + Chrome + Meili | ~800 MB |
| Remaining apps (traggo, homebox, etc.) | ~400 MB |
| **Total estimate** | **~4.2 GB** |

6 GB gives ~1.8 GB headroom. If memory is tight, you can increase to 8 GB RAM — still free tier (limit is 24 GB total across all A1 instances in your tenancy).

---

*Generated: 2026-06-03 | Source: shocknode Codex session logs*
