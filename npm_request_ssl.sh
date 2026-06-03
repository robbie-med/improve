#!/usr/bin/env bash
# npm_request_ssl.sh
# Requests Let's Encrypt SSL certs for all proxy hosts and enables Force SSL.
# Run AFTER npm_setup_proxy_hosts.sh and AFTER DNS for all subdomains points to this server.
#
# Usage:
#   NPM_EMAIL="your@email.com" NPM_PASS="yourpassword" \
#   LETSENCRYPT_EMAIL="you@robbiemed.org" bash npm_request_ssl.sh

set -euo pipefail

NPM_URL="http://127.0.0.1:81"
NPM_EMAIL="${NPM_EMAIL:-admin@example.com}"
NPM_PASS="${NPM_PASS:-changeme}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@robbiemed.org}"

echo "Authenticating with NPM..."
TOKEN=$(curl -s -X POST "${NPM_URL}/api/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${NPM_EMAIL}\",\"secret\":\"${NPM_PASS}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: Authentication failed."
  exit 1
fi
echo "Authenticated OK."

# ── Get all proxy hosts ───────────────────────────────────────────────────────
echo "Fetching proxy host list..."
hosts=$(curl -s "${NPM_URL}/api/nginx/proxy-hosts" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json")

host_count=$(echo "$hosts" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo "Found ${host_count} proxy hosts."

# ── Request SSL for each ──────────────────────────────────────────────────────
echo
echo "Requesting SSL certificates (this takes ~30s per host, be patient)..."

echo "$hosts" | python3 -c "
import sys, json
hosts = json.load(sys.stdin)
for h in hosts:
    print(h['id'], h['domain_names'][0])
" | while read -r host_id domain; do
  echo -n "  SSL for ${domain} (id=${host_id})... "

  # Step 1: Request cert
  cert_result=$(curl -s -X POST "${NPM_URL}/api/nginx/certificates" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"provider\": \"letsencrypt\",
      \"domain_names\": [\"${domain}\"],
      \"meta\": {
        \"letsencrypt_email\": \"${LETSENCRYPT_EMAIL}\",
        \"letsencrypt_agree\": true,
        \"dns_challenge\": false
      }
    }")

  cert_id=$(echo "$cert_result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('id', 'ERROR'))
" 2>/dev/null || echo "ERROR")

  if [ "$cert_id" = "ERROR" ] || [ -z "$cert_id" ]; then
    echo "CERT FAILED — skipping SSL for this host"
    echo "    $cert_result"
    continue
  fi

  # Step 2: Attach cert to proxy host and enable force SSL
  update_result=$(curl -s -X PUT "${NPM_URL}/api/nginx/proxy-hosts/${host_id}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"certificate_id\": ${cert_id},
      \"ssl_forced\": true,
      \"hsts_enabled\": false,
      \"http2_support\": true
    }")

  ok=$(echo "$update_result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('OK' if 'id' in d else 'FAIL')
" 2>/dev/null || echo "FAIL")

  echo "$ok (cert_id=${cert_id})"
  sleep 2  # avoid rate limiting
done

echo
echo "============================================================"
echo "  SSL setup complete."
echo "  Check NPM UI for any failed domains — they likely have DNS"
echo "  not pointing to this server yet, or need HTTP challenge access."
echo "============================================================"
