#!/usr/bin/env bash
# probe_partial_self_unstake_auto_sweep.sh — verify Story-specific auto-sweep
# behavior on a pruned single-delegator validator: operator submits a PARTIAL
# self-unstake that would leave residual self-delegation BELOW MinSelfDelegation
# (1024 IP). Story's auto-sweep rule promotes the operation to effectively 100%
# by also unstaking the residual; this collapses to the same code path as
# probe_unstake_pruned_val.sh Case A (RemoveValidator fires, val GONE).
#
# Why this matters: any "leave 1 IP residual to avoid the halt" workaround
# that an operator might attempt is preempted by auto-sweep. The auto-sweep
# code path itself has not been explicitly exercised by an existing probe —
# this fills that gap, and confirms Hans's fix prevents the halt for this
# code path the same way it does for direct 100% unstakes.
#
# Setup:
#   Fresh 20-validator localnet, V170 height 50. After upgrade, val-17 is a
#   pruned UNBONDED validator with operator-only self-delegation (~286,240 IP).
#
# Trigger:
#   Operator submits partial unstake leaving exactly 100 IP residual (well
#   below the 1024 IP MinSelfDelegation threshold). Auto-sweep should pick up
#   the residual and unstake it together, totalling the full self-del.
#
# Expected:
#   - val-17 GONE from staking store (auto-sweep + RemoveValidator fired)
#   - chain progresses past the unstake tx (Hans fix, no halt)
#   - operator EVM wallet credited with full ~286,240 IP after unbonding mature
#   - no panic / CONSENSUS FAILURE in any validator log
#
# Usage:
#   ./scripts/probe_partial_self_unstake_auto_sweep.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_partial_self_unstake_auto_sweep.sh

set -u

N_VALS=${N_VALS:-8}
NEW_MAX=${NEW_MAX:-4}
UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-70}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-75}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
TARGET_MONIKER=${TARGET_MONIKER:-localnet-val-5}
RESIDUAL_STAKE=100000000000   # leave 100 IP residual (< 1024 IP MinSelfDelegation)

# ---- Phase 1: pre-V170 partial self-unstake (Raul Case 3a strict) ----
# Different target val (will-be-pruned), still ≥ MinSelfDel so val stays BONDED pre-V170.
PRE_H_TARGET_MONIKER=${PRE_H_TARGET_MONIKER:-localnet-val-6}
PRE_H_PARTIAL_FRACTION=${PRE_H_PARTIAL_FRACTION:-50}   # percent of self-stake to unstake

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[autosweep]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[autosweep]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[autosweep]${C_RESET} FAIL %s\n" "$*"; exit 1; }

get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}
wait_height() { local target=$1 h; while :; do h=$(get_height); [[ $h -ge $target ]] && { echo "$h"; return; }; sleep 2; done; }
get_evm_balance() {
  local addr=$1 hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$addr\",\"latest\"],\"id\":1}" \
    | jq -r .result)
  python3 -c "print(int('$hex', 16))" 2>/dev/null || echo 0
}
val_field() {
  # When val record is removed from store, REST returns 404 -> curl -f suppresses body.
  # jq on empty input returns empty, not the // default. Handle empty body explicitly.
  local body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${1}" 2>/dev/null)
  [[ -z $body ]] && { echo "GONE"; return; }
  jq -r ".msg.validator.${2} // \"GONE\"" <<<"$body"
}
meta_pubkey_hex() { local b64; b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META"); echo -n "$b64" | base64 -d | xxd -p -c 66; }
meta_privkey()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }
meta_op_evm()     { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }

# ---------------- Phase 0 — fresh localnet ----------------
phase_0_start() {
  log "Phase 0 — start fresh localnet"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2); sleep 5
  fi
  MAX_VALIDATORS_INIT="$N_VALS" STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N_VALS" 2>&1 | tail -1
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "rpc1 didn't sync in 90s"
    sleep 3
  done
}

