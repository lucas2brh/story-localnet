#!/usr/bin/env bash
# probe_slashing_dt_rebond_counter_resume.sh
#
# Chain-assert: after V170 cap-prunes val-5 with a NON-ZERO missed_blocks_counter,
# operator stake-climbs val-5 back into top-NEW_MAX within the UNBONDING window.
# What survives the BONDED→UNBONDING→BONDED transition?
#
# PRIMARY (v1.7.0 carry-through question):
#   At h_rebond+1, signing_info.missed_blocks_counter still equals the value
#   captured pre-V170 (NOT reset to 0). cosmos-sdk x/slashing/keeper/hooks.go
#   AfterValidatorBonded line 28-45 only updates StartHeight; counter and bitmap
#   are preserved.
#
# SECONDARY (slash-gate behavior):
#   AfterValidatorBonded resets signInfo.StartHeight = h_rebond. The slash check
#   at infractions.go:109+118 gates on `height > minHeight` where
#   `minHeight = StartHeight + SignedBlocksWindow`. So even with counter > maxMissed
#   immediately post-rebond, jail does NOT fire during the grace window
#   [h_rebond+1, h_rebond+SignedBlocksWindow]. Earliest jail = h_rebond + SBW + 1.
#
# Setup mirrors probe_unbonding_val_no_downtime_accumulation.sh (v2):
#   8-val NEW_MAX=4, V170 @ h=70, val-5 as offender, SBW=80.
#
# Heights:
#   h=10  baseline (val-5 BONDED, counter=0)
#   h=12  docker pause val-5
#   h≈52  unpause when counter reaches TARGET_COUNTER (default 40)
#   h=68  pre-V170 check (val-5 BONDED, not jailed, counter≈40)
#   h=70  V170 fires (val-5 BONDED → UNBONDING via cap-prune)
#   h=78  post-V170 check (val-5 UNBONDING, counter frozen)
#   h=100 frozen-counter sanity (counter still ≈40)
#   h=100 Anvil delegates massive stake to val-5
#   h≈110 h_rebond (val-5 UNBONDING → BONDED) — captured dynamically
#   h_rebond+1   PRIMARY: counter still ≈40 (carry-through)
#   h_rebond+2   docker pause val-5 again
#   h_rebond+50  SECONDARY 1: counter > maxMissed (76) but val-5 NOT jailed
#   h_rebond+85  SECONDARY 2: val-5 jailed=true, tokens reduced 5%, slash event present
#
# Usage:
#   ./scripts/probe_slashing_dt_rebond_counter_resume.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_slashing_dt_rebond_counter_resume.sh
#   EVIDENCE_DIR=/path ./scripts/probe_slashing_dt_rebond_counter_resume.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-70}
BASELINE_HEIGHT=${BASELINE_HEIGHT:-10}
PAUSE_HEIGHT=${PAUSE_HEIGHT:-12}
POST_PAUSE_VERIFY_HEIGHT=${POST_PAUSE_VERIFY_HEIGHT:-18}
PRE_V170_CHECK_HEIGHT=${PRE_V170_CHECK_HEIGHT:-68}
POST_V170_CHECK_HEIGHT=${POST_V170_CHECK_HEIGHT:-78}
FROZEN_CHECK_HEIGHT=${FROZEN_CHECK_HEIGHT:-100}
DELEGATE_HEIGHT=${DELEGATE_HEIGHT:-100}
TARGET_COUNTER=${TARGET_COUNTER:-40}
VSU_BLOCKS=${VSU_BLOCKS:-15}
GRACE_MID_OFFSET=${GRACE_MID_OFFSET:-50}
GRACE_END_OFFSET=${GRACE_END_OFFSET:-90}
TARGET_MONIKER=${TARGET_MONIKER:-localnet-val-5}
SIGNED_BLOCKS_WINDOW=${SIGNED_BLOCKS_WINDOW:-80}
UNBONDING_TIME=${UNBONDING_TIME:-3600s}
N_VALS=${N_VALS:-8}
NEW_MAX=${NEW_MAX:-4}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
STAKE_MARGIN=${STAKE_MARGIN:-4}     # numerator/10 → stake = rank_NEW_MAX_tokens * 0.4; val-5 just barely passes rank-4, cluster share <33% so pause doesn't break BFT quorum
WEI_PER_STAKE=${WEI_PER_STAKE:-1000000000}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
GENESIS="${LOCALNET}/config/story/genesis-node.json"
BECH32_HELPER="${LOCALNET}/scripts/lib/bech32_helper.py"
EVIDENCE_DIR=${EVIDENCE_DIR:-/Users/lucas/workspace/lucas-workspace/docs/test-evidence/v170-slashing-dt-rebond-2026-05-11}
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[rebond-resume]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[rebond-resume]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[rebond-resume]${C_RESET} FAIL %s\n" "$*"; capture_evidence_on_fail; exit 1; }
note() { printf "${C_YELLOW}[rebond-resume]${C_RESET} OBSERVED %s\n" "$*"; }

# ---------------- helpers (mirrored from probe v2) ----------------

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
meta_pubkey_hex() { local b64; b64=$(meta_pubkey_b64 "$1"); echo -n "$b64" | base64 -d | xxd -p -c 66; }
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

last_commit_size_at() {
  local h=$1
  curl -fsS -m 5 "http://localhost:26657/block?height=${h}" 2>/dev/null \
    | jq -r '.result.block.last_commit.signatures | length' 2>/dev/null
}

