#!/usr/bin/env bash
# probe_slashing_downtime_post_upgrade.sh — verify the slashing-for-downtime
# code path works at MaxValidators=16 cap and observe cap-fill behavior.
#
# Mainnet realism: in the first week of v1.7.0 activation, some BONDED val
# will inevitably miss blocks (operator restart, node crash, networking).
# At 16-val cap each remaining val is 5x more critical than under the
# original 80-val cap. We need empirical confirmation that the jail path
# still functions and to document what happens to the cap when one val
# drops out (does cosmos-sdk auto-promote a UNBONDED ex-pruned val to
# refill the slot, or does bonded count drop to 15?).
#
# Setup:
#   Fresh 20-val localnet. Genesis is patched to shorten
#   signed_blocks_window from 200 to 20 (default would take ~10 min to
#   trigger jail; 20 takes ~60s). Past V170 the bonded set is the top-16
#   by tokens. Probe pauses the rank-16 (smallest-stake bonded) val's
#   consensus container.
#
# Expected:
#   - paused val gets jailed (status=UNBONDED, jailed=true) within ~30 blocks
#   - chain continues to produce blocks (no halt; 15 healthy vals out of
#     16-vote-set is well above 2/3 threshold)
#   - bonded count: OBSERVED, not asserted — log whether cosmos-sdk
#     auto-fills the slot from rank-17 (UNBONDED ex-pruned val) or leaves
#     bonded count at 15
#
# Usage:
#   ./scripts/probe_slashing_downtime_post_upgrade.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_slashing_downtime_post_upgrade.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-65}
STORY_BIN=${STORY_BIN:-/tmp/story}
NEW_MAX=${NEW_MAX:-16}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
SLASHING_WINDOW=${SLASHING_WINDOW:-20}     # blocks
JAIL_WAIT_BLOCKS=${JAIL_WAIT_BLOCKS:-30}   # buffer past the missed-block threshold

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[slash]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[slash]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[slash]${C_RESET} FAIL %s\n" "$*"; exit 1; }
note() { printf "${C_YELLOW}[slash]${C_RESET} OBSERVED %s\n" "$*"; }

get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}
wait_height() { local target=$1 h; while :; do h=$(get_height); [[ $h -ge $target ]] && { echo "$h"; return; }; sleep 2; done; }
val_field() {
  local body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${1}" 2>/dev/null)
  [[ -z $body ]] && { echo "GONE"; return; }
  jq -r ".msg.validator.${2} // \"GONE\"" <<<"$body"
}
bonded_set_json() {
  curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" 2>/dev/null
}
moniker_for_op() {
  local op=$1
  jq -r --arg op "$op" '.[] | select((.evm_address | ascii_downcase) == ($op | ascii_downcase)) | .moniker' "$META"
}

# ---------------- Phase 0 — fresh localnet with shortened slashing window ----------------
phase_0_start() {
  log "Phase 0 — start fresh localnet with signed_blocks_window=$SLASHING_WINDOW (default 200 would take ~10 min to trigger jail)"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2); sleep 5
  fi
  MAX_VALIDATORS_INIT=20 STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" 20 2>&1 | tail -1

  # Patch slashing params for fast jail trigger
  local genesis="${LOCALNET}/config/story/genesis-node.json"
  jq --arg sbw "$SLASHING_WINDOW" '.app_state.slashing.params.signed_blocks_window = $sbw
    | .app_state.slashing.params.min_signed_per_window = "0.050000000000000000"
    | .app_state.slashing.params.downtime_jail_duration = "10s"' \
    "$genesis" > "$genesis.tmp" && mv "$genesis.tmp" "$genesis"
  log "  patched slashing.signed_blocks_window=$SLASHING_WINDOW min_signed_per_window=0.05 downtime_jail_duration=10s"

  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "rpc1 didn't sync in 90s"
    sleep 3
  done
}