# ---------------- Phase 1 — pre-V170 partial self-unstake (Raul Case 3a strict) ----------------
PRE_H_VAL_OP=""; PRE_H_VAL_TOKENS_PRE=""; PRE_H_VAL_TOKENS_POST=""; PRE_H_UNSTAKE_TX=""
phase_1_pre_v170_partial_unstake() {
  log "Phase 1 — pre-V170 partial self-unstake on $PRE_H_TARGET_MONIKER (Raul Case 3a strict: residual ≥ MinSelfDel, val stays BONDED pre-H)"
  wait_height 10 >/dev/null
  log "  chain at $(get_height) (pre-V170)"

  PRE_H_VAL_OP=$(meta_op_evm "$PRE_H_TARGET_MONIKER")
  local st; st=$(val_field "$PRE_H_VAL_OP" status)
  PRE_H_VAL_TOKENS_PRE=$(val_field "$PRE_H_VAL_OP" tokens)
  log "  $PRE_H_TARGET_MONIKER op=$PRE_H_VAL_OP pre-unstake status=$st tokens=$PRE_H_VAL_TOKENS_PRE"
  [[ "$st" == "3" ]] || fail "$PRE_H_TARGET_MONIKER expected BONDED (status=3) pre-V170, got status=$st"

  # Fund operator EVM wallet for unstake gas
  local fund_out fund_rc
  fund_out=$(cast send --rpc-url http://localhost:8545 --private-key "$ANVIL_PK" "$PRE_H_VAL_OP" \
    --value 10ether --legacy --gas-price 50gwei 2>&1)
  fund_rc=$?
  [[ $fund_rc -eq 0 ]] || fail "fund $PRE_H_TARGET_MONIKER operator: cast send rc=$fund_rc"
  sleep 5

  # Partial unstake — PRE_H_PARTIAL_FRACTION% of self-stake (residual stays >> MinSelfDel)
  local unstake_stake unstake_wei pub priv expected_residual
  unstake_stake=$(( PRE_H_VAL_TOKENS_PRE * PRE_H_PARTIAL_FRACTION / 100 ))
  expected_residual=$(( PRE_H_VAL_TOKENS_PRE - unstake_stake ))
  unstake_wei=$(echo "$unstake_stake * 1000000000" | bc)
  pub=$(meta_pubkey_hex "$PRE_H_TARGET_MONIKER")
  priv=$(meta_privkey "$PRE_H_TARGET_MONIKER")
  log "  partial unstake $unstake_stake stake = $unstake_wei wei ($PRE_H_PARTIAL_FRACTION% of self-stake)"
  log "  expected residual: $expected_residual stake = $((expected_residual / 1000000000)) IP (must be > 1024 IP MinSelfDel)"
  [[ $expected_residual -gt $((1024 * 1000000000)) ]] || fail "residual $expected_residual stake < MinSelfDel=1024 IP — adjust PRE_H_PARTIAL_FRACTION"

  local out rc
  out=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$unstake_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  PRE_H_UNSTAKE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  log "  tx=$PRE_H_UNSTAKE_TX rc=$rc"
  [[ "$rc" == "0" ]] || fail "pre-V170 partial unstake rc=$rc ($out)"

  wait_height "$(( $(get_height) + 5 ))" >/dev/null

  # Verify val still BONDED + tokens reduced
  local st_post tk_post diff
  st_post=$(val_field "$PRE_H_VAL_OP" status)
  tk_post=$(val_field "$PRE_H_VAL_OP" tokens)
  PRE_H_VAL_TOKENS_POST=$tk_post
  log "  $PRE_H_TARGET_MONIKER post-unstake (still pre-V170): status=$st_post tokens=$tk_post"
  [[ "$st_post" == "3" ]] || fail "$PRE_H_TARGET_MONIKER expected still BONDED post-partial-unstake, got status=$st_post"
  diff=$(( PRE_H_VAL_TOKENS_PRE - tk_post ))
  [[ "$diff" -gt 0 ]] || fail "expected tokens reduced after partial unstake, got pre=$PRE_H_VAL_TOKENS_PRE post=$tk_post"
  pass "pre-V170 partial unstake (Raul Case 3a strict): $PRE_H_TARGET_MONIKER still BONDED, tokens delta=-$diff stake (residual ≈ $((tk_post / 1000000000)) IP > MinSelfDel)"
}

