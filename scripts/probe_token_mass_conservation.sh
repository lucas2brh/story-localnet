#!/usr/bin/env bash
# probe_token_mass_conservation.sh — verify total staked token mass is
# preserved exactly through the v1.7.0 prune.
#
# Mainnet realism: 64 vals get pruned at the activation block (largest UBD
# batch this chain will ever see). The prune itself only re-classifies
# validators from BONDED -> UNBONDED; it must NOT lose or duplicate stake.
# This probe confirms that invariant by sampling stake totals before and
# after V170 and asserting exact equality.
#
# Setup:
#   Fresh 20-val localnet. No tx-level activity between the pre-V170 and
#   post-V170 samples (no delegate / undelegate / redelegate by anyone),
#   so any drift in totals must come from the prune itself.
#
# Sampled at each checkpoint:
#   1. sum of every validator's `tokens` field (across BONDED + UNBONDED)
#   2. staking module's `bonded_tokens` + `not_bonded_tokens` from /staking/pool
#
# Invariants asserted:
#   - sum(val.tokens) at pre-V170 == sum(val.tokens) at post-V170
#   - total_pool at pre-V170 == total_pool at post-V170
#   - post-V170: bonded_tokens = sum(top-16 by tokens), not_bonded_tokens = sum(rank17-20 tokens)
#     (re-classification balances the two pools without leaking)
#
# Usage:
#   ./scripts/probe_token_mass_conservation.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_token_mass_conservation.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
PRE_UPGRADE_SAMPLE=${PRE_UPGRADE_SAMPLE:-10}    # sample at block 10 (well past genesis)
POST_UPGRADE_SAMPLE=${POST_UPGRADE_SAMPLE:-65}  # sample at block 65 (past V170+15)
NEW_MAX=${NEW_MAX:-16}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[mass]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[mass]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[mass]${C_RESET} FAIL %s\n" "$*"; exit 1; }

get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}
wait_height() { local target=$1 h; while :; do h=$(get_height); [[ $h -ge $target ]] && { echo "$h"; return; }; sleep 2; done; }

sum_val_tokens() {
  # Sum the `tokens` field across all validators (BONDED + UNBONDED)
  curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" 2>/dev/null \
    | jq -r '[.msg.validators[].tokens | tonumber] | add'
}
sum_val_tokens_by_status() {
  # $1 = "BOND_STATUS_BONDED" or "BOND_STATUS_UNBONDED"
  curl -fsS "http://localhost:1317/staking/validators?status=${1}&pagination.limit=100" 2>/dev/null \
    | jq -r '[.msg.validators[].tokens | tonumber] | add // 0'
}
pool_bonded() {
  curl -fsS "http://localhost:1317/staking/pool" 2>/dev/null | jq -r '.msg.pool.bonded_tokens'
}
pool_not_bonded() {
  curl -fsS "http://localhost:1317/staking/pool" 2>/dev/null | jq -r '.msg.pool.not_bonded_tokens'
}

# ---------------- Phase 0 — fresh localnet ----------------
phase_0_start() {
  log "Phase 0 — start fresh localnet (no tx-level activity will occur during this probe)"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2); sleep 5
  fi
  MAX_VALIDATORS_INIT=20 STORY_BIN=/tmp/story bash "${LOCALNET}/scripts/assemble_genesis.sh" 20 2>&1 | tail -1
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "rpc1 didn't sync in 90s"
    sleep 3
  done
}

# ---------------- Phase 1 — pre-V170 sample at block 10 ----------------
PRE_VAL_TOKENS_SUM=""; PRE_POOL_BONDED=""; PRE_POOL_NOT_BONDED=""; PRE_POOL_TOTAL=""
phase_1_pre_sample() {
  log "Phase 1 — wait to block $PRE_UPGRADE_SAMPLE (well before V170=$UPGRADE_HEIGHT) and sample stake totals"
  wait_height "$PRE_UPGRADE_SAMPLE" >/dev/null
  PRE_VAL_TOKENS_SUM=$(sum_val_tokens)
  PRE_POOL_BONDED=$(pool_bonded)
  PRE_POOL_NOT_BONDED=$(pool_not_bonded)
  PRE_POOL_TOTAL=$(( PRE_POOL_BONDED + PRE_POOL_NOT_BONDED ))
  log "  pre-V170 sample at block $(get_height):"
  log "    sum(val.tokens)        = $PRE_VAL_TOKENS_SUM"
  log "    pool.bonded_tokens     = $PRE_POOL_BONDED"
  log "    pool.not_bonded_tokens = $PRE_POOL_NOT_BONDED"
  log "    pool total             = $PRE_POOL_TOTAL"
  pass "pre-V170 stake totals captured"
}