# ---------------- Phase 1 — wait past upgrade, capture rank-16 BONDED ----------------
TARGET_OP=""; TARGET_MONIKER=""; TARGET_TOKENS_PRE=""
BONDED_COUNT_PRE=""
phase_1_capture_baseline() {
  log "Phase 1 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_BLOCK and identify rank-16 BONDED val"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  log "  chain at $(get_height)"
  local vals; vals=$(bonded_set_json)
  BONDED_COUNT_PRE=$(jq '.msg.validators | length' <<<"$vals")
  log "  bonded count pre-pause: $BONDED_COUNT_PRE (expected $NEW_MAX)"
  [[ "$BONDED_COUNT_PRE" == "$NEW_MAX" ]] || fail "bonded count $BONDED_COUNT_PRE != $NEW_MAX (post-upgrade prune broken?)"

  # Pick the rank-16 (smallest-tokens) BONDED val — pausing the smallest val
  # has the smallest impact on consensus voting power, so the chain is least
  # at risk of a 2/3-quorum scare during the test.
  TARGET_OP=$(jq -r '.msg.validators | sort_by(.tokens|tonumber) | .[0].operator_address' <<<"$vals")
  TARGET_TOKENS_PRE=$(jq -r '.msg.validators | sort_by(.tokens|tonumber) | .[0].tokens' <<<"$vals")
  TARGET_MONIKER=$(moniker_for_op "$TARGET_OP")
  log "  rank-16 BONDED target: moniker=$TARGET_MONIKER op=$TARGET_OP tokens=$TARGET_TOKENS_PRE"
  [[ -n "$TARGET_MONIKER" ]] || fail "could not resolve moniker for op=$TARGET_OP"
  pass "baseline captured"
}

# ---------------- Phase 2 — pause target val's consensus container ----------------
phase_2_pause_target() {
  local container="${TARGET_MONIKER#localnet-}-node"  # e.g., val-16 -> val-16-node? actually monikers are "localnet-val-N", containers are "validatorN-node"
  # Map moniker -> docker container name. Convention: localnet-val-N -> validatorN-node
  local n; n=$(echo "$TARGET_MONIKER" | sed -E 's/^localnet-val-//')
  container="validator${n}-node"
  log "Phase 2 — docker pause $container (target val's consensus container)"
  docker pause "$container" 2>&1 | sed 's/^/      /'
  local state; state=$(docker inspect "$container" --format '{{.State.Status}}')
  log "  container state: $state"
  [[ "$state" == "paused" ]] || fail "expected container paused, got $state"
}

# ---------------- Phase 3 — wait past slashing window ----------------
JAIL_BLOCK_OBSERVED=""
phase_3_wait_for_jail() {
  log "Phase 3 — wait $JAIL_WAIT_BLOCKS blocks past pause to give signed_blocks_window=$SLASHING_WINDOW + min_signed_per_window=0.05 time to trigger jail"
  local h_start=$(get_height)
  local target_h=$(( h_start + JAIL_WAIT_BLOCKS ))
  log "  pause height ~$h_start, will check jail at block $target_h"
  wait_height "$target_h" >/dev/null
}