# Get current missed_blocks_counter for val from block_results liveness events.
# cosmos-sdk x/slashing/keeper/infractions.go:91-98 emits liveness event each
# time a val MISSES a block, with attribute missed_blocks = counter value.
# Story's REST gateway does NOT expose /cosmos/slashing/v1beta1/signing_infos
# (returns 404), so this is the chain-asserted alternative.
#
# Scans block_results backwards from to_h to from_h, returns missed_blocks of
# the first matching liveness event found. If none found in range, returns "0"
# (val never missed → counter == 0 by cosmos-sdk default).
#
# Liveness event format (cometbft v0.38, plain-text attrs):
#   { "type": "liveness",
#     "attributes": [
#       {"key":"address","value":"storyvalcons1..."},
#       {"key":"missed_blocks","value":"<N>"},
#       {"key":"height","value":"<H>"},
#       {"key":"mode","value":"BeginBlock"}
#     ] }
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

# Get full liveness event for val at the most recent height in range.
# Returns the JSON event object, or "{}" if not found.
get_signing_info_full() {
  local target_bech32=$1 from_h=${2:-1} to_h=${3:-} h
  [[ -z "$to_h" ]] && to_h=$(get_cometbft_height)
  for ((h=to_h; h>=from_h; h--)); do
    local body ev
    body=$(curl -fsS -m 5 "http://localhost:26657/block_results?height=${h}" 2>/dev/null)
    [[ -z "$body" ]] && continue
    ev=$(jq -c --arg target "$target_bech32" '
      .result.finalize_block_events[]?
      | select(.type == "liveness")
      | select(any(.attributes[]; .key == "address" and .value == $target))
    ' <<<"$body" 2>/dev/null | head -1)
    if [[ -n "$ev" && "$ev" != "null" ]]; then
      echo "$ev"
      return 0
    fi
  done
  echo "{}"
}

scan_slash_events_strict() {
  local from=$1 to=$2 target_cons_bech32=$3 hits=0 h
  for ((h=from; h<=to; h++)); do
    local body
    body=$(curl -fsS -m 5 "http://localhost:26657/block_results?height=${h}" 2>/dev/null)
    [[ -z "$body" ]] && continue
    local hit
    hit=$(jq -r --arg target "$target_cons_bech32" '
      .result.begin_block_events[]?
      | select(.type == "slash")
      | .attributes[]
      | select((.key | @base64d) == "address")
      | (.value | @base64d)
      | select(. == $target)
    ' <<<"$body" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${hit:-0}" -gt 0 ]]; then
      hits=$((hits + hit))
      log "  slash event MATCH at h=$h (cons_bech32=$target_cons_bech32 count=$hit)"
    fi
  done
  echo "$hits"
}

scan_slash_logs_bech32() {
  local target_op_bech32=$1 hits=0 c
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$'); do
    local n
    n=$(docker logs "$c" 2>&1 | grep -c "validator slashed by slash factor.*${target_op_bech32}" || true)
    hits=$((hits + n))
  done
  echo "$hits"
}

capture_evidence() {
  log "Capturing evidence to $EVIDENCE_DIR"
  mkdir -p "$EVIDENCE_DIR"
  for c in $(docker ps --format '{{.Names}}' | grep -E '^(validator[0-9]+|bootnode[0-9]+|rpc[0-9]+)-node$'); do
    docker logs "$c" > "$EVIDENCE_DIR/cl-${c}.log" 2>&1
  done
  log "  CL logs saved"
  local cur_h; cur_h=$(get_cometbft_height)
  for h in 5 "$BASELINE_HEIGHT" "$POST_PAUSE_VERIFY_HEIGHT" "$PRE_V170_CHECK_HEIGHT" "$POST_V170_CHECK_HEIGHT" "$FROZEN_CHECK_HEIGHT" "${H_REBOND:-0}" "${H_REBOND_PLUS_1:-0}" "${H_GRACE_MID:-0}" "${H_GRACE_END:-0}"; do
    [[ "$h" == "0" ]] && continue
    [[ "$h" -gt "$cur_h" ]] && continue
    cometbft_validators_at "$h" > "$EVIDENCE_DIR/cometbft-validators-h${h}.json" 2>/dev/null
    curl -fsS -m 5 "http://localhost:26657/block?height=${h}" 2>/dev/null > "$EVIDENCE_DIR/block-h${h}.json"
  done
  log "  cometbft validators + block snapshots saved"
  if [[ -n "${TARGET_OP_EVM:-}" ]]; then
    for h_label in baseline pre_v170 post_v170 frozen rebond_plus_1 grace_mid grace_end; do
      local h_upper; h_upper=$(printf %s "$h_label" | tr a-z A-Z)
      local snapshot_var="STAKING_${h_upper}"
      local val="${!snapshot_var:-}"
      [[ -n "$val" ]] && printf '%s\n' "$val" > "$EVIDENCE_DIR/staking-validator-${h_label}.json"
    done
  fi
  if [[ -n "${TARGET_CONS_BECH32:-}" ]]; then
    for h_label in baseline pre_v170 post_v170 frozen rebond_plus_1 grace_mid grace_end; do
      local h_upper; h_upper=$(printf %s "$h_label" | tr a-z A-Z)
      local snapshot_var="SIGNING_${h_upper}"
      local val="${!snapshot_var:-}"
      [[ -n "$val" ]] && printf '%s\n' "$val" > "$EVIDENCE_DIR/signing-info-${h_label}.json"
    done
  fi
  cat > "$EVIDENCE_DIR/probe-metadata.json" <<EOF
{
  "probe": "probe_slashing_dt_rebond_counter_resume.sh",
  "binary_sha256_sentinel": "$(cat ${LOCALNET}/tmp/staged_binary.sha256 2>/dev/null || echo unknown)",
  "target_moniker": "$TARGET_MONIKER",
  "target_op_evm": "${TARGET_OP_EVM:-}",
  "target_op_bech32": "${TARGET_OP_BECH32:-}",
  "target_cons_hex": "${TARGET_CONS_HEX:-}",
  "target_cons_bech32": "${TARGET_CONS_BECH32:-}",
  "config": {
    "UPGRADE_HEIGHT": $UPGRADE_HEIGHT,
    "PAUSE_HEIGHT": $PAUSE_HEIGHT,
    "TARGET_COUNTER": $TARGET_COUNTER,
    "PRE_V170_CHECK_HEIGHT": $PRE_V170_CHECK_HEIGHT,
    "POST_V170_CHECK_HEIGHT": $POST_V170_CHECK_HEIGHT,
    "FROZEN_CHECK_HEIGHT": $FROZEN_CHECK_HEIGHT,
    "DELEGATE_HEIGHT": $DELEGATE_HEIGHT,
    "VSU_BLOCKS": $VSU_BLOCKS,
    "GRACE_MID_OFFSET": $GRACE_MID_OFFSET,
    "GRACE_END_OFFSET": $GRACE_END_OFFSET,
    "SIGNED_BLOCKS_WINDOW": $SIGNED_BLOCKS_WINDOW,
    "UNBONDING_TIME": "$UNBONDING_TIME",
    "N_VALS": $N_VALS,
    "NEW_MAX": $NEW_MAX
  },
  "runtime": {
    "h_rebond": "${H_REBOND:-}",
    "counter_baseline": "${COUNTER_BASELINE:-}",
    "counter_pre_v170": "${COUNTER_PRE_V170:-}",
    "counter_post_v170": "${COUNTER_POST_V170:-}",
    "counter_frozen": "${COUNTER_FROZEN:-}",
    "counter_rebond_plus_1": "${COUNTER_REBOND_PLUS_1:-}",
    "counter_grace_mid": "${COUNTER_GRACE_MID:-}",
    "counter_grace_end": "${COUNTER_GRACE_END:-}",
    "tokens_baseline": "${TOKENS_BASELINE:-}",
    "tokens_grace_end": "${TOKENS_GRACE_END:-}"
  }
}
EOF
  log "  probe-metadata.json written"
}

capture_evidence_on_fail() {
  log "FAIL path — attempting evidence capture (cluster may be degraded)"
  capture_evidence 2>/dev/null || log "  (capture failed or partial)"
}

# ---------------- Phase 0 — boot fresh cluster ----------------
TARGET_OP_EVM=""; TARGET_OP_BECH32=""; TARGET_PUBKEY_B64=""; TARGET_PUBKEY_HEX=""
TARGET_CONS_HEX=""; TARGET_CONS_BECH32=""
TOKENS_BASELINE=""; STAKING_BASELINE=""; SIGNING_BASELINE=""

phase_0_start() {
  log "Phase 0 — terminate existing + patch genesis + boot ${N_VALS}-val cluster (NEW_MAX=$NEW_MAX, SBW=$SIGNED_BLOCKS_WINDOW)"
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

  local sw min_signed slash_dt dj
  sw=$(jq -r '.app_state.slashing.params.signed_blocks_window' "$GENESIS")
  min_signed=$(jq -r '.app_state.slashing.params.min_signed_per_window' "$GENESIS")
  slash_dt=$(jq -r '.app_state.slashing.params.slash_fraction_downtime' "$GENESIS")
  dj=$(jq -r '.app_state.slashing.params.downtime_jail_duration' "$GENESIS")
  local max_missed
  max_missed=$(python3 -c "print(int($sw) - int(float('$min_signed') * int($sw)))")
  log "  slashing.params: SBW=$sw min_signed=$min_signed slash_dt=$slash_dt jail_dur=$dj  maxMissed=$max_missed"

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
  TARGET_PUBKEY_HEX=$(meta_pubkey_hex "$TARGET_MONIKER")
  TARGET_CONS_HEX=$(derive_cons_hex "$TARGET_PUBKEY_B64")
  TARGET_CONS_BECH32=$(derive_cons_bech32 "$TARGET_PUBKEY_B64")

  [[ -n "$TARGET_OP_EVM" && -n "$TARGET_CONS_HEX" && -n "$TARGET_CONS_BECH32" ]] \
    || fail "couldn't derive target addresses (op=$TARGET_OP_EVM cons_hex=$TARGET_CONS_HEX cons_bech32=$TARGET_CONS_BECH32)"

  log "  target $TARGET_MONIKER:"
  log "    op_evm=$TARGET_OP_EVM"
  log "    op_bech32=$TARGET_OP_BECH32"
  log "    cons_hex=$TARGET_CONS_HEX"
  log "    cons_bech32=$TARGET_CONS_BECH32"
}

# ---------------- Phase 1 — baseline ----------------
COUNTER_BASELINE=""
phase_1_baseline() {
  log "Phase 1 — wait h=$BASELINE_HEIGHT, capture baseline"
  wait_cometbft_height "$BASELINE_HEIGHT" >/dev/null

  val_record_exists "$TARGET_OP_EVM" || fail "@h=$BASELINE_HEIGHT target record GONE"
  local status tokens
  status=$(val_field "$TARGET_OP_EVM" status)
  tokens=$(val_field "$TARGET_OP_EVM" tokens)
  val_is_unjailed "$TARGET_OP_EVM" >/dev/null
  [[ "$status" == "3" ]] || fail "@h=$BASELINE_HEIGHT status=$status (expected 3 BONDED)"
  TOKENS_BASELINE="$tokens"
  STAKING_BASELINE=$(curl -fsS "http://localhost:1317/staking/validators/${TARGET_OP_EVM}" 2>/dev/null)
  SIGNING_BASELINE=$(get_signing_info_full "$TARGET_CONS_BECH32" 1 "$BASELINE_HEIGHT")

  target_in_active_set_at "$BASELINE_HEIGHT" "$TARGET_CONS_HEX" \
    || fail "@h=$BASELINE_HEIGHT target not in cometbft active set"

  COUNTER_BASELINE=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" 1 "$BASELINE_HEIGHT")
  log "  status=$status tokens=$tokens counter=$COUNTER_BASELINE (via liveness events; '0' = val never missed)"
  [[ "$COUNTER_BASELINE" == "0" ]] || note "baseline counter=$COUNTER_BASELINE (expected 0 at fresh start)"
  pass "baseline: BONDED, in active set, counter=$COUNTER_BASELINE"
}

# ---------------- Phase 2 — pause + poll counter to TARGET_COUNTER ----------------
COUNTER_PAUSE_END=""
phase_2_pause_to_target() {
  log "Phase 2 — pause val-5 at h=$PAUSE_HEIGHT, poll counter, unpause at counter≥$TARGET_COUNTER"
  wait_cometbft_height "$PAUSE_HEIGHT" >/dev/null
  local val_idx="${TARGET_MONIKER##*-val-}"
  local cl_container="validator${val_idx}-node"
  docker pause "$cl_container" >/dev/null || fail "docker pause $cl_container failed"
  log "  $cl_container paused at h=$(get_cometbft_height)"

  local poll_deadline=$(( $(date +%s) + 180 ))
  while :; do
    local cur_h ctr restarting dead
    cur_h=$(get_cometbft_height)
    ctr=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$cur_h")
    restarting=$(docker ps --format '{{.Status}}' | grep -c Restarting | tr -d ' ')
    dead=$(docker ps -a --format '{{.Status}}' | grep -cE 'Exited \(1|Exited \(2|Dead' | tr -d ' ')
    log "  h=$cur_h counter=$ctr restarting=$restarting dead=$dead"

    [[ "$restarting" != "0" || "$dead" != "0" ]] && fail "containers unhealthy: restarting=$restarting dead=$dead"

    if [[ "$ctr" -ge "$TARGET_COUNTER" ]]; then
      docker unpause "$cl_container" >/dev/null || fail "docker unpause $cl_container failed"
      COUNTER_PAUSE_END="$ctr"
      log "  unpaused at h=$cur_h counter=$ctr (target $TARGET_COUNTER)"
      break
    fi

    if [[ "$ctr" -ge "$((SIGNED_BLOCKS_WINDOW * 95 / 100 - 5))" ]]; then
      docker unpause "$cl_container" >/dev/null || true
      fail "counter=$ctr approaching maxMissed=$((SIGNED_BLOCKS_WINDOW * 95 / 100)); emergency unpause to avoid pre-V170 jail"
    fi

    [[ $(date +%s) -ge $poll_deadline ]] && { docker unpause "$cl_container" >/dev/null; fail "poll timeout, counter=$ctr"; }
    sleep 2
  done

  pass "Phase 2: counter reached $COUNTER_PAUSE_END, unpaused (pre-V170 jail avoided)"
}

# ---------------- Phase 3 — pre-V170 ----------------
COUNTER_PRE_V170=""; STAKING_PRE_V170=""; SIGNING_PRE_V170=""
phase_3_pre_v170() {
  log "Phase 3 — wait h=$PRE_V170_CHECK_HEIGHT, verify pre-V170 state"
  wait_cometbft_height "$PRE_V170_CHECK_HEIGHT" >/dev/null

  local status tokens jailed
  status=$(val_field "$TARGET_OP_EVM" status)
  tokens=$(val_field "$TARGET_OP_EVM" tokens)
  jailed=$(val_is_unjailed "$TARGET_OP_EVM"); local jrc=$?
  STAKING_PRE_V170=$(curl -fsS "http://localhost:1317/staking/validators/${TARGET_OP_EVM}" 2>/dev/null)
  SIGNING_PRE_V170=$(get_signing_info_full "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$PRE_V170_CHECK_HEIGHT")

  [[ "$status" == "3" ]]  || fail "@h=$PRE_V170_CHECK_HEIGHT status=$status (expected 3 BONDED)"
  [[ $jrc -eq 0 ]]         || fail "@h=$PRE_V170_CHECK_HEIGHT jailed=$jailed (pre-V170 jail unexpected)"
  [[ "$tokens" == "$TOKENS_BASELINE" ]] || fail "@h=$PRE_V170_CHECK_HEIGHT tokens=$tokens != baseline"

  target_in_active_set_at "$PRE_V170_CHECK_HEIGHT" "$TARGET_CONS_HEX" \
    || fail "@h=$PRE_V170_CHECK_HEIGHT target not in active set"

  COUNTER_PRE_V170=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$PRE_V170_CHECK_HEIGHT")
  log "  status=$status tokens=$tokens jailed=$jailed counter=$COUNTER_PRE_V170"
  pass "Phase 3: BONDED, not jailed, in active set, counter=$COUNTER_PRE_V170"
}

# ---------------- Phase 4 — V170 cap-prune transition ----------------
COUNTER_POST_V170=""; STAKING_POST_V170=""; SIGNING_POST_V170=""
phase_4_v170_transition() {
  log "Phase 4 — wait h=$POST_V170_CHECK_HEIGHT (V170 @ h=$UPGRADE_HEIGHT + $((POST_V170_CHECK_HEIGHT - UPGRADE_HEIGHT)) blocks)"
  wait_cometbft_height "$POST_V170_CHECK_HEIGHT" >/dev/null

  val_record_exists "$TARGET_OP_EVM" || fail "@h=$POST_V170_CHECK_HEIGHT record GONE (cap-prune should NOT remove)"
  local status tokens jailed
  status=$(val_field "$TARGET_OP_EVM" status)
  tokens=$(val_field "$TARGET_OP_EVM" tokens)
  jailed=$(val_is_unjailed "$TARGET_OP_EVM"); local jrc=$?
  STAKING_POST_V170=$(curl -fsS "http://localhost:1317/staking/validators/${TARGET_OP_EVM}" 2>/dev/null)
  SIGNING_POST_V170=$(get_signing_info_full "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$POST_V170_CHECK_HEIGHT")

  [[ "$status" == "2" ]] || fail "@h=$POST_V170_CHECK_HEIGHT status=$status (expected 2 UNBONDING after V170 cap-prune)"
  [[ $jrc -eq 0 ]] || fail "@h=$POST_V170_CHECK_HEIGHT jailed=$jailed (cap-prune doesn't jail; if true, downtime fired pre-V170)"
  [[ "$tokens" == "$TOKENS_BASELINE" ]] || fail "@h=$POST_V170_CHECK_HEIGHT tokens=$tokens != baseline (no slash on cap-prune)"

  if target_in_active_set_at "$POST_V170_CHECK_HEIGHT" "$TARGET_CONS_HEX"; then
    fail "@h=$POST_V170_CHECK_HEIGHT target STILL in cometbft active set — cap-prune didn't propagate to val_set_updates"
  fi

  local size; size=$(last_commit_size_at "$POST_V170_CHECK_HEIGHT")
  log "  last_commit size @h=$POST_V170_CHECK_HEIGHT = $size (expected $NEW_MAX post-V170)"

  COUNTER_POST_V170=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$POST_V170_CHECK_HEIGHT")
  log "  status=$status tokens=$tokens jailed=$jailed counter=$COUNTER_POST_V170"
  pass "Phase 4: V170 cap-prune transition: status=2 UNBONDING, removed from active set, counter=$COUNTER_POST_V170"
}

# ---------------- Phase 5 — frozen verification @ h=FROZEN_CHECK_HEIGHT ----------------
COUNTER_FROZEN=""; STAKING_FROZEN=""; SIGNING_FROZEN=""
phase_5_frozen_check() {
  log "Phase 5 — wait h=$FROZEN_CHECK_HEIGHT, verify counter frozen during UNBONDING"
  wait_cometbft_height "$FROZEN_CHECK_HEIGHT" >/dev/null

  STAKING_FROZEN=$(curl -fsS "http://localhost:1317/staking/validators/${TARGET_OP_EVM}" 2>/dev/null)
  SIGNING_FROZEN=$(get_signing_info_full "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$FROZEN_CHECK_HEIGHT")
  COUNTER_FROZEN=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$FROZEN_CHECK_HEIGHT")

  log "  counter @h=$FROZEN_CHECK_HEIGHT = $COUNTER_FROZEN (vs post-V170 $COUNTER_POST_V170)"
  local delta=$((COUNTER_FROZEN - COUNTER_POST_V170))
  [[ "$delta" -le 1 && "$delta" -ge -1 ]] || fail "counter not frozen: delta=$delta over $((FROZEN_CHECK_HEIGHT - POST_V170_CHECK_HEIGHT)) UNBONDING blocks"
  pass "Phase 5: counter frozen during UNBONDING (delta=$delta)"
}

# ---------------- Phase 6 — Anvil stake-climb to push val-5 back to BONDED ----------------
STAKE_WEI=""; DELEGATE_TX=""; H_REBOND=""
phase_6_stake_climb() {
  log "Phase 6 — Anvil delegates massive stake to $TARGET_MONIKER (currently UNBONDING) to force re-bond"

  local vals count rank_N_tokens
  vals=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100")
  count=$(jq '.msg.validators | length' <<<"$vals")
  [[ "$count" == "$NEW_MAX" ]] || fail "bonded count=$count (expected $NEW_MAX post-V170)"
  rank_N_tokens=$(jq -r --argjson n "$NEW_MAX" '.msg.validators | sort_by(-(.tokens|tonumber)) | .[($n-1)].tokens' <<<"$vals")
  log "  current rank-$NEW_MAX tokens=$rank_N_tokens"

  STAKE_WEI=$(echo "$rank_N_tokens * $STAKE_MARGIN / 10 * $WEI_PER_STAKE" | bc)
  local stake_ip; stake_ip=$(echo "$STAKE_WEI / 1000000000000000000" | bc)
  log "  Anvil will delegate $STAKE_WEI wei (~$stake_ip IP, ${STAKE_MARGIN}/10 × rank_N tokens)"

  local out rc
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
    --validator-pubkey "$TARGET_PUBKEY_HEX" --stake "$STAKE_WEI" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  DELEGATE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  log "  delegate tx=$DELEGATE_TX rc=$rc"
  [[ "$rc" == "0" ]] || fail "delegate cli rc=$rc"

  log "  poll val-5 status for UNBONDING → BONDED transition (timeout $((VSU_BLOCKS * 3))s after VSU_BLOCKS=$VSU_BLOCKS)"
  local poll_deadline=$(( $(date +%s) + VSU_BLOCKS * 3 ))
  local h_status3=""
  while :; do
    local s h; s=$(val_field "$TARGET_OP_EVM" status); h=$(get_cometbft_height)
    log "  h=$h status=$s"
    if [[ "$s" == "3" ]]; then
      h_status3="$h"
      log "  REST staking status=3 BONDED first seen at h=$h_status3"
      break
    fi
    [[ $(date +%s) -ge $poll_deadline ]] && fail "val-5 didn't re-bond after delegate within ${VSU_BLOCKS}×3=$((VSU_BLOCKS * 3))s"
    sleep 2
  done

  # cosmos-sdk staking EndBlock at h_status3 emits validator_update; CometBFT
  # applies it at h_status3 + ValidatorUpdateDelay(1) + 1 = h_status3+2. So
  # /validators?height=h_status3 still reflects OLD set. Wait h_status3+3 then
  # confirm chain-side active set membership before declaring re-bond.
  local h_check=$((h_status3 + 3))
  log "  wait h=$h_check (status3 + 3 for val_set_update propagation) then verify cometbft active set"
  wait_cometbft_height "$h_check" >/dev/null
  target_in_active_set_at "$h_check" "$TARGET_CONS_HEX" \
    || fail "@h=$h_check target NOT in cometbft active set 3 blocks past REST status=3 — propagation slower than expected"

  # H_REBOND = the chain-side moment val-5 is BOTH BONDED in staking AND in
  # cometbft active set. Use h_check as the canonical re-bond height.
  H_REBOND="$h_check"
  log "  re-bonded (status3 + active set membership both true) at H_REBOND=$H_REBOND"

  pass "Phase 6: stake-climb succeeded, val-5 re-BONDED at h_rebond=$H_REBOND (REST status=3 @ h=$h_status3, active set @ h=$h_check)"
}

# ---------------- Phase 7 — PRIMARY carry-through check @ h_rebond+1 ----------------
COUNTER_REBOND_PLUS_1=""; SIGNING_REBOND_PLUS_1=""; H_REBOND_PLUS_1=""
phase_7_primary_carry_through() {
  H_REBOND_PLUS_1=$((H_REBOND + 1))
  log "Phase 7 — wait h_rebond+1=$H_REBOND_PLUS_1, PRIMARY: counter must equal frozen value (carry-through)"
  wait_cometbft_height "$H_REBOND_PLUS_1" >/dev/null

  SIGNING_REBOND_PLUS_1=$(get_signing_info_full "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$H_REBOND_PLUS_1")
  COUNTER_REBOND_PLUS_1=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" "$PAUSE_HEIGHT" "$H_REBOND_PLUS_1")

  log "  counter @h_rebond+1=$H_REBOND_PLUS_1 = $COUNTER_REBOND_PLUS_1 (vs frozen=$COUNTER_FROZEN)"

  local delta=$((COUNTER_REBOND_PLUS_1 - COUNTER_FROZEN))
  if [[ "$COUNTER_REBOND_PLUS_1" -eq 0 && "$COUNTER_FROZEN" -gt 0 ]]; then
    fail "PRIMARY FAILED: counter reset to 0 on re-bond (frozen was $COUNTER_FROZEN). Refutes carry-through hypothesis — AfterValidatorBonded resets counter, contradicting x/slashing/keeper/hooks.go:28-45 reading."
  fi
  [[ "$delta" -ge 0 && "$delta" -le 3 ]] || fail "PRIMARY FAILED: counter @h_rebond+1=$COUNTER_REBOND_PLUS_1 vs frozen=$COUNTER_FROZEN, delta=$delta (expected ≥0, ≤3 for one-block fresh-position increment)"

  pass "PRIMARY: counter carried through UNBONDING→BONDED (frozen=$COUNTER_FROZEN, h_rebond+1=$COUNTER_REBOND_PLUS_1, delta=$delta)"
}

# ---------------- Phase 8 — pause again, verify grace window + delayed jail ----------------
COUNTER_GRACE_MID=""; STAKING_GRACE_MID=""; SIGNING_GRACE_MID=""; H_GRACE_MID=""
COUNTER_GRACE_END=""; STAKING_GRACE_END=""; SIGNING_GRACE_END=""; H_GRACE_END=""; TOKENS_GRACE_END=""
phase_8_grace_and_jail() {
  log "Phase 8 — pause val-5 again at h_rebond+2, verify grace window + delayed jail"
  local val_idx="${TARGET_MONIKER##*-val-}"
  local cl_container="validator${val_idx}-node"
  wait_cometbft_height "$((H_REBOND + 2))" >/dev/null
  docker pause "$cl_container" >/dev/null || fail "docker pause $cl_container (second pause) failed"
  log "  $cl_container paused (again) at h=$(get_cometbft_height)"

  H_GRACE_MID=$((H_REBOND + GRACE_MID_OFFSET))
  log "  wait h_rebond+$GRACE_MID_OFFSET=$H_GRACE_MID — SECONDARY 1: inside grace window, val-5 still BONDED + not jailed despite post-rebond miss accumulation"
  wait_cometbft_height "$H_GRACE_MID" >/dev/null

  local mid_status mid_jailed
  mid_status=$(val_field "$TARGET_OP_EVM" status)
  mid_jailed=$(val_is_unjailed "$TARGET_OP_EVM"); local mid_jrc=$?
  STAKING_GRACE_MID=$(curl -fsS "http://localhost:1317/staking/validators/${TARGET_OP_EVM}" 2>/dev/null)
  SIGNING_GRACE_MID=$(get_signing_info_full "$TARGET_CONS_BECH32" "$((H_REBOND + 2))" "$H_GRACE_MID")
  COUNTER_GRACE_MID=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" "$((H_REBOND + 2))" "$H_GRACE_MID")

  log "  @h_grace_mid=$H_GRACE_MID status=$mid_status jailed=$mid_jailed counter=$COUNTER_GRACE_MID (grace window ends at h=$((H_REBOND + SIGNED_BLOCKS_WINDOW)))"
  [[ $mid_jrc -eq 0 ]] || fail "SECONDARY 1 FAILED: val-5 jailed @h=$H_GRACE_MID (inside grace window h<=h_rebond+SBW=$((H_REBOND + SIGNED_BLOCKS_WINDOW)))"
  [[ "$mid_status" == "3" ]] || fail "SECONDARY 1 FAILED: status=$mid_status @h=$H_GRACE_MID (expected 3 BONDED inside grace window)"
  [[ "$COUNTER_GRACE_MID" -gt "$COUNTER_REBOND_PLUS_1" ]] || fail "SECONDARY 1 FAILED: counter $COUNTER_GRACE_MID NOT > rebond+1 counter $COUNTER_REBOND_PLUS_1; post-rebond miss not accumulating"
  pass "SECONDARY 1: grace window holds @h=$H_GRACE_MID; counter accumulated $COUNTER_REBOND_PLUS_1 -> $COUNTER_GRACE_MID, val still BONDED+unjailed"

  H_GRACE_END=$((H_REBOND + GRACE_END_OFFSET))
  log "  wait h_rebond+$GRACE_END_OFFSET=$H_GRACE_END (past minHeight=h_rebond+SBW=$((H_REBOND + SIGNED_BLOCKS_WINDOW))) — SECONDARY 2: jail fires"
  wait_cometbft_height "$H_GRACE_END" >/dev/null

  local end_status end_tokens end_jailed
  end_status=$(val_field "$TARGET_OP_EVM" status)
  end_tokens=$(val_field "$TARGET_OP_EVM" tokens)
  end_jailed=$(val_is_unjailed "$TARGET_OP_EVM"); local end_jrc=$?
  STAKING_GRACE_END=$(curl -fsS "http://localhost:1317/staking/validators/${TARGET_OP_EVM}" 2>/dev/null)
  SIGNING_GRACE_END=$(get_signing_info_full "$TARGET_CONS_BECH32" "$((H_REBOND + 2))" "$H_GRACE_END")
  COUNTER_GRACE_END=$(get_missed_blocks_counter "$TARGET_CONS_BECH32" "$((H_REBOND + 2))" "$H_GRACE_END")
  TOKENS_GRACE_END="$end_tokens"

  log "  @h_grace_end=$H_GRACE_END status=$end_status jailed=$end_jailed counter=$COUNTER_GRACE_END tokens=$end_tokens"

  [[ $end_jrc -eq 1 ]] || fail "SECONDARY 2 FAILED: val-5 NOT jailed @h=$H_GRACE_END (expected jailed=true past minHeight=$((H_REBOND + SIGNED_BLOCKS_WINDOW))); counter=$COUNTER_GRACE_END"
  [[ "$end_status" == "2" ]] || fail "SECONDARY 2 FAILED: status=$end_status @h=$H_GRACE_END (expected 2 UNBONDING after jail+unbond)"

  local expected_slashed_tokens
  expected_slashed_tokens=$(python3 -c "print(int(int('$TOKENS_BASELINE') * 0.95))")
  local tokens_diff
  tokens_diff=$(python3 -c "print(int('$end_tokens') - $expected_slashed_tokens)")
  log "  expected post-slash tokens (5% slash) ≈ $expected_slashed_tokens, observed=$end_tokens, diff=$tokens_diff"
  local abs_diff
  abs_diff=$(python3 -c "print(abs($tokens_diff))")
  local tolerance
  tolerance=$(python3 -c "print(int(int('$TOKENS_BASELINE') * 0.001))")
  [[ "$abs_diff" -le "$tolerance" ]] || fail "SECONDARY 2 FAILED: tokens=$end_tokens, expected ≈$expected_slashed_tokens (5% slash from baseline $TOKENS_BASELINE), diff=$tokens_diff exceeds tolerance $tolerance"

  pass "SECONDARY 2: jail fired by h_grace_end=$H_GRACE_END (past minHeight=h_rebond+SBW=$((H_REBOND + SIGNED_BLOCKS_WINDOW))), tokens slashed 5% (baseline=$TOKENS_BASELINE → $end_tokens)"

  log "  scan slash events in block_results h=$H_REBOND..$H_GRACE_END targeting $TARGET_CONS_BECH32"
  local ev_hits; ev_hits=$(scan_slash_events_strict "$H_REBOND" "$H_GRACE_END" "$TARGET_CONS_BECH32")
  log "  scan_slash_events_strict hits: $ev_hits"
  [[ "$ev_hits" -ge 1 ]] || fail "SECONDARY 2 FAILED: no slash event in block_results h=$H_REBOND..$H_GRACE_END for $TARGET_CONS_BECH32"

  log "  scan CL logs for 'validator slashed by slash factor.*$TARGET_OP_BECH32'"
  local log_hits; log_hits=$(scan_slash_logs_bech32 "$TARGET_OP_BECH32")
  log "  scan_slash_logs_bech32 hits: $log_hits"
  [[ "$log_hits" -ge 1 ]] || fail "SECONDARY 2 FAILED: no slash CL log for $TARGET_OP_BECH32"

  pass "SECONDARY 2: slash event in block_results ($ev_hits hits) + CL log ($log_hits hits) confirm chain-side slash"
}

# ---------------- Phase 9 — capture evidence ----------------
phase_9_capture() {
  log "Phase 9 — capture evidence to $EVIDENCE_DIR"
  capture_evidence
  pass "evidence captured"
}

# ---------------- Phase 10 — summary ----------------
phase_10_summary() {
  printf "\n========== SLASHING-DT-REBOND-COUNTER-RESUME ==========\n"
  printf "  Binary: %s (V170=$UPGRADE_HEIGHT, NewMax=$NEW_MAX)\n" "$(cat ${LOCALNET}/tmp/staged_binary.sha256 2>/dev/null || echo unknown)"
  printf "  Cluster: $N_VALS-val, target $TARGET_MONIKER\n"
  printf "    op_evm:      $TARGET_OP_EVM\n"
  printf "    cons_bech32: $TARGET_CONS_BECH32\n"
  printf "  Genesis: SBW=$SIGNED_BLOCKS_WINDOW maxMissed=$((SIGNED_BLOCKS_WINDOW * 95 / 100)) unbonding_time=$UNBONDING_TIME\n"
  printf "  \n"
  printf "  Counter trajectory (signing_info.missed_blocks_counter):\n"
  printf "    h=$BASELINE_HEIGHT (baseline):        $COUNTER_BASELINE\n"
  printf "    pause-end (target $TARGET_COUNTER): $COUNTER_PAUSE_END\n"
  printf "    h=$PRE_V170_CHECK_HEIGHT (pre-V170):       $COUNTER_PRE_V170\n"
  printf "    h=$POST_V170_CHECK_HEIGHT (post-V170):      $COUNTER_POST_V170\n"
  printf "    h=$FROZEN_CHECK_HEIGHT (frozen verify):  $COUNTER_FROZEN\n"
  printf "    h_rebond+1 (=$H_REBOND_PLUS_1):     $COUNTER_REBOND_PLUS_1   ← PRIMARY assertion\n"
  printf "    h_rebond+$GRACE_MID_OFFSET (=$H_GRACE_MID): $COUNTER_GRACE_MID  ← SECONDARY 1 (grace window)\n"
  printf "    h_rebond+$GRACE_END_OFFSET (=$H_GRACE_END): $COUNTER_GRACE_END  ← SECONDARY 2 (post-grace jail)\n"
  printf "  \n"
  printf "  Tokens:\n"
  printf "    baseline:    $TOKENS_BASELINE\n"
  printf "    grace_end:   $TOKENS_GRACE_END  (5%% slashed)\n"
  printf "  \n"
  printf "  Re-bond: h_rebond=$H_REBOND, minHeight=h_rebond+SBW=$((H_REBOND + SIGNED_BLOCKS_WINDOW))\n"
  printf "  Earliest jail height (predicted): $((H_REBOND + SIGNED_BLOCKS_WINDOW + 1))\n"
  printf "  \n"
  printf "  CHAIN-ASSERTED CONCLUSIONS:\n"
  printf "  (PRIMARY) AfterValidatorBonded does NOT reset missed_blocks_counter;\n"
  printf "    val-5's counter survives BONDED→UNBONDING→BONDED transition intact.\n"
  printf "  (SECONDARY 1) StartHeight reset on re-bond gates slash check for SBW=$SIGNED_BLOCKS_WINDOW blocks;\n"
  printf "    counter can exceed maxMissed without jail firing during this window.\n"
  printf "  (SECONDARY 2) Once height > h_rebond+SBW, jail fires normally with 5%% slash.\n"
  printf "  Evidence in $EVIDENCE_DIR\n"
  printf "===========================================================\n"
}

# ---------------- Phase 11 — teardown ----------------
phase_11_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then
    log "Phase 11 — SKIP_TEARDOWN"; return
  fi
  log "Phase 11 — teardown"
  local val_idx="${TARGET_MONIKER##*-val-}"
  docker unpause "validator${val_idx}-node" 2>/dev/null || true
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline
phase_2_pause_to_target
phase_3_pre_v170
phase_4_v170_transition
phase_5_frozen_check
phase_6_stake_climb
phase_7_primary_carry_through
phase_8_grace_and_jail
phase_9_capture
phase_10_summary
phase_11_teardown