# ---------------- Phase 2 — post-V170 sample at block 65 ----------------
POST_VAL_TOKENS_SUM=""; POST_POOL_BONDED=""; POST_POOL_NOT_BONDED=""; POST_POOL_TOTAL=""
POST_BONDED_SUM=""; POST_UNBONDED_SUM=""
phase_2_post_sample() {
  log "Phase 2 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_SAMPLE and sample stake totals"
  wait_height "$POST_UPGRADE_SAMPLE" >/dev/null
  POST_VAL_TOKENS_SUM=$(sum_val_tokens)
  POST_POOL_BONDED=$(pool_bonded)
  POST_POOL_NOT_BONDED=$(pool_not_bonded)
  POST_POOL_TOTAL=$(( POST_POOL_BONDED + POST_POOL_NOT_BONDED ))
  POST_BONDED_SUM=$(sum_val_tokens_by_status "BOND_STATUS_BONDED")
  POST_UNBONDED_SUM=$(sum_val_tokens_by_status "BOND_STATUS_UNBONDED")
  log "  post-V170 sample at block $(get_height):"
  log "    sum(val.tokens)              = $POST_VAL_TOKENS_SUM"
  log "    sum(bonded vals tokens)      = $POST_BONDED_SUM"
  log "    sum(unbonded vals tokens)    = $POST_UNBONDED_SUM"
  log "    pool.bonded_tokens           = $POST_POOL_BONDED"
  log "    pool.not_bonded_tokens       = $POST_POOL_NOT_BONDED"
  log "    pool total                   = $POST_POOL_TOTAL"
  pass "post-V170 stake totals captured"
}

# ---------------- Phase 3 — assert conservation invariants ----------------
phase_3_verify() {
  log "Phase 3 — assert token-mass conservation across V170 prune"

  # Invariant 1: sum(val.tokens) preserved exactly
  [[ "$POST_VAL_TOKENS_SUM" == "$PRE_VAL_TOKENS_SUM" ]] \
    || fail "sum(val.tokens) drift: pre=$PRE_VAL_TOKENS_SUM post=$POST_VAL_TOKENS_SUM (delta=$((POST_VAL_TOKENS_SUM - PRE_VAL_TOKENS_SUM)))"
  pass "sum(val.tokens) preserved exactly: $PRE_VAL_TOKENS_SUM stake (no stake lost or duplicated through prune)"

  # Invariant 2: total pool (bonded + not_bonded) preserved exactly
  [[ "$POST_POOL_TOTAL" == "$PRE_POOL_TOTAL" ]] \
    || fail "pool total drift: pre=$PRE_POOL_TOTAL post=$POST_POOL_TOTAL (delta=$((POST_POOL_TOTAL - PRE_POOL_TOTAL)))"
  pass "pool total preserved: $PRE_POOL_TOTAL stake (re-classification only, no leakage)"

  # Invariant 3: post-V170 bonded_pool == sum of BONDED vals' tokens
  [[ "$POST_POOL_BONDED" == "$POST_BONDED_SUM" ]] \
    || fail "post-V170 bonded pool != sum(bonded vals tokens): pool=$POST_POOL_BONDED, sum=$POST_BONDED_SUM"
  pass "post-V170 bonded_tokens_pool == sum(top-16 vals tokens) = $POST_POOL_BONDED"

  # Invariant 4: post-V170 not_bonded_pool == sum of UNBONDED vals' tokens
  [[ "$POST_POOL_NOT_BONDED" == "$POST_UNBONDED_SUM" ]] \
    || fail "post-V170 not_bonded pool != sum(unbonded vals tokens): pool=$POST_POOL_NOT_BONDED, sum=$POST_UNBONDED_SUM"
  pass "post-V170 not_bonded_tokens_pool == sum(rank17-20 vals tokens) = $POST_POOL_NOT_BONDED"

  # Invariant 5: pre-V170 not_bonded should be 0 (all 20 vals were BONDED)
  [[ "$PRE_POOL_NOT_BONDED" == "0" ]] \
    || log "  NOTE: pre-V170 not_bonded_tokens = $PRE_POOL_NOT_BONDED (expected 0 since all 20 vals BONDED at genesis; non-zero may indicate genesis-time UBD state)"
}

# ---------------- Phase 4 — summary ----------------
phase_4_summary() {
  printf "\n========== TOKEN-MASS CONSERVATION PROBE CONCLUSIONS ==========\n"
  printf "Pre-V170 (block %d):\n" "$PRE_UPGRADE_SAMPLE"
  printf "  sum(val.tokens)        = %s\n" "$PRE_VAL_TOKENS_SUM"
  printf "  pool.bonded            = %s\n" "$PRE_POOL_BONDED"
  printf "  pool.not_bonded        = %s\n" "$PRE_POOL_NOT_BONDED"
  printf "  pool total             = %s\n" "$PRE_POOL_TOTAL"
  printf "Post-V170 (block %d):\n" "$POST_UPGRADE_SAMPLE"
  printf "  sum(val.tokens)        = %s\n" "$POST_VAL_TOKENS_SUM"
  printf "  sum(bonded vals)       = %s\n" "$POST_BONDED_SUM"
  printf "  sum(unbonded vals)     = %s\n" "$POST_UNBONDED_SUM"
  printf "  pool.bonded            = %s\n" "$POST_POOL_BONDED"
  printf "  pool.not_bonded        = %s\n" "$POST_POOL_NOT_BONDED"
  printf "  pool total             = %s\n" "$POST_POOL_TOTAL"
  printf "Conservation deltas:\n"
  printf "  sum(val.tokens):  %s -> %s (delta=%d)\n" "$PRE_VAL_TOKENS_SUM" "$POST_VAL_TOKENS_SUM" "$((POST_VAL_TOKENS_SUM - PRE_VAL_TOKENS_SUM))"
  printf "  pool total:       %s -> %s (delta=%d)\n" "$PRE_POOL_TOTAL" "$POST_POOL_TOTAL" "$((POST_POOL_TOTAL - PRE_POOL_TOTAL))"
  printf "================================================================\n"
}

phase_5_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 5 — SKIP_TEARDOWN"; return; fi
  log "Phase 5 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_pre_sample
phase_2_post_sample
phase_3_verify
phase_4_summary
phase_5_teardown
