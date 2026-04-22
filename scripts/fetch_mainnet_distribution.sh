#!/bin/bash
# Fetch top-N bonded validators from story-1 mainnet REST; scale to TOTAL.
# Falls back to committed snapshot (scripts/distribution_mainnet_snapshot.json)
# if all public endpoints are unreachable (common — Story mainnet public RPC
# only exposes EVM + /status, no Cosmos REST).
#
# Usage: ./fetch_mainnet_distribution.sh [N] [TOTAL_STAKE]
#   N            validators to keep (default 20)
#   TOTAL_STAKE  sum of scaled tokens across all N (default 10^16)
#   STORY_REST   override: comma-separated list of REST base URLs to try
#   NEW_MAX_VALIDATORS   post-upgrade count for safety check (default 16)

set -euo pipefail

N=${1:-20}
TOTAL=${2:-10000000000000000}
NEW_MAX=${NEW_MAX_VALIDATORS:-16}

DEFAULT_ENDPOINTS="https://story-mainnet-api.itrocket.net,https://story-api.polkachu.com,https://story-rest.publicnode.com"
REST_LIST=${STORY_REST:-$DEFAULT_ENDPOINTS}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="${SCRIPT_DIR}/distribution_mainnet_snapshot.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

RAW_JSON=""
SOURCE=""

IFS=',' read -ra ENDPOINTS <<< "$REST_LIST"
for ep in "${ENDPOINTS[@]}"; do
  ep_trim="${ep// /}"
  [ -z "$ep_trim" ] && continue
  echo "Trying $ep_trim..." >&2
  if resp=$(curl -fsS -m 10 -H "User-Agent: Mozilla/5.0" \
              "${ep_trim}/cosmos/staking/v1beta1/validators?status=BOND_STATUS_BONDED&pagination.limit=100" 2>/dev/null); then
    if echo "$resp" | jq -e '.validators' >/dev/null 2>&1; then
      RAW_JSON="$resp"
      SOURCE="live: $ep_trim"
      break
    fi
  fi
done

if [ -z "$RAW_JSON" ]; then
  if [ ! -f "$SNAPSHOT" ]; then
    echo "ERROR: all REST endpoints failed and snapshot file missing: $SNAPSHOT" >&2
    exit 1
  fi
  RAW_JSON=$(cat "$SNAPSHOT")
  SOURCE="snapshot: $SNAPSHOT"
  echo "All REST endpoints failed, falling back to committed snapshot." >&2
fi

echo "Source: $SOURCE" >&2

echo "$RAW_JSON" | jq --argjson n "$N" --argjson total "$TOTAL" '
    [.validators[] | {op:.operator_address, tokens:(.tokens|tonumber), moniker:.description.moniker}]
    | sort_by(-.tokens) | .[:$n]
    | (map(.tokens)|add) as $raw_sum
    | to_entries | map({
        index: (.key + 1),
        tokens: ((.value.tokens / $raw_sum) * $total | floor),
        source_moniker: .value.moniker,
        source_operator: .value.op
      })' > distribution.json

total_scaled=$(jq '[.[].tokens]|add' distribution.json)
top_share=$(jq --argjson k "$NEW_MAX" '
    ([.[:$k] | .[].tokens] | add) as $top
    | ([.[].tokens] | add) as $all
    | ($top / $all)' distribution.json)

echo "Wrote $N validators, scaled total = $total_scaled" >&2
echo "Top-${NEW_MAX} cumulative share = $top_share" >&2

awk_check=$(awk -v s="$top_share" 'BEGIN{ print (s > 0.67) ? "ok" : "bad" }')
if [ "$awk_check" = "bad" ]; then
  echo "ABORT: top-${NEW_MAX} share $top_share <= 0.67 — bottom-$((N - NEW_MAX)) carry >1/3 VP." >&2
  echo "Pruning them would halt mainnet BFT; test distribution not safe." >&2
  exit 2
fi

echo "OK: top-${NEW_MAX} controls > 2/3 VP — safe pruning." >&2
