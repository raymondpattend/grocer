#!/usr/bin/env bash
#
# Smoke-test the Live Activity endpoints against a running API.
#   Local:  ./scripts/test-live-activity.sh            (defaults to localhost:8787)
#   Remote: API_BASE=https://grocer-api.<you>.workers.dev ./scripts/test-live-activity.sh
#
# To exercise real APNs delivery you need a real push-to-start token from a
# device build (see docs/LIVE_ACTIVITIES.md). Pass it as PUSH_TO_START_TOKEN.
set -euo pipefail

API_BASE="${API_BASE:-https://grocer-75.localcan.dev}"
HOUSEHOLD="${HOUSEHOLD:-household_test}"
MEMBER="${MEMBER:-member_test}"
DEVICE="${DEVICE:-device_test}"
SESSION="${SESSION:-session_test}"
PUSH_TO_START_TOKEN="${PUSH_TO_START_TOKEN:-deadbeef}"

echo "==> health"
curl -fsS "$API_BASE/health" | jq .

echo "==> register push-to-start token"
curl -fsS -X POST "$API_BASE/live-activity/register-token" \
  -H 'content-type: application/json' \
  -d "{\"householdId\":\"$HOUSEHOLD\",\"memberId\":\"$MEMBER\",\"deviceId\":\"$DEVICE\",\"pushToStartToken\":\"$PUSH_TO_START_TOKEN\",\"familyLiveActivitiesEnabled\":true,\"appVersion\":\"1.0.0\",\"platform\":\"iOS\"}" | jq .

echo "==> start"
curl -fsS -X POST "$API_BASE/live-activity/start" \
  -H 'content-type: application/json' \
  -d "{\"householdId\":\"$HOUSEHOLD\",\"sessionId\":\"$SESSION\",\"storeName\":\"Meijer\",\"shopperName\":\"Raymond\",\"status\":\"Active\",\"itemsFound\":0,\"itemsRemaining\":19,\"totalItems\":19,\"outOfStockCount\":0,\"replacedCount\":0,\"lastHandledItemName\":null,\"lastHandledItemStatus\":null,\"startedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | jq .

echo "==> (device would now POST its per-activity update token)"
curl -fsS -X POST "$API_BASE/live-activity/register-update-token" \
  -H 'content-type: application/json' \
  -d "{\"householdId\":\"$HOUSEHOLD\",\"memberId\":\"$MEMBER\",\"deviceId\":\"$DEVICE\",\"sessionId\":\"$SESSION\",\"updateToken\":\"$PUSH_TO_START_TOKEN\"}" | jq .

echo "==> update"
curl -fsS -X POST "$API_BASE/live-activity/update" \
  -H 'content-type: application/json' \
  -d "{\"householdId\":\"$HOUSEHOLD\",\"sessionId\":\"$SESSION\",\"storeName\":\"Meijer\",\"shopperName\":\"Raymond\",\"status\":\"Active\",\"itemsFound\":12,\"itemsRemaining\":7,\"totalItems\":19,\"outOfStockCount\":1,\"replacedCount\":2,\"lastHandledItemName\":\"Milk\",\"lastHandledItemStatus\":\"Found\",\"updatedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | jq .

echo "==> end"
curl -fsS -X POST "$API_BASE/live-activity/end" \
  -H 'content-type: application/json' \
  -d "{\"householdId\":\"$HOUSEHOLD\",\"sessionId\":\"$SESSION\",\"status\":\"completed\",\"itemsFound\":18,\"itemsRemaining\":0,\"totalItems\":23,\"outOfStockCount\":3,\"replacedCount\":2,\"endedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | jq .

echo "==> done"
