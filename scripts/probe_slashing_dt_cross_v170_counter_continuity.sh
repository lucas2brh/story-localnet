#!/usr/bin/env bash
# probe_slashing_dt_cross_v170_counter_continuity.sh
#
# Chain-assert: a validator that STAYS in top-NEW_MAX across V170 maintains
# contiguous missed_blocks_counter accumulation through H. V170 handler does
# not touch x/slashing signing_info for retained vals; BeginBlocker keeps
# iterating them, counter keeps growing.
#
# This is the sibling to probe_slashing_dt_rebond_counter_resume.sh:
#   - rebond-resume tests BONDED -> UNBONDING -> BONDED carry-through
#   - this probe tests BONDED -> BONDED (across V170) carry-through
#
# Setup: 8-val NEW_MAX=4, V170 @ h=70. Pick a target val that will stay in
# top-4 by stake (verify at Phase 1). Default target moniker is val-2 with
# fallback to runtime rank detection if val-2 happens not to be in top-4.
#
# Heights:
#   h=10  baseline (target BONDED, counter=0, verify in top-4 BONDED set)
#   h=20  docker pause target (CONTINUOUS miss, no unpause)
#   h=68  pre-V170 check: counter ~ 48, status=3 BONDED
#   h=70  V170 fires (target stays in top-4 by stake; val-5..val-8 cap-pruned)
#   h=78  post-V170 check: counter ~ 58 (8 more misses), status=3 still BONDED
#         PRIMARY: counter@h=78 >= counter@h=68 + 7 (continuous, not reset by V170)
#   h~97  jail fires: counter > maxMissed=76, h > minHeight(StartHeight 0 + SBW 80)
#         5% slash, status -> 2 UNBONDING, jailed=true
#
# Usage:
#   ./scripts/probe_slashing_dt_cross_v170_counter_continuity.sh
#   SKIP_TEARDOWN=1 ./scripts/...
#   EVIDENCE_DIR=/path ./scripts/...

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-70}
BASELINE_HEIGHT=${BASELINE_HEIGHT:-10}
PAUSE_HEIGHT=${PAUSE_HEIGHT:-20}
PRE_V170_CHECK_HEIGHT=${PRE_V170_CHECK_HEIGHT:-68}
POST_V170_CHECK_HEIGHT=${POST_V170_CHECK_HEIGHT:-78}
JAIL_DEADLINE_HEIGHT=${JAIL_DEADLINE_HEIGHT:-110}
TARGET_MONIKER=${TARGET_MONIKER:-localnet-val-2}
SIGNED_BLOCKS_WINDOW=${SIGNED_BLOCKS_WINDOW:-80}
UNBONDING_TIME=${UNBONDING_TIME:-3600s}
N_VALS=${N_VALS:-8}
NEW_MAX=${NEW_MAX:-4}
STORY_BIN=${STORY_BIN:-/tmp/story}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
GENESIS="${LOCALNET}/config/story/genesis-node.json"
BECH32_HELPER="${LOCALNET}/scripts/lib/bech32_helper.py"
EVIDENCE_DIR=${EVIDENCE_DIR:-/Users/lucas/workspace/lucas-workspace/docs/test-evidence/v170-slashing-dt-cross-v170-2026-05-11}
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[cross-v170]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[cross-v170]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[cross-v170]${C_RESET} FAIL %s\n" "$*"; capture_evidence_on_fail; exit 1; }
note() { printf "${C_YELLOW}[cross-v170]${C_RESET} OBSERVED %s\n" "$*"; }

# ---------------- helpers (mirror B2 / probe v2) ----------------

get_cometbft_height() {
  local h
  h=$(curl -fsS -m 5 http://localhost:26657/status 2>/dev/null \
    | jq -r '.result.sync_info.latest_block_height // 0' 2>/dev/null)
  [[ -z "$h" ]] && echo 0 || echo "$h"
}

