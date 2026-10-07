#!/usr/bin/env bash
set -eo pipefail

# Start the patching loop by firing the initial webhook to EDA with current_group: A.
# The loop then self-perpetuates: A -> B -> C -> A -> ...
#
# Usage:
#   ./scripts/start-loop.sh [GROUP]
#
# Arguments:
#   GROUP — Starting group (default: A). Must be A, B, or C.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

GROUP="${1:-A}"
GROUP="${GROUP^^}"

if [[ ! "$GROUP" =~ ^[ABC]$ ]]; then
  echo "Error: GROUP must be A, B, or C (got: $GROUP)" >&2
  exit 1
fi

# Remove stop flag if present
rm -f /tmp/patching-loop-stop

echo "=== Starting Patching Loop ==="
echo "  Starting group: $GROUP"
echo "  AO Webhook URL: ${AO_WEBHOOK_BASE_URL}"
echo "  Webhook path:   ${AO_WEBHOOK_PATH}"
echo ""

# Step 1: Get OAuth2 token
echo "Obtaining OAuth2 token..."
TOKEN_RESPONSE=$(curl -sk -X POST \
  "${AO_WEBHOOK_BASE_URL}/api/v1/auth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${AO_WEBHOOK_CLIENT_ID}&client_secret=${AO_WEBHOOK_CLIENT_SECRET}")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Error: Failed to obtain OAuth2 token" >&2
  echo "Response: $TOKEN_RESPONSE" >&2
  exit 1
fi

echo "Token obtained ✓"

# Step 2: Fire webhook to EDA
echo "Firing webhook for Group $GROUP..."
WEBHOOK_RESPONSE=$(curl -sk -X POST \
  "${AO_WEBHOOK_BASE_URL}/api/v1/webhooks/eda/${AO_WEBHOOK_PATH}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"current_group\": \"$GROUP\"}" \
  -w "\n%{http_code}")

HTTP_CODE=$(echo "$WEBHOOK_RESPONSE" | tail -1)
BODY=$(echo "$WEBHOOK_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "202" ]]; then
  echo "Webhook accepted (HTTP 202) ✓"
  echo "Response: $BODY"
  echo ""
  echo "Patching loop started! Group $GROUP will be processed first."
  echo "Loop will continue: $GROUP → $(echo $GROUP | tr 'ABC' 'BCA') → $(echo $GROUP | tr 'ABC' 'CAB') → $GROUP → ..."
  echo ""
  echo "To stop the loop: ./scripts/stop-loop.sh"
else
  echo "Error: Webhook returned HTTP $HTTP_CODE" >&2
  echo "Response: $BODY" >&2
  exit 1
fi