# ---------------- Phase 4 — verify jail + observe cap-fill behavior ----------------
TARGET_STATUS_POST=""; TARGET_JAILED_POST=""; BONDED_COUNT_POST=""
phase_4_verify_jail_and_cap() {
  log "Phase 4 — verify $TARGET_MONIKER jailed and observe bonded count behavior"
  TARGET_STATUS_POST=$(val_field "$TARGET_OP" status)
  TARGET_JAILED_POST=$(val_field "$TARGET_OP" jailed)
  log "  $TARGET_MONIKER post-jail: status=$TARGET_STATUS_POST jailed=$TARGET_JAILED_POST"

  [[ "$TARGET_JAILED_POST" == "true" ]] || fail "expected jailed=true after $JAIL_WAIT_BLOCKS blocks of downtime, got jailed=$TARGET_JAILED_POST"
  [[ "$TARGET_STATUS_POST" == "1" ]] || fail "expected status=1 (UNBONDED) post-jail, got $TARGET_STATUS_POST"
  pass "target val correctly jailed for downtime"

  # Observe (do not assert) — bonded count behavior under v1.7.0 cap
  local vals; vals=$(bonded_set_json)
  BONDED_COUNT_POST=$(jq '.msg.validators | length' <<<"$vals")
  log "  bonded count post-jail: $BONDED_COUNT_POST"
  if [[ "$BONDED_COUNT_POST" == "$NEW_MAX" ]]; then
    note "cap-fill: cosmos-sdk auto-promoted a previously-UNBONDED val to refill the slot. Bonded count restored to $NEW_MAX."
    local promoted; promoted=$(jq -r --argjson n "$BONDED_COUNT_POST" '.msg.validators | sort_by(-(.tokens|tonumber)) | .[$n-1].description.moniker' <<<"$vals")
    log "  new rank-16 (auto-promoted): $promoted"
  elif [[ "$BONDED_COUNT_POST" -lt "$NEW_MAX" ]]; then
    note "no cap-fill: bonded count dropped to $BONDED_COUNT_POST (was $BONDED_COUNT_PRE). Slot left vacant."
  else
    fail "bonded count $BONDED_COUNT_POST > $NEW_MAX, MaxValidators cap broken"
  fi
}

# ---------------- Phase 5 — chain liveness ----------------
phase_5_liveness() {
  log "Phase 5 — verify chain still progressing despite jailed val"
  local h=$(get_height)
  wait_height "$((h + 5))" >/dev/null
  pass "chain produced 5+ blocks post-jail (no halt)"

  local panics=0 c
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$'); do
    # Skip the paused container, it can't write logs
    [[ "$c" == "validator${TARGET_MONIKER#localnet-val-}-node" ]] && continue
    local n; n=$(docker logs "$c" 2>&1 | grep -cE 'panic|CONSENSUS FAILURE' || true)
    panics=$((panics + n))
  done
  [[ $panics -eq 0 ]] || fail "$panics panic/CONSENSUS FAILURE lines across non-paused validator-node containers"
  pass "no panic / CONSENSUS FAILURE in healthy validator logs"
}

# ---------------- Phase 6 — unpause + summary ----------------
phase_6_unpause_and_summary() {
  local n; n=$(echo "$TARGET_MONIKER" | sed -E 's/^localnet-val-//')
  local container="validator${n}-node"
  log "Phase 6 — docker unpause $container (cleanup)"
  docker unpause "$container" 2>&1 | sed 's/^/      /'

  printf "\n========== SLASHING-FOR-DOWNTIME PROBE CONCLUSIONS ==========\n"
  printf "Target: %s op=%s\n" "$TARGET_MONIKER" "$TARGET_OP"
  printf "  Pre-pause:  status=BONDED(3) tokens=%s; bonded count=%s\n" "$TARGET_TOKENS_PRE" "$BONDED_COUNT_PRE"
  printf "  Action:     docker pause validator%s-node for %d blocks (signed_blocks_window=%d, min_signed_per_window=0.05)\n" "$n" "$JAIL_WAIT_BLOCKS" "$SLASHING_WINDOW"
  printf "  Post-jail:  status=%s jailed=%s; bonded count=%s\n" "$TARGET_STATUS_POST" "$TARGET_JAILED_POST" "$BONDED_COUNT_POST"
  printf "  Cap-fill behavior: %s\n" "$( [[ "$BONDED_COUNT_POST" == "$NEW_MAX" ]] && echo "auto-fill (rank-17 promoted from UNBONDED)" || echo "no auto-fill (slot left vacant)" )"
  printf "  Final chain height: %s (no halt)\n" "$(get_height)"
  printf "=============================================================\n"
}

phase_7_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 7 — SKIP_TEARDOWN"; return; fi
  log "Phase 7 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_capture_baseline
phase_2_pause_target
phase_3_wait_for_jail
phase_4_verify_jail_and_cap
phase_5_liveness
phase_6_unpause_and_summary
phase_7_teardown
