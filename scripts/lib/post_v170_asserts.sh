#!/usr/bin/env bash
# scripts/lib/post_v170_asserts.sh — shared post-V170 assertion helpers.
#
# Purpose: catch the failure mode where binary's `NewMaxValidators` and the
# probe's `NEW_MAX` variable disagree. A probe that just runs
# `wait_height pre-V170; redelegate; capture state` will silently PASS even
# if V170 never actually prunes anything (e.g., NewMax=21 binary on 8-val
# cluster: cap raised, no prune fires, "out-of-top" semantics never realized).
#
# Source from a probe and call assert_post_v170_state after the V170 fire
# height. This will:
#   1. Wait until height >= UPGRADE_HEIGHT + grace
#   2. Assert REST staking/params.max_validators == probe's NEW_MAX
#      (binary-level sanity — failing here means binary patched wrong)
#   3. Assert each named "expected pruned" val has status ∈ {1,2}
#      (UNBONDING or UNBONDED — pre-`unbonding_time` is 2, post is 1)
#   4. Optionally assert "expected bonded" vals stay status=3
#   5. Dump full snapshot of all named vals to stdout (for evidence capture)
#
# Usage (sourced):
#   source "${LOCALNET}/scripts/lib/post_v170_asserts.sh"
#   PRUNED_VALS="localnet-val-5 localnet-val-6 localnet-val-7 localnet-val-8" \
#     BONDED_VALS="localnet-val-1 localnet-val-2 localnet-val-3 localnet-val-4" \
#     EXPECTED_NEW_MAX="$NEW_MAX" \
#     UPGRADE_HEIGHT="$UPGRADE_HEIGHT" \
#     META="$META" \
#     POST_V170_GRACE=5 \
#     assert_post_v170_state
#
# Caller is expected to define `fail()`, `pass()`, `log()` (probes already do).
# If not defined, lib will define basic stubs.

if ! declare -F log >/dev/null 2>&1;  then log()  { printf "[post-v170] %s\n" "$*"; }; fi
if ! declare -F pass >/dev/null 2>&1; then pass() { printf "[post-v170] PASS %s\n" "$*"; }; fi
if ! declare -F fail >/dev/null 2>&1; then fail() { printf "[post-v170] FAIL %s\n" "$*" >&2; exit 1; }; fi

_post_v170_get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}

_post_v170_meta_op() {
  jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"
}

_post_v170_val_field() {
  local op=$1 field=$2 body
  body=$(curl -fsS -m 5 "http://localhost:1317/staking/validators/${op}" 2>/dev/null)
  [[ -z $body ]] && { echo "GONE"; return; }
  jq -r ".msg.validator.${field} // \"\"" <<<"$body"
}

_post_v170_params_max_validators() {
  curl -fsS -m 5 "http://localhost:1317/staking/params" 2>/dev/null \
    | jq -r '.msg.params.max_validators // ""'
}

# Main assertion entry point.
#
# Required env vars:
#   PRUNED_VALS       space-separated monikers expected to have status ∈ {1,2}
#   EXPECTED_NEW_MAX  expected staking/params.max_validators value post-V170
#   UPGRADE_HEIGHT    V170 height (probe's UPGRADE_HEIGHT)
#   META              path to validators_meta.json
#
# Optional env vars:
#   BONDED_VALS       space-separated monikers expected to stay status=3 (default: empty)
#   POST_V170_GRACE   blocks to wait past UPGRADE_HEIGHT before asserting (default: 5)
#   SNAPSHOT_FILE     if set, write per-val JSON state to this path
assert_post_v170_state() {
  : "${PRUNED_VALS:?PRUNED_VALS must be set}"
  : "${EXPECTED_NEW_MAX:?EXPECTED_NEW_MAX must be set}"
  : "${UPGRADE_HEIGHT:?UPGRADE_HEIGHT must be set}"
  : "${META:?META must be set}"
  local grace=${POST_V170_GRACE:-5}
  local target_h=$((UPGRADE_HEIGHT + grace))

  log "post-V170 assert: waiting height >= $target_h (V170=$UPGRADE_HEIGHT + grace=$grace)"
  local h
  while :; do
    h=$(_post_v170_get_height)
    [[ $h -ge $target_h ]] && break
    sleep 2
  done
  log "  chain at h=$h"

  # ---- 1. binary sanity: staking/params.max_validators == probe's NEW_MAX ----
  local actual_max
  actual_max=$(_post_v170_params_max_validators)
  if [[ "$actual_max" != "$EXPECTED_NEW_MAX" ]]; then
    fail "binary↔probe mismatch: staking/params.max_validators=$actual_max but probe expects NEW_MAX=$EXPECTED_NEW_MAX. Binary's v_1_7_0.NewMaxValidators is wrong, or probe's NEW_MAX is stale."
  fi
  pass "binary↔probe consistent: staking/params.max_validators = $actual_max == NEW_MAX"

  # ---- 2. assert pruned vals have status ∈ {1,2} ----
  local m op status snapshot=""
  for m in $PRUNED_VALS; do
    op=$(_post_v170_meta_op "$m")
    [[ -z $op ]] && fail "moniker $m not found in $META"
    status=$(_post_v170_val_field "$op" status)
    if [[ "$status" != "1" && "$status" != "2" ]]; then
      fail "$m expected pruned (status ∈ {1,2}) post-V170 at h=$h, got status=$status"
    fi
    log "  $m op=$op status=$status (pruned ✓)"
    snapshot+=$(curl -fsS -m 5 "http://localhost:1317/staking/validators/${op}" 2>/dev/null \
      | jq -c '{moniker: .msg.validator.description.moniker, status: .msg.validator.status, jailed: (.msg.validator.jailed // false), tokens: .msg.validator.tokens, unbonding_height: (.msg.validator.unbonding_height // ""), unbonding_time: (.msg.validator.unbonding_time // "")}')
    snapshot+=$'\n'
  done
  pass "pruned vals (${PRUNED_VALS// /, }) all in status ∈ {1,2} post-V170"

  # ---- 3. assert bonded vals stay status=3 (optional) ----
  if [[ -n "${BONDED_VALS:-}" ]]; then
    for m in $BONDED_VALS; do
      op=$(_post_v170_meta_op "$m")
      [[ -z $op ]] && fail "moniker $m not found in $META"
      status=$(_post_v170_val_field "$op" status)
      [[ "$status" == "3" ]] || fail "$m expected BONDED (status=3) post-V170, got status=$status"
      log "  $m op=$op status=3 (bonded ✓)"
      snapshot+=$(curl -fsS -m 5 "http://localhost:1317/staking/validators/${op}" 2>/dev/null \
        | jq -c '{moniker: .msg.validator.description.moniker, status: .msg.validator.status, jailed: (.msg.validator.jailed // false), tokens: .msg.validator.tokens}')
      snapshot+=$'\n'
    done
    pass "bonded vals (${BONDED_VALS// /, }) all in status=3 post-V170"
  fi

  # ---- 4. dump snapshot ----
  if [[ -n "${SNAPSHOT_FILE:-}" ]]; then
    {
      echo "# post-V170 chain-asserted val state @ $(date +%Y-%m-%dT%H:%M:%S)"
      echo "# height=$h, expected_new_max=$EXPECTED_NEW_MAX, actual_max=$actual_max"
      echo "$snapshot" | grep -v '^$' || true
    } > "$SNAPSHOT_FILE"
    log "  snapshot → $SNAPSHOT_FILE"
  fi
}