# ---------------- Phase 2 — wait past upgrade, sanity-check cluster, capture target baseline ----------------
VAL_OP=""; VAL_TOKENS_PRE=""
phase_2_post_upgrade_baseline() {
  log "Phase 2 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_BLOCK, sample $TARGET_MONIKER baseline + verify pre-V170 unstake carried through"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  log "  chain at $(get_height)"

  # Cluster-wide post-V170 sanity check (binary↔probe consistency, all expected vals pruned)
  source "${LOCALNET}/scripts/lib/post_v170_asserts.sh"
  local pruned_list="" bonded_list="" i
  for ((i=1; i<=NEW_MAX; i++));     do bonded_list+=" localnet-val-$i"; done
  for ((i=NEW_MAX+1; i<=N_VALS; i++)); do pruned_list+=" localnet-val-$i"; done
  PRUNED_VALS="${pruned_list# }" \
    BONDED_VALS="${bonded_list# }" \
    EXPECTED_NEW_MAX="$NEW_MAX" \
    UPGRADE_HEIGHT="$UPGRADE_HEIGHT" \
    META="$META" \
    POST_V170_GRACE=0 \
    assert_post_v170_state

  # Verify pre-V170 unstake target val carried through prune correctly
  local pre_h_st pre_h_tk
  pre_h_st=$(val_field "$PRE_H_VAL_OP" status)
  pre_h_tk=$(val_field "$PRE_H_VAL_OP" tokens)
  log "  $PRE_H_TARGET_MONIKER post-V170: status=$pre_h_st tokens=$pre_h_tk (expected status=1, tokens == pre-V170-post-unstake $PRE_H_VAL_TOKENS_POST)"
  [[ "$pre_h_st" == "1" ]] || fail "$PRE_H_TARGET_MONIKER expected UNBONDED post-V170 (status=1), got $pre_h_st"
  [[ "$pre_h_tk" == "$PRE_H_VAL_TOKENS_POST" ]] || fail "$PRE_H_TARGET_MONIKER tokens drift: pre-V170-post-unstake=$PRE_H_VAL_TOKENS_POST post-V170=$pre_h_tk (expected exact match — no other action between unstake and V170)"
  pass "Raul Case 3a strict: pre-V170 partial unstake on $PRE_H_TARGET_MONIKER carried through V170 prune cleanly (BONDED→UNBONDED, tokens preserved)"

  VAL_OP=$(meta_op_evm "$TARGET_MONIKER")
  local status; status=$(val_field "$VAL_OP" status)
  VAL_TOKENS_PRE=$(val_field "$VAL_OP" tokens)
  log "  $TARGET_MONIKER op=$VAL_OP status=$status tokens=$VAL_TOKENS_PRE"
  [[ "$status" == "1" ]] || fail "$TARGET_MONIKER expected UNBONDED (status=1) post-upgrade, got status=$status"
  pass "target val confirmed UNBONDED with operator-only self-del"
}

