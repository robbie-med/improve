#!/usr/bin/env bash
# npm_setup_proxy_hosts.sh
# Automates creation of all 18 proxy hosts in NPM via its REST API.
# Run this ON THE SERVER after logging into NPM and updating credentials.
#
# Usage:
#   NPM_EMAIL="your@email.com" NPM_PASS="yourpassword" bash npm_setup_proxy_hosts.sh
#
# Or set them at the top of the file and run: bash npm_setup_proxy_hosts.sh

set -euo pipefail

NPM_URL="http://127.0.0.1:81"
NPM_EMAIL="${NPM_EMAIL:-admin@example.com}"
NPM_PASS="${NPM_PASS:-changeme}"

# ── Auth ─────────────────────────────────────────────────────────────────────
echo "Authenticating with NPM..."
TOKEN=$(curl -s -X POST "${NPM_URL}/api/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${NPM_EMAIL}\",\"secret\":\"${NPM_PASS}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: Authentication failed. Check NPM_EMAIL and NPM_PASS."
  exit 1
fi
echo "Authenticated OK."

H="-H 'Authorization: Bearer ${TOKEN}' -H 'Content-Type: application/json'"

# ── Helper: create one proxy host ────────────────────────────────────────────
create_host() {
  local domain="$1"
  local forward_host="$2"
  local forward_port="$3"
  local scheme="${4:-http}"

  echo -n "  Creating ${domain} → ${forward_host}:${forward_port} (${scheme})... "

  result=$(curl -s -X POST "${NPM_URL}/api/nginx/proxy-hosts" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"domain_names\": [\"${domain}\"],
      \"forward_scheme\": \"${scheme}\",
      \"forward_host\": \"${forward_host}\",
      \"forward_port\": ${forward_port},
      \"block_exploits\": true,
      \"allow_websocket_upgrade\": true,
      \"http2_support\": false,
      \"ssl_forced\": false,
      \"hsts_enabled\": false,
      \"caching_enabled\": false,
      \"advanced_config\": \"\",
      \"locations\": [],
      \"meta\": {\"letsencrypt_agree\": false, \"dns_challenge\": false}
    }")

  id=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','ERROR'))" 2>/dev/null || echo "ERROR")

  if [ "$id" = "ERROR" ] || [ -z "$id" ]; then
    echo "FAILED"
    echo "    Response: $result"
  else
    echo "OK (id=$id)"
  fi
}

# ── Create all proxy hosts ────────────────────────────────────────────────────
echo
echo "Creating proxy hosts..."

# Subdomain → Container:Port (scheme defaults to http unless specified)
create_host "waf.robbiemed.org"       "appsec-nginx-proxy-manager" 81
create_host "time.robbiemed.org"      "traggo"                     3030
create_host "git.robbiemed.org"       "gitea"                      3000
create_host "db.robbiemed.org"        "pocketbase"                 8090
create_host "auth.robbiemed.org"      "keycloak"                   8080
create_host "bin.robbiemed.org"       "privatebin"                 8080
create_host "rss.robbiemed.org"       "rsshub"                     1200
create_host "boards.robbiemed.org"    "wekan"                      8080
create_host "cloud.robbiemed.org"     "nextcloud"                  443   "https"
create_host "wedding.robbiemed.org"   "weddingshare"               5000
create_host "inventory.robbiemed.org" "homebox"                    7745
create_host "idlers.robbiemed.org"    "my-idlers"                  8000
create_host "flow.robbiemed.org"      "n8n"                        5678
create_host "haven.robbiemed.org"     "haven"                      3000
create_host "kara.robbiemed.org"      "karakeep"                   3000
create_host "auto.robbiemed.org"      "lubelogger"                 8080
create_host "crm.robbiemed.org"       "twenty-server"              3000
create_host "docs.robbiemed.org"      "bookstack"                  80

echo
echo "============================================================"
echo "  All proxy hosts created."
echo
echo "  NEXT STEP — Request SSL certificates:"
echo "  In NPM UI → Proxy Hosts → Edit each host → SSL tab"
echo "  → Request a new SSL certificate → Force SSL"
echo
echo "  OR run: bash npm_request_ssl.sh  (if you create that script)"
echo "============================================================"
