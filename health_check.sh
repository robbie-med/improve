#!/usr/bin/env bash
# health_check.sh — Run ON THE SERVER to get a full status snapshot.
# Shows container status, recent errors, and basic reachability of each service.
#
# Usage: bash health_check.sh | tee ~/health_$(date +%Y%m%d_%H%M%S).txt

set -euo pipefail

HR="============================================================"
section() { echo; echo "$HR"; echo "  $1"; echo "$HR"; }

section "CONTAINER STATUS"
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}" 2>/dev/null \
  | sort || echo "Docker not available"

section "RESTART COUNTS (containers restarting often = problem)"
docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null \
  | grep -v "Up " | grep -v "^NAMES" || echo "All containers running"

section "RESOURCE USAGE"
echo "--- Memory ---"
free -h
echo
echo "--- Disk ---"
df -h /
echo
echo "--- Top containers by memory ---"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" \
  2>/dev/null | sort -t$'\t' -k4 -rn | head -20 || true

section "DATABASE CONNECTIVITY"
echo "--- PostgreSQL ---"
docker exec shared-postgres psql -U postgres -tAc "\l" 2>/dev/null \
  | grep -E 'gitea|keycloak|n8n|twenty|haven' \
  && echo "  Postgres: all expected DBs present" \
  || echo "  WARNING: Some expected Postgres DBs missing"

echo
echo "--- MariaDB ---"
docker exec shared-mariadb mariadb -uroot \
  -p"$(grep MARIADB_ROOT_PASSWORD /home/ubuntu/docker/shared-db/.env | cut -d= -f2-)" \
  -e "SHOW DATABASES;" 2>/dev/null \
  | grep -E 'nextcloud|bookstack|myidlers' \
  && echo "  MariaDB: all expected DBs present" \
  || echo "  WARNING: Some expected MariaDB DBs missing"

section "SERVICE REACHABILITY (from inside Docker network)"
# We use a temporary alpine container on npm_network to test reachability
echo "Spawning test container on npm_network..."

docker run --rm --network npm_network alpine sh -c '
  check() {
    name=$1; host=$2; port=$3
    if nc -z -w3 "$host" "$port" 2>/dev/null; then
      echo "  OK    $name ($host:$port)"
    else
      echo "  FAIL  $name ($host:$port)"
    fi
  }
  apk add --no-cache netcat-openbsd >/dev/null 2>&1

  check "NPM admin"         "appsec-nginx-proxy-manager" 81
  check "Traggo"            "traggo"           3030
  check "Gitea"             "gitea"            3000
  check "PocketBase"        "pocketbase"       8090
  check "Keycloak"          "keycloak"         8080
  check "PrivateBin"        "privatebin"       8080
  check "RSSHub"            "rsshub"           1200
  check "Wekan"             "wekan"            8080
  check "Nextcloud"         "nextcloud"        443
  check "WeddingShare"      "weddingshare"     5000
  check "Homebox"           "homebox"          7745
  check "my-idlers"         "my-idlers"        8000
  check "n8n"               "n8n"              5678
  check "Haven"             "haven"            3000
  check "Karakeep"          "karakeep"         3000
  check "LubeLogger"        "lubelogger"       8080
  check "Twenty"            "twenty-server"    3000
  check "BookStack"         "bookstack"        80
  check "Shared Redis"      "shared-redis"     6379
  check "Shared Postgres"   "shared-postgres"  5432
  check "Shared MariaDB"    "shared-mariadb"   3306
'

section "RECENT ERRORS (last 20 lines from problem containers)"
for container in haven keycloak twenty-server gitea n8n karakeep; do
  status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
  restarts=$(docker inspect --format '{{.RestartCount}}' "$container" 2>/dev/null || echo "?")
  echo
  echo "--- $container (status=$status, restarts=$restarts) ---"
  if [ "$restarts" != "0" ] && [ "$restarts" != "?" ]; then
    docker logs --tail 15 "$container" 2>&1 | tail -15 || echo "(no logs)"
  else
    echo "(no restart issues)"
  fi
done

section "NPM PROXY HOSTS"
echo "Fetching from NPM API..."
# Get token
TOKEN=$(curl -s -X POST "http://127.0.0.1:81/api/tokens" \
  -H "Content-Type: application/json" \
  -d '{"identity":"admin@example.com","secret":"changeme"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token','FAIL'))" 2>/dev/null \
  || echo "FAIL")

if [ "$TOKEN" = "FAIL" ] || [ -z "$TOKEN" ]; then
  echo "  Could not auth to NPM (update credentials in this script if you changed them)"
else
  curl -s "http://127.0.0.1:81/api/nginx/proxy-hosts" \
    -H "Authorization: Bearer ${TOKEN}" \
    | python3 -c "
import sys, json
hosts = json.load(sys.stdin)
if not hosts:
    print('  No proxy hosts configured yet — run npm_setup_proxy_hosts.sh')
else:
    print(f'  {len(hosts)} proxy hosts configured:')
    for h in hosts:
        ssl = 'SSL' if h.get('ssl_forced') else 'no-ssl'
        certs = 'cert' if h.get('certificate_id') else 'no-cert'
        print(f'    {h[\"domain_names\"][0]:45s} → {h[\"forward_host\"]}:{h[\"forward_port\"]} [{ssl}, {certs}]')
" 2>/dev/null || echo "  Error parsing proxy hosts response"
fi

section "HOMARR APP COUNT"
APP_COUNT=$(sqlite3 /home/ubuntu/homarr/appdata/db/db.sqlite \
  "SELECT COUNT(*) FROM app;" 2>/dev/null || echo "unknown")
echo "  Apps in Homarr database: $APP_COUNT"

section "SUMMARY"
RUNNING=$(docker ps -q 2>/dev/null | wc -l)
TOTAL=$(docker ps -aq 2>/dev/null | wc -l)
RESTARTING=$(docker ps --filter "status=restarting" -q 2>/dev/null | wc -l)
echo "  Running containers: $RUNNING / $TOTAL"
echo "  Restarting (broken): $RESTARTING"
echo
echo "  Next actions needed:"
echo "  1. Run npm_setup_proxy_hosts.sh if proxy hosts = 0"
echo "  2. Run fix_haven_db.sh if haven is restarting"
echo "  3. Run npm_request_ssl.sh after DNS is pointed at this server"
echo "  4. Visit http://$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'):81 for NPM"