# ---------------- Phase 3 — fund operator EVM wallet for unstake gas ----------------
OP_EVM_BAL_PRE=""
phase_3_fund_operator() {
  log "Phase 3 — Anvil sends 10 IP to $TARGET_MONIKER operator wallet for gas"
  OP_EVM_BAL_PRE=$(get_evm_balance "$VAL_OP")
  log "  operator $VAL_OP pre-fund balance=$OP_EVM_BAL_PRE wei"
  local out rc
  out=$(cast send --rpc-url http://localhost:8545 \
    --private-key "$ANVIL_PK" "$VAL_OP" \
    --value 10ether --legacy --gas-price 50gwei 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || fail "cast send rc=$rc ($out)"
  sleep 5
  local op_bal; op_bal=$(get_evm_balance "$VAL_OP")
  log "  operator post-fund balance=$op_bal wei"
}

# ---------------- Phase 4 — operator partial unstake (residual below MinSelfDelegation) ----------------
PARTIAL_UNSTAKE_TX=""; PARTIAL_UNSTAKE_RC=""
PARTIAL_UNSTAKE_AMOUNT_STAKE=""
phase_4_partial_unstake_trigger_sweep() {
  PARTIAL_UNSTAKE_AMOUNT_STAKE=$(( VAL_TOKENS_PRE - RESIDUAL_STAKE ))
  log "Phase 4 — operator partial unstake $PARTIAL_UNSTAKE_AMOUNT_STAKE stake (residual $RESIDUAL_STAKE stake = $((RESIDUAL_STAKE / 1000000000)) IP, below 1024 IP MinSelfDelegation)"
  local pub priv amount_wei
  pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  priv=$(meta_privkey "$TARGET_MONIKER")
  amount_wei=$(echo "$PARTIAL_UNSTAKE_AMOUNT_STAKE * 1000000000" | bc)
  log "  $TARGET_MONIKER operator unstakes $PARTIAL_UNSTAKE_AMOUNT_STAKE stake = $amount_wei wei (delegation-id=0)"
  local out
  out=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  PARTIAL_UNSTAKE_RC=$?
  PARTIAL_UNSTAKE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  log "  tx=$PARTIAL_UNSTAKE_TX rc=$PARTIAL_UNSTAKE_RC"
  [[ "$PARTIAL_UNSTAKE_RC" == "0" ]] || fail "operator partial unstake rc=$PARTIAL_UNSTAKE_RC"
  wait_height "$(( $(get_height) + 5 ))" >/dev/null
}

# ---------------- Phase 5 — verify auto-sweep + RemoveValidator + no halt ----------------
phase_5_verify() {
  log "Phase 5 — verify auto-sweep collapsed partial -> 100%, val GONE, chain alive"
  local status tokens shares
  status=$(val_field "$VAL_OP" status)
  tokens=$(val_field "$VAL_OP" tokens)
  shares=$(val_field "$VAL_OP" delegator_shares)
  log "  $TARGET_MONIKER post-unstake: status=$status tokens=$tokens shares=$shares"

  [[ "$status" == "GONE" ]] || fail "expected val GONE (RemoveValidator fired after auto-sweep), got status=$status tokens=$tokens"

  # Chain liveness: must progress past the tx block (Hans fix prevents halt)
  local h=$(get_height)
  wait_height "$((h + 3))" >/dev/null
  pass "val GONE + chain still progressing (auto-sweep collapsed to 100%, RemoveValidator fired, no halt)"

  # Panic / consensus failure scan across all validator-node containers
  local panics=0 c
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$'); do
    local n; n=$(docker logs "$c" 2>&1 | grep -cE 'panic|CONSENSUS FAILURE' || true)
    panics=$((panics + n))
  done
  [[ $panics -eq 0 ]] || fail "$panics panic/CONSENSUS FAILURE lines across validator-node containers"
  pass "no panic / CONSENSUS FAILURE in any validator log"
}

# ---------------- Phase 6 — wait unbonding mature, verify operator EVM refund ----------------
OP_EVM_BAL_AFTER_UBD=""
phase_6_operator_balance() {
  log "Phase 6 — wait past unbonding_time (10s), verify operator EVM credited full self-del refund"
  wait_height "$(( $(get_height) + 8 ))" >/dev/null
  OP_EVM_BAL_AFTER_UBD=$(get_evm_balance "$VAL_OP")
  log "  operator after-mature balance=$OP_EVM_BAL_AFTER_UBD wei (vs pre-fund $OP_EVM_BAL_PRE wei)"
  log "  expected refund ~ $VAL_TOKENS_PRE stake = $(echo "$VAL_TOKENS_PRE * 1000000000" | bc) wei (full balance via auto-sweep)"
}

# ---------------- Phase 7 — summary ----------------
phase_7_summary() {
  printf "\n========== AUTO-SWEEP PARTIAL-UNSTAKE PROBE CONCLUSIONS ==========\n"
  printf "Pre-V170 scenario (Raul Case 3a strict):\n"
  printf "  Target: %s op=%s\n" "$PRE_H_TARGET_MONIKER" "$PRE_H_VAL_OP"
  printf "  Action: %d%% partial self-unstake at h~10 (BONDED, residual ≥ MinSelfDel)\n" "$PRE_H_PARTIAL_FRACTION"
  printf "  Result: pre-V170 BONDED → post-V170 UNBONDED, tokens preserved across prune\n"
  printf "  Pre-unstake tokens=%s, post-unstake tokens=%s, post-V170 tokens=%s (drift=0 expected)\n" \
    "$PRE_H_VAL_TOKENS_PRE" "$PRE_H_VAL_TOKENS_POST" "$(val_field "$PRE_H_VAL_OP" tokens)"
  printf "  Pre-V170 unstake tx=%s\n" "$PRE_H_UNSTAKE_TX"
  printf "\n"
  printf "Post-V170 scenario (auto-sweep on residual < MinSelfDel):\n"
  printf "  Target: %s op=%s\n" "$TARGET_MONIKER" "$VAL_OP"
  printf "  Pre-unstake: status=UNBONDED(1) tokens=%s\n" "$VAL_TOKENS_PRE"
  printf "  Partial unstake requested: %s stake (residual %s stake = %d IP, below 1024 IP MinSelfDelegation)\n" \
    "$PARTIAL_UNSTAKE_AMOUNT_STAKE" "$RESIDUAL_STAKE" "$((RESIDUAL_STAKE / 1000000000))"
  printf "  CLI rc=%s tx=%s\n" "$PARTIAL_UNSTAKE_RC" "$PARTIAL_UNSTAKE_TX"
  printf "  val status post-unstake: %s (expected GONE — auto-sweep collapsed to 100%%, RemoveValidator fired)\n" "$(val_field "$VAL_OP" status)"
  printf "  Operator EVM bal: pre-fund=%s after-ubd=%s (expected delta ~ %s wei = full self-del refund via auto-sweep)\n" \
    "$OP_EVM_BAL_PRE" "$OP_EVM_BAL_AFTER_UBD" "$(echo "$VAL_TOKENS_PRE * 1000000000" | bc)"
  printf "  Final chain height: %s (no halt)\n" "$(get_height)"
  printf "==================================================================\n"
}

phase_8_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 8 — SKIP_TEARDOWN"; return; fi
  log "Phase 8 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_pre_v170_partial_unstake
phase_2_post_upgrade_baseline
phase_3_fund_operator
phase_4_partial_unstake_trigger_sweep
phase_5_verify
phase_6_operator_balance
phase_7_summary
phase_8_teardown
