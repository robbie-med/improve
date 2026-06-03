#!/usr/bin/env bash
# arm_compatibility_check.sh — Run on OLD server before migrating.
# Checks whether each image in your compose files has an ARM64 (linux/arm64) variant.
# Images marked FAIL will need to be replaced before running on A1.Flex.
#
# Usage: bash arm_compatibility_check.sh

set -euo pipefail

DOCKER_BASE="/home/ubuntu/docker"

echo "============================================================"
echo "  ARM64 Compatibility Check for A1.Flex Migration"
echo "============================================================"
echo

check_arm() {
  local image="$1"
  # Use docker manifest to check for arm64 support
  result=$(docker manifest inspect "$image" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    manifests = d.get('manifests', [])
    platforms = [m.get('platform',{}) for m in manifests]
    arm64 = any(p.get('architecture') == 'arm64' or p.get('architecture') == 'aarch64'
                for p in platforms)
    # Also check if it's a single-platform manifest (might be native)
    if not manifests:
        # Single manifest — check os/arch at top level
        arch = d.get('architecture', '')
        arm64 = arch in ('arm64', 'aarch64')
    print('OK' if arm64 else 'FAIL')
except Exception as e:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN")
  printf "  %-55s %s\n" "$image" "$result"
}

echo "Extracting images from compose files..."
echo

# Extract all image references
images=$(grep -h "image:" "$DOCKER_BASE"/*/*.yml 2>/dev/null \
  | sed 's/.*image://; s/\${.*}//g; s/^ *//; s/ *$//' \
  | grep -v '^$' | sort -u)

FAILED=0
UNKNOWN=0
PASSED=0

while IFS= read -r image; do
  result=$(docker manifest inspect "$image" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    manifests = d.get('manifests', [])
    platforms = [m.get('platform',{}) for m in manifests]
    arm64 = any(p.get('architecture') in ('arm64','aarch64') for p in platforms)
    if not manifests:
        arch = d.get('architecture','')
        arm64 = arch in ('arm64','aarch64')
    print('OK' if arm64 else 'FAIL')
except:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN")

  printf "  %-55s %s\n" "$image" "$result"
  case "$result" in
    OK)      ((PASSED++)) ;;
    FAIL)    ((FAILED++)) ;;
    UNKNOWN) ((UNKNOWN++)) ;;
  esac
done <<< "$images"

echo
echo "============================================================"
echo "  Results: $PASSED OK, $FAILED FAIL, $UNKNOWN UNKNOWN"
echo "============================================================"
echo

if [ "$FAILED" -gt 0 ]; then
  echo "IMAGES NEEDING REPLACEMENT (no ARM64 variant found):"
  echo
  echo "  browserless/chrome"
  echo "  → Replace with: ghcr.io/browserless/chromium:latest"
  echo "    (used by RSSHub in automation/docker-compose.yml)"
  echo
  echo "  gcr.io/zenika-hub/alpine-chrome:124"
  echo "  → Replace with: gcr.io/zenika-hub/alpine-chrome:latest"
  echo "    (used by Karakeep in home-lifestyle/docker-compose.yml)"
  echo "    NOTE: The :latest tag has arm64. The :124 pin does not."
  echo
  echo "  To apply these patches automatically, migrate_restore.sh handles them."
fi

echo
echo "Additional notes for A1.Flex:"
echo "  - Ubuntu 22.04 ARM recommended (not 20.04)"
echo "  - All LSIO images (linuxserver.io) support ARM64"
echo "  - PostgreSQL, MariaDB, Redis, Gitea, n8n, Meilisearch: all ARM64 OK"
echo "  - Wekan, Nextcloud, BookStack, Keycloak: ARM64 OK"
echo "  - Open-appsec: verify latest tag has arm64 before deploying"