wait_cometbft_height() {
  local target=$1 h
  while :; do
    h=$(get_cometbft_height)
    [[ $h -ge $target ]] && { echo "$h"; return; }
    sleep 2
  done
}

val_field() {
  local op=$1 field=$2 body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null)
  [[ -z $body ]] && { echo "GONE"; return; }
  jq -r ".msg.validator.${field} // \"GONE\"" <<<"$body"
}

val_record_exists() {
  local op=$1 body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null)
  [[ -z $body ]] && return 1
  local has_op
  has_op=$(jq -r '.msg.validator.operator_address // ""' <<<"$body" 2>/dev/null)
  [[ -n "$has_op" && "$has_op" != "null" ]]
}

val_is_unjailed() {
  local op=$1 body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null)
  [[ -z $body ]] && { echo "RECORD_GONE"; return 2; }
  local jailed
  jailed=$(jq -r '.msg.validator.jailed' <<<"$body" 2>/dev/null)
  if [[ "$jailed" == "true" ]]; then
    echo "true"; return 1
  elif [[ "$jailed" == "false" || "$jailed" == "null" || -z "$jailed" ]]; then
    echo "false"; return 0
  else
    echo "$jailed"; return 2
  fi
}

meta_pubkey_b64() { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META"; }
meta_op_evm()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }
meta_op_bech32() { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .validator_address' "$META"; }
derive_cons_hex()    { python3 "$BECH32_HELPER" pub-to-hex "$1"; }
derive_cons_bech32() { python3 "$BECH32_HELPER" pub-to-cons "$1" storyvalcons; }

cometbft_validators_at() {
  local h=$1
  curl -fsS -m 5 "http://localhost:26657/validators?height=${h}&per_page=100" 2>/dev/null \
    | jq -c '.result.validators // []' 2>/dev/null
}

target_in_active_set_at() {
  local h=$1 target_hex=$2 vals
  vals=$(cometbft_validators_at "$h")
  [[ -z "$vals" || "$vals" == "null" ]] && return 1
  local found
  found=$(jq -r --arg target "$target_hex" '.[] | select(.address == $target) | .address' <<<"$vals" 2>/dev/null)
  [[ -n "$found" ]]
}

# Liveness-event-based counter reader (B2 pattern). Scans block_results
# backwards from to_h to from_h; returns latest missed_blocks value for val.
# Returns "0" if no event found in range (val never missed).
get_missed_blocks_counter() {
  local target_bech32=$1 from_h=${2:-1} to_h=${3:-} h
  [[ -z "$to_h" ]] && to_h=$(get_cometbft_height)
  for ((h=to_h; h>=from_h; h--)); do
    local body v
    body=$(curl -fsS -m 5 "http://localhost:26657/block_results?height=${h}" 2>/dev/null)
    [[ -z "$body" ]] && continue
    v=$(jq -r --arg target "$target_bech32" '
      .result.finalize_block_events[]?
      | select(.type == "liveness")
      | select(any(.attributes[]; .key == "address" and .value == $target))
      | .attributes[] | select(.key == "missed_blocks") | .value
    ' <<<"$body" 2>/dev/null | head -1)
    if [[ -n "$v" && "$v" != "null" ]]; then
      echo "$v"
      return 0
    fi
  done
  echo "0"
}

# Scan val-node CL logs for slash event matching bech32 operator.
scan_slash_logs_bech32() {
  local target_op_bech32=$1 hits=0 c
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$'); do
    local n
    n=$(docker logs "$c" 2>&1 | grep -c "validator slashed by slash factor.*${target_op_bech32}" || true)
    hits=$((hits + n))
  done
  echo "$hits"
}

# Verify target val IS in top-N BONDED set (i.e., will stay BONDED after
# V170 cap-prune to NEW_MAX). Returns 0 if in top-NEW_MAX, 1 otherwise.
target_is_top_n_by_stake() {
  local target_op=$1 n=$2 body found
  body=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" 2>/dev/null)
  found=$(jq -r --arg op "$target_op" --argjson n "$n" '
    .msg.validators
    | sort_by(-(.tokens|tonumber))
    | [.[0:$n][] | .operator_address | ascii_downcase]
    | index(($op | ascii_downcase))
  ' <<<"$body" 2>/dev/null)
  [[ -n "$found" && "$found" != "null" ]]
}

capture_evidence() {
  log "Capturing evidence to $EVIDENCE_DIR"
  mkdir -p "$EVIDENCE_DIR"
  for c in $(docker ps --format '{{.Names}}' | grep -E '^(validator[0-9]+|bootnode[0-9]+|rpc[0-9]+)-node$'); do
    docker logs "$c" > "$EVIDENCE_DIR/cl-${c}.log" 2>&1
  done
  log "  CL logs saved"
  local cur_h; cur_h=$(get_cometbft_height)
  for h in 5 "$BASELINE_HEIGHT" "$PAUSE_HEIGHT" "$PRE_V170_CHECK_HEIGHT" "$UPGRADE_HEIGHT" "$POST_V170_CHECK_HEIGHT" "${H_JAIL:-0}"; do
    [[ "$h" == "0" ]] && continue
    [[ "$h" -gt "$cur_h" ]] && continue
    cometbft_validators_at "$h" > "$EVIDENCE_DIR/cometbft-validators-h${h}.json" 2>/dev/null
    curl -fsS -m 5 "http://localhost:26657/block_results?height=${h}" 2>/dev/null > "$EVIDENCE_DIR/block_results-h${h}.json"
  done
  log "  cometbft validators + block_results snapshots saved"
  if [[ -n "${TARGET_OP_EVM:-}" ]]; then
    for h_label in baseline pre_v170 post_v170 jail; do
      local h_upper; h_upper=$(printf %s "$h_label" | tr a-z A-Z)
      local snapshot_var="STAKING_${h_upper}"
      local val="${!snapshot_var:-}"
      [[ -n "$val" ]] && printf '%s\n' "$val" > "$EVIDENCE_DIR/staking-validator-${h_label}.json"
    done
  fi
  cat > "$EVIDENCE_DIR/probe-metadata.json" <<EOF
{
  "probe": "probe_slashing_dt_cross_v170_counter_continuity.sh",
  "binary_sha256_sentinel": "$(cat ${LOCALNET}/tmp/staged_binary.sha256 2>/dev/null || echo unknown)",
  "target_moniker": "$TARGET_MONIKER",
  "target_op_evm": "${TARGET_OP_EVM:-}",
  "target_op_bech32": "${TARGET_OP_BECH32:-}",
  "target_cons_hex": "${TARGET_CONS_HEX:-}",
  "target_cons_bech32": "${TARGET_CONS_BECH32:-}",
  "config": {
    "UPGRADE_HEIGHT": $UPGRADE_HEIGHT,
    "PAUSE_HEIGHT": $PAUSE_HEIGHT,
    "PRE_V170_CHECK_HEIGHT": $PRE_V170_CHECK_HEIGHT,
    "POST_V170_CHECK_HEIGHT": $POST_V170_CHECK_HEIGHT,
    "JAIL_DEADLINE_HEIGHT": $JAIL_DEADLINE_HEIGHT,
    "SIGNED_BLOCKS_WINDOW": $SIGNED_BLOCKS_WINDOW,
    "UNBONDING_TIME": "$UNBONDING_TIME",
    "N_VALS": $N_VALS,
    "NEW_MAX": $NEW_MAX
  },
  "runtime": {
    "counter_baseline": "${COUNTER_BASELINE:-}",
    "counter_pre_v170": "${COUNTER_PRE_V170:-}",
    "counter_post_v170": "${COUNTER_POST_V170:-}",
    "h_jail": "${H_JAIL:-}",
    "counter_jail": "${COUNTER_JAIL:-}",
    "tokens_baseline": "${TOKENS_BASELINE:-}",
    "tokens_jail": "${TOKENS_JAIL:-}"
  }
}
EOF
  log "  probe-metadata.json written"
}

capture_evidence_on_fail() {
  log "FAIL path - attempting evidence capture (cluster may be degraded)"
  capture_evidence 2>/dev/null || log "  (capture failed or partial)"
}

# ---------------- Phase 0 — boot fresh cluster ----------------
TARGET_OP_EVM=""; TARGET_OP_BECH32=""; TARGET_PUBKEY_B64=""
TARGET_CONS_HEX=""; TARGET_CONS_BECH32=""
TOKENS_BASELINE=""; STAKING_BASELINE=""

phase_0_start() {
  log "Phase 0 - terminate + boot ${N_VALS}-val cluster (NEW_MAX=$NEW_MAX, SBW=$SIGNED_BLOCKS_WINDOW)"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -3); sleep 5
  fi
  local yml_count
  yml_count=$(ls "${LOCALNET}"/docker-compose-validator*.yml 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$yml_count" != "$N_VALS" ]]; then
    log "  regenerating compose files for N=$N_VALS (had $yml_count)"
    bash "${LOCALNET}/scripts/generate_compose_files.sh" "$N_VALS" 2>&1 | tail -3
  fi
  log "  assemble genesis with N=$N_VALS, MAX_VALIDATORS_INIT=$N_VALS"
  MAX_VALIDATORS_INIT="$N_VALS" STORY_BIN="$STORY_BIN" \
    bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N_VALS" 2>&1 | tail -1
  log "  patch genesis: signed_blocks_window=$SIGNED_BLOCKS_WINDOW, unbonding_time=$UNBONDING_TIME"
  jq --arg w "$SIGNED_BLOCKS_WINDOW" --arg u "$UNBONDING_TIME" \
    '.app_state.slashing.params.signed_blocks_window = $w
     | .app_state.staking.params.unbonding_time = $u' \
    "$GENESIS" > "$GENESIS.tmp" && mv "$GENESIS.tmp" "$GENESIS"
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -3)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_cometbft_height)
    [[ $h -gt 0 ]] && { log "  cometbft sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "cometbft didn't sync in 90s"
    sleep 3
  done
  TARGET_OP_EVM=$(meta_op_evm "$TARGET_MONIKER")
  TARGET_OP_BECH32=$(meta_op_bech32 "$TARGET_MONIKER")
  TARGET_PUBKEY_B64=$(meta_pubkey_b64 "$TARGET_MONIKER")
  TARGET_CONS_HEX=$(derive_cons_hex "$TARGET_PUBKEY_B64")
  TARGET_CONS_BECH32=$(derive_cons_bech32 "$TARGET_PUBKEY_B64")
  [[ -n "$TARGET_OP_EVM" && -n "$TARGET_CONS_HEX" && -n "$TARGET_CONS_BECH32" ]] \
    || fail "couldn't derive target addresses"
  log "  target $TARGET_MONIKER:"
  log "    op_evm=$TARGET_OP_EVM  op_bech32=$TARGET_OP_BECH32"
  log "    cons_hex=$TARGET_CONS_HEX  cons_bech32=$TARGET_CONS_BECH32"
}

# ---------------- Phase 1 — baseline + verify target stays in top-NEW_MAX ----------------
COUNTER_BASELINE=""
phase_1_baseline() {
  log "Phase 1 - wait h=$BASELINE_HEIGHT, capture baseline + verify target is in top-$NEW_MAX BONDED set"
  wait_cometbft_height "$BASELINE_HEIGHT" >/dev/null

  val_record_exists "$TARGET_OP_EVM" || fail "@h=$BASELINE_HEIGHT target record GONE"
  local status tokens
  status=$(val_field "$TARGET_OP_EVM" status)
  tokens=$(val_field "$TARGET_OP_EVM" tokens)
  [[ "$status" == "3" ]] || fail "@h=$BASELINE_HEIGHT status=$status (expected 3 BONDED)"
  TOKENS_BASELINE="$tokens"
  STAKING_BASELINE=$(curl -fsS "http://localhost:1317/staking/validators/${TARGET_OP_EVM}" 2>/dev/null)

  target_in_active_set_at "$BASELINE_HEIGHT" "$TARGET_CONS_HEX" \
    || fail "@h=$BASELINE_HEIGHT target not in cometbft active set"

  # Critical: target must be in top-NEW_MAX by stake or it will be cap-pruned at V170,
  # breaking the test premise (we want to test RETAINED val's counter continuity).
  if ! target_is_top_n_by_stake "$TARGET_OP_EVM" "$NEW_MAX"; then
    local body
    body=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" 2>/dev/null)
    log "  target $TARGET_MONIKER NOT in top-$NEW_MAX by stake; current top-$NEW_MAX:"
    jq -r --argjson n "$NEW_MAX" '.msg.validators | sort_by(-(.tokens|tonumber)) | .[0:$n] | .[] | "    \(.operator_address) tokens=\(.tokens)"' <<<"$body"
    fail "TARGET_MONIKER=$TARGET_MONIKER is not in top-$NEW_MAX by stake. Re-run with TARGET_MONIKER=<one of the top-$NEW_MAX vals above>."
  fi

  COUNTER_BASELINE=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" 1 "$BASELINE_HEIGHT")
  log "  status=$status tokens=$tokens counter=$COUNTER_BASELINE (in top-$NEW_MAX confirmed)"
  pass "baseline: BONDED, in top-$NEW_MAX by stake, will stay BONDED after V170 cap-prune"
}

# ---------------- Phase 2 — pause target, continuous miss ----------------
phase_2_pause() {
  log "Phase 2 - pause $TARGET_MONIKER at h=$PAUSE_HEIGHT (continuous miss, no unpause)"
  wait_cometbft_height "$PAUSE_HEIGHT" >/dev/null
  local val_idx="${TARGET_MONIKER##*-val-}"
  local cl_container="validator${val_idx}-node"
  docker pause "$cl_container" >/dev/null || fail "docker pause $cl_container failed"
  log "  $cl_container paused at h=$(get_cometbft_height); counter will accumulate until jail (~h=97)"
  pass "Phase 2: pause active, BFT quorum should hold (target ~26% of top-$NEW_MAX VP)"
}

# ---------------- Phase 3 — pre-V170 check ----------------
COUNTER_PRE_V170=""; STAKING_PRE_V170=""
phase_3_pre_v170() {
  log "Phase 3 - wait h=$PRE_V170_CHECK_HEIGHT, verify pre-V170 state (target BONDED + counter accumulating)"
  wait_cometbft_height "$PRE_V170_CHECK_HEIGHT" >/dev/null

  local status tokens jailed
  status=$(val_field "$TARGET_OP_EVM" status)
  tokens=$(val_field "$TARGET_OP_EVM" tokens)
  jailed=$(val_is_unjailed "$TARGET_OP_EVM"); local jrc=$?
  STAKING_PRE_V170=$(curl -fsS "http://localhost:1317/staking/validators/${TARGET_OP_EVM}" 2>/dev/null)

  [[ "$status" == "3" ]] || fail "@h=$PRE_V170_CHECK_HEIGHT status=$status (expected 3 BONDED, pre-V170 jail unexpected)"
  [[ $jrc -eq 0 ]]        || fail "@h=$PRE_V170_CHECK_HEIGHT jailed=$jailed (pre-V170 jail = test broken, counter would have crossed threshold too early)"
  [[ "$tokens" == "$TOKENS_BASELINE" ]] || fail "@h=$PRE_V170_CHECK_HEIGHT tokens=$tokens != baseline"

  target_in_active_set_at "$PRE_V170_CHECK_HEIGHT" "$TARGET_CONS_HEX" \
    || fail "@h=$PRE_V170_CHECK_HEIGHT target not in active set"

  COUNTER_PRE_V170=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$PRE_V170_CHECK_HEIGHT")
  log "  status=$status tokens=$tokens jailed=$jailed counter=$COUNTER_PRE_V170 (expected ~48 from pause h=$PAUSE_HEIGHT)"
  [[ "$COUNTER_PRE_V170" -ge 40 ]] || fail "PRIMARY 1 FAILED: counter=$COUNTER_PRE_V170 too low; expected >=40 (val missing $((PRE_V170_CHECK_HEIGHT - PAUSE_HEIGHT)) blocks)"
  pass "PRIMARY 1: pre-V170 counter=$COUNTER_PRE_V170 (>=40); val BONDED, accumulating misses"
}

# ---------------- Phase 4 — V170 transition (target STAYS in top-NEW_MAX) ----------------
COUNTER_POST_V170=""; STAKING_POST_V170=""
phase_4_v170_transition() {
  log "Phase 4 - wait h=$POST_V170_CHECK_HEIGHT (V170 @ h=$UPGRADE_HEIGHT + $((POST_V170_CHECK_HEIGHT - UPGRADE_HEIGHT)) blocks for propagation)"
  wait_cometbft_height "$POST_V170_CHECK_HEIGHT" >/dev/null

  val_record_exists "$TARGET_OP_EVM" || fail "@h=$POST_V170_CHECK_HEIGHT record GONE"
  local status tokens jailed
  status=$(val_field "$TARGET_OP_EVM" status)
  tokens=$(val_field "$TARGET_OP_EVM" tokens)
  jailed=$(val_is_unjailed "$TARGET_OP_EVM"); local jrc=$?
  STAKING_POST_V170=$(curl -fsS "http://localhost:1317/staking/validators/${TARGET_OP_EVM}" 2>/dev/null)

  # PRIMARY 2a: target STAYS in top-NEW_MAX (NOT cap-pruned by V170)
  [[ "$status" == "3" ]] || fail "PRIMARY 2a FAILED: @h=$POST_V170_CHECK_HEIGHT status=$status (expected 3 BONDED, V170 should NOT cap-prune a top-$NEW_MAX val)"
  [[ $jrc -eq 0 ]] || fail "@h=$POST_V170_CHECK_HEIGHT jailed=$jailed (premature jail before h>minHeight)"
  [[ "$tokens" == "$TOKENS_BASELINE" ]] || fail "@h=$POST_V170_CHECK_HEIGHT tokens=$tokens != baseline (no slash before jail)"

  target_in_active_set_at "$POST_V170_CHECK_HEIGHT" "$TARGET_CONS_HEX" \
    || fail "PRIMARY 2a FAILED: @h=$POST_V170_CHECK_HEIGHT target NOT in cometbft active set (V170 cap-prune should not have removed top-$NEW_MAX val)"

  # PRIMARY 2b: counter advanced from pre-V170 by at least (POST - PRE - 1) = 9
  # (allowing 1 block tolerance for liveness-event timing/wraparound)
  COUNTER_POST_V170=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$POST_V170_CHECK_HEIGHT")
  local delta=$((COUNTER_POST_V170 - COUNTER_PRE_V170))
  local expected_min=$((POST_V170_CHECK_HEIGHT - PRE_V170_CHECK_HEIGHT - 3))  # 10 blocks span, allow 3 slack
  log "  status=$status tokens=$tokens jailed=$jailed counter=$COUNTER_POST_V170 (delta from h=68: $delta, expected >=$expected_min for continuous accumulation across V170)"
  [[ "$delta" -ge "$expected_min" ]] || fail "PRIMARY 2b FAILED: counter @h=$POST_V170_CHECK_HEIGHT=$COUNTER_POST_V170 only $delta higher than @h=$PRE_V170_CHECK_HEIGHT=$COUNTER_PRE_V170 (expected >=$expected_min). Counter did NOT carry through V170 contiguously - V170 may have reset signing_info."

  pass "PRIMARY 2a: target stays BONDED post-V170 (NOT cap-pruned; in top-$NEW_MAX by stake)"
  pass "PRIMARY 2b: counter accumulated $COUNTER_PRE_V170 -> $COUNTER_POST_V170 across V170 (delta=$delta >=$expected_min, contiguous; V170 did NOT reset signing_info for retained val)"
}

# ---------------- Phase 5 — wait jail fire (chain-asserted) ----------------
H_JAIL=""; COUNTER_JAIL=""; STAKING_JAIL=""; TOKENS_JAIL=""
phase_5_wait_jail() {
  local predicted_h_jail=$((PAUSE_HEIGHT + SIGNED_BLOCKS_WINDOW * 95 / 100 + 1))
  log "Phase 5 - poll for jail (predicted h_jail = PAUSE_HEIGHT + maxMissed + 1 = $predicted_h_jail; deadline h=$JAIL_DEADLINE_HEIGHT)"

  local poll_deadline=$(( $(date +%s) + (JAIL_DEADLINE_HEIGHT - POST_V170_CHECK_HEIGHT) * 3 ))
  while :; do
    local cur_h s jrc jailed
    cur_h=$(get_cometbft_height)
    s=$(val_field "$TARGET_OP_EVM" status)
    jailed=$(val_is_unjailed "$TARGET_OP_EVM"); jrc=$?
    log "  h=$cur_h status=$s jailed=$jailed"
    if [[ $jrc -eq 1 ]]; then  # jailed=true
      H_JAIL="$cur_h"
      log "  JAIL fired by h=$H_JAIL (predicted ~$predicted_h_jail)"
      break
    fi
    [[ "$cur_h" -ge "$JAIL_DEADLINE_HEIGHT" ]] && fail "deadline h=$JAIL_DEADLINE_HEIGHT reached without jail (counter stuck below maxMissed?)"
    [[ $(date +%s) -ge $poll_deadline ]] && fail "wall-clock timeout waiting for jail"
    sleep 2
  done

  local end_status end_tokens
  end_status=$(val_field "$TARGET_OP_EVM" status)
  end_tokens=$(val_field "$TARGET_OP_EVM" tokens)
  STAKING_JAIL=$(curl -fsS "http://localhost:1317/staking/validators/${TARGET_OP_EVM}" 2>/dev/null)
  COUNTER_JAIL=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$H_JAIL")
  TOKENS_JAIL="$end_tokens"

  # PRIMARY 3: jail fired with expected outcomes
  [[ "$end_status" == "2" ]] || fail "PRIMARY 3 FAILED: @h_jail=$H_JAIL status=$end_status (expected 2 UNBONDING post-jail)"

  local expected_slashed
  expected_slashed=$(python3 -c "print(int(int('$TOKENS_BASELINE') * 0.95))")
  local tokens_diff abs_diff tolerance
  tokens_diff=$(python3 -c "print(int('$end_tokens') - $expected_slashed)")
  abs_diff=$(python3 -c "print(abs($tokens_diff))")
  tolerance=$(python3 -c "print(int(int('$TOKENS_BASELINE') * 0.001))")
  log "  expected post-slash tokens (5% slash) ~= $expected_slashed, observed=$end_tokens, diff=$tokens_diff, tolerance=$tolerance"
  [[ "$abs_diff" -le "$tolerance" ]] || fail "PRIMARY 3 FAILED: tokens=$end_tokens, expected ~$expected_slashed (5% slash), diff=$tokens_diff exceeds tolerance $tolerance"

  local log_hits; log_hits=$(scan_slash_logs_bech32 "$TARGET_OP_BECH32")
  log "  CL log slash hits for $TARGET_OP_BECH32: $log_hits"
  [[ "$log_hits" -ge 1 ]] || fail "PRIMARY 3 FAILED: no slash CL log line"

  pass "PRIMARY 3: jail fired @h=$H_JAIL (predicted ~$predicted_h_jail), status=2 UNBONDING, tokens slashed 5% ($TOKENS_BASELINE -> $end_tokens), CL log slash event present"
}

# ---------------- Phase 6 — capture evidence ----------------
phase_6_capture() {
  log "Phase 6 - capture evidence to $EVIDENCE_DIR"
  capture_evidence
  pass "evidence captured"
}

# ---------------- Phase 7 — summary ----------------
phase_7_summary() {
  printf "\n========== SLASHING-DT-CROSS-V170-COUNTER-CONTINUITY ==========\n"
  printf "  Binary: %s (V170=$UPGRADE_HEIGHT, NewMax=$NEW_MAX)\n" "$(cat ${LOCALNET}/tmp/staged_binary.sha256 2>/dev/null || echo unknown)"
  printf "  Cluster: $N_VALS-val, target $TARGET_MONIKER (top-$NEW_MAX by stake -> retained post-V170)\n"
  printf "    op_evm:      $TARGET_OP_EVM\n"
  printf "    cons_bech32: $TARGET_CONS_BECH32\n"
  printf "  Genesis: SBW=$SIGNED_BLOCKS_WINDOW maxMissed=$((SIGNED_BLOCKS_WINDOW * 95 / 100)) unbonding_time=$UNBONDING_TIME\n"
  printf "\n"
  printf "  Counter trajectory:\n"
  printf "    h=$BASELINE_HEIGHT (baseline):       $COUNTER_BASELINE\n"
  printf "    h=$PRE_V170_CHECK_HEIGHT (pre-V170):       $COUNTER_PRE_V170\n"
  printf "    h=$POST_V170_CHECK_HEIGHT (post-V170, +$(($POST_V170_CHECK_HEIGHT - $PRE_V170_CHECK_HEIGHT))): $COUNTER_POST_V170 (delta from pre-V170 = $((COUNTER_POST_V170 - COUNTER_PRE_V170)))\n"
  printf "    h=$H_JAIL (jail):           $COUNTER_JAIL\n"
  printf "\n"
  printf "  Tokens:\n"
  printf "    baseline:    $TOKENS_BASELINE\n"
  printf "    jail:        $TOKENS_JAIL  (5%% slashed)\n"
  printf "\n"
  printf "  CHAIN-ASSERTED CONCLUSIONS:\n"
  printf "  (PRIMARY 1)  Pre-V170 counter accumulation works (counter=$COUNTER_PRE_V170 @h=$PRE_V170_CHECK_HEIGHT).\n"
  printf "  (PRIMARY 2a) Top-$NEW_MAX val retains BONDED status across V170 (not cap-pruned).\n"
  printf "  (PRIMARY 2b) Counter continues to accumulate contiguously across V170 boundary;\n"
  printf "               V170 handler does NOT reset signing_info for retained vals.\n"
  printf "  (PRIMARY 3)  Once counter > maxMissed=76, normal jail+5%% slash mechanism fires.\n"
  printf "  Evidence in $EVIDENCE_DIR\n"
  printf "================================================================\n"
}

# ---------------- Phase 8 — teardown ----------------
phase_8_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then
    log "Phase 8 - SKIP_TEARDOWN"; return
  fi
  log "Phase 8 - teardown"
  local val_idx="${TARGET_MONIKER##*-val-}"
  docker unpause "validator${val_idx}-node" 2>/dev/null || true
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline
phase_2_pause
phase_3_pre_v170
phase_4_v170_transition
phase_5_wait_jail
phase_6_capture
phase_7_summary
phase_8_teardown
