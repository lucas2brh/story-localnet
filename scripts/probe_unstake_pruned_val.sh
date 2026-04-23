#!/usr/bin/env bash
# probe_unstake_pruned_val.sh — empirical verification that unstake path
# does NOT have the L3-style silent rollback, and that jail triggers on
# UNBONDED val during self-del drop below MinSelfDelegation.
#
# Two parallel cases on one fresh localnet:
#   Case A: val-17 (self-del only, 100% unstake)
#     - delegation.Shares = 0, DelegatorShares = 0, IsUnbonded = true
#     - RemoveValidator fires inside Unbond
#     - Undelegate has no post-Unbond lookup → completes, UBD created
#     - Observe: CLI rc=0, no Failed log, UBD entry present, val-17 removed,
#       EVM balance increased after unbonding mature
#
#   Case B: val-18 (external del injected via Anvil, 100% self-unstake)
#     - delegation.Shares = 0 (operator's self-del), DelegatorShares > 0
#       (Anvil's del remains) → RemoveValidator NOT called
#     - Jail check: self-del remaining 0 < MinSelfDelegation (1024 IP) → jailed=true
#     - Observe: CLI rc=0, no Failed log, UBD for operator created,
#       val-18.jailed=true, val-18 still in store, EVM balance up after mature
#
# Setup:
#   Fresh localnet on lucas/v170-maxval-test (N=20, default MAX_VALIDATORS_INIT=20,
#   upgrade at block 50 prunes rank 17-20 to UNBONDED).

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[unstake]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[unstake]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[unstake]${C_RESET} FAIL %s\n" "$*"; }
note() { printf "${C_YELLOW}[unstake]${C_RESET} NOTE %s\n" "$*"; }

# ---------------- helpers ----------------
get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}

wait_height() {
  local target=$1 h
  while :; do
    h=$(get_height)
    [[ $h -ge $target ]] && { echo "$h"; return; }
    sleep 2
  done
}

get_evm_balance() {
  local addr=$1 hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$addr\",\"latest\"],\"id\":1}" \
    | jq -r .result)
  python3 -c "print(int('$hex', 16))" 2>/dev/null || echo 0
}

val_status_in_store() {
  # Returns: 3=bonded, 2=unbonding, 1=unbonded, "GONE"=removed
  local op=$1 body status
  body=$(curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null)
  status=$(jq -r '.msg.validator.status // "GONE"' <<<"$body")
  echo "$status"
}

val_jailed() {
  local op=$1 body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null)
  jq -r '.msg.validator.jailed // "null"' <<<"$body"
}

val_tokens() {
  local op=$1 body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null)
  jq -r '.msg.validator.tokens // "GONE"' <<<"$body"
}

val_delegator_shares() {
  local op=$1 body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null)
  jq -r '.msg.validator.delegator_shares // "GONE"' <<<"$body"
}

ubd_count_for() {
  # Unbonding delegations for a delegator address (cosmos bech32)
  local del_bech=$1
  curl -fsS "http://localhost:1317/staking/delegators/${del_bech}/unbonding_delegations?pagination.limit=100" 2>/dev/null \
    | jq '.msg.unbonding_responses | length // 0'
}

meta_pubkey_hex() {
  local b64; b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META")
  echo -n "$b64" | base64 -d | xxd -p -c 66
}
meta_privkey() { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }
meta_evm_addr() { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }
meta_delegator_bech() { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .delegator_address' "$META"; }

fund_operator() {
  # Fund a val operator EVM wallet 10 IP from Anvil #0 (legacy tx).
  local moniker=$1
  local op_addr
  op_addr=$(meta_evm_addr "$moniker")
  log "  Funding $moniker operator $op_addr with 10 IP"
  local out rc
  out=$(cast send --rpc-url http://localhost:8545 \
    --private-key "$ANVIL_PK" "$op_addr" \
    --value 10ether --legacy --gas-price 50gwei 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || { fail "cast send rc=$rc ($out)"; return 1; }
  sleep 6
  local bal
  bal=$(get_evm_balance "$op_addr")
  log "    post-fund balance=$bal wei"
  if ! awk -v b="$bal" 'BEGIN{exit !(b+0 >= 5000000000000000000)}'; then
    fail "balance $bal too low"
    return 1
  fi
  return 0
}

anvil_stake_to_val() {
  # Anvil #0 stakes N IP to a val (for Case B external del injection).
  local moniker=$1 amount_wei=$2 pub
  pub=$(meta_pubkey_hex "$moniker")
  log "  Anvil stakes $amount_wei wei to $moniker"
  local out rc
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
    --validator-pubkey "$pub" --stake "$amount_wei" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -5
  [[ $rc -eq 0 ]] || { fail "anvil stake rc=$rc"; return 1; }
  sleep 15
  return 0
}

submit_unstake() {
  # Operator 100% unstake of their self-del.
  local moniker=$1 amount_stake=$2
  local pub priv amount_wei
  pub=$(meta_pubkey_hex "$moniker")
  priv=$(meta_privkey "$moniker")
  amount_wei=$(echo "$amount_stake * 1000000000" | bc)
  log "  $moniker operator unstakes $amount_stake stake = $amount_wei wei"
  local out rc tx
  out=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -5
  tx=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  echo "RC=$rc TX=$tx"
}

# ---------------- Phase 0 — start fresh localnet ----------------
phase_0_start() {
  log "Phase 0 — start fresh localnet"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    log "  existing containers found, tearing down first"
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -3)
    sleep 5
  fi
  # Ensure genesis has default max_validators=20 (any prior probe may have left it at 4)
  log "  re-assemble genesis with MAX_VALIDATORS_INIT=20"
  MAX_VALIDATORS_INIT=20 STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" 20 2>&1 | tail -1
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)
  # rpc1 JWT race workaround
  local deadline h
  deadline=$(( $(date +%s) + 90 ))
  while :; do
    h=$(get_height)
    [[ $h -gt 0 ]] && { log "  rpc1 sync good, height=$h"; return; }
    if [[ $(date +%s) -ge $deadline ]]; then
      log "  rpc1 stuck, restarting rpc1-node to reload JWT"
      docker restart rpc1-node >/dev/null 2>&1
      sleep 15
      h=$(get_height)
      [[ $h -gt 0 ]] && { log "  rpc1 recovered, height=$h"; return; }
      fail "rpc1 did not recover"; exit 1
    fi
    sleep 3
  done
}

# ---------------- Phase 1 — wait post-upgrade, sample baseline ----------------
VAL_A_OP=""; VAL_A_TOKENS=""; VAL_A_DEL_BECH=""
VAL_B_OP=""; VAL_B_TOKENS=""; VAL_B_DEL_BECH=""
phase_1_baseline() {
  log "Phase 1 — wait past upgrade + unbonding settled (block 65)"
  wait_height 65 >/dev/null
  log "  chain at $(get_height)"

  VAL_A_OP=$(jq -r '.msg.validators[] | select(.description.moniker=="localnet-val-17") | .operator_address' <<<"$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100")")
  VAL_A_TOKENS=$(val_tokens "$VAL_A_OP")
  VAL_A_DEL_BECH=$(meta_delegator_bech "localnet-val-17")
  log "  CASE A: val-17 op=$VAL_A_OP tokens=$VAL_A_TOKENS status=$(val_status_in_store $VAL_A_OP) jailed=$(val_jailed $VAL_A_OP) delegator=$VAL_A_DEL_BECH"

  VAL_B_OP=$(jq -r '.msg.validators[] | select(.description.moniker=="localnet-val-18") | .operator_address' <<<"$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100")")
  VAL_B_TOKENS=$(val_tokens "$VAL_B_OP")
  VAL_B_DEL_BECH=$(meta_delegator_bech "localnet-val-18")
  log "  CASE B: val-18 op=$VAL_B_OP tokens=$VAL_B_TOKENS status=$(val_status_in_store $VAL_B_OP) jailed=$(val_jailed $VAL_B_OP) delegator=$VAL_B_DEL_BECH"

  [[ "$(val_status_in_store "$VAL_A_OP")" == "1" ]] || { fail "val-17 baseline status != 1"; exit 1; }
  [[ "$(val_status_in_store "$VAL_B_OP")" == "1" ]] || { fail "val-18 baseline status != 1"; exit 1; }
  pass "both target vals confirmed UNBONDED"
}

# ---------------- Phase 2 — setup external del for Case B ----------------
phase_2_ext_del_B() {
  log "Phase 2 — Case B setup: Anvil stakes 2048 IP to val-18"
  anvil_stake_to_val "localnet-val-18" "2048000000000000000000" || exit 1
  local b_tokens_post b_shares_post
  b_tokens_post=$(val_tokens "$VAL_B_OP")
  b_shares_post=$(val_delegator_shares "$VAL_B_OP")
  log "  val-18 post-stake: tokens=$b_tokens_post delegator_shares=$b_shares_post"
  pass "Case B external del injected"
}

# ---------------- Phase 3 — fund operator EVM for both ----------------
phase_3_fund_ops() {
  log "Phase 3 — fund operator EVM wallets for Case A and Case B"
  fund_operator "localnet-val-17" || exit 1
  fund_operator "localnet-val-18" || exit 1
  pass "both operator wallets funded"
}

# ---------------- Phase 4 — submit unstakes ----------------
A_TX=""; B_TX=""; A_RC=""; B_RC=""
phase_4_submit_unstakes() {
  log "Phase 4 — Case A: val-17 operator 100% unstake"
  # VAL_A_TOKENS is current tokens (self-del only, still = genesis value since val-17 pruned but delegation intact)
  local a_result
  a_result=$(submit_unstake "localnet-val-17" "$VAL_A_TOKENS" | tail -1)
  A_RC=$(grep -oE 'RC=[0-9]+' <<<"$a_result" | cut -d= -f2)
  A_TX=$(grep -oE 'TX=0x[0-9a-f]+' <<<"$a_result" | cut -d= -f2)
  log "  A: rc=$A_RC tx=$A_TX"

  log "Phase 4 — Case B: val-18 operator 100% self-unstake (keeps external del)"
  # For val-18, original self-del baseline (before Anvil stake). VAL_B_TOKENS was captured pre-Anvil.
  local b_result
  b_result=$(submit_unstake "localnet-val-18" "$VAL_B_TOKENS" | tail -1)
  B_RC=$(grep -oE 'RC=[0-9]+' <<<"$b_result" | cut -d= -f2)
  B_TX=$(grep -oE 'TX=0x[0-9a-f]+' <<<"$b_result" | cut -d= -f2)
  log "  B: rc=$B_RC tx=$B_TX"

  wait_height "$(( $(get_height) + 10 ))" >/dev/null
}

# ---------------- Phase 5 — verify immediate post-tx state ----------------
A_VAL_STATUS_POST=""; A_UBD_COUNT_POST=""
B_VAL_STATUS_POST=""; B_JAILED_POST=""; B_UBD_COUNT_POST=""; B_TOKENS_POST=""
phase_5_verify_post() {
  log "Phase 5 — verify post-unstake state"

  local fail_count
  fail_count=$(docker logs rpc1-node 2>&1 | grep -c "Failed to process withdraw" || true)
  log "  rpc1-node Failed-to-process-withdraw log count: $fail_count"
  [[ "$fail_count" == "0" ]] || note "non-zero Failed count ($fail_count) — at least one unstake silently rolled back"

  # Case A state
  A_VAL_STATUS_POST=$(val_status_in_store "$VAL_A_OP")
  A_UBD_COUNT_POST=$(ubd_count_for "$VAL_A_DEL_BECH")
  log "  CASE A val-17: in_store=$A_VAL_STATUS_POST UBD_count_for_operator=$A_UBD_COUNT_POST"

  # Case B state
  B_VAL_STATUS_POST=$(val_status_in_store "$VAL_B_OP")
  B_JAILED_POST=$(val_jailed "$VAL_B_OP")
  B_UBD_COUNT_POST=$(ubd_count_for "$VAL_B_DEL_BECH")
  B_TOKENS_POST=$(val_tokens "$VAL_B_OP")
  log "  CASE B val-18: in_store=$B_VAL_STATUS_POST jailed=$B_JAILED_POST tokens=$B_TOKENS_POST UBD_count_for_operator=$B_UBD_COUNT_POST"
}

# ---------------- Phase 6 — wait for unbonding maturation + balance check ----------------
A_EVM_BAL_PRE=""; A_EVM_BAL_POST=""; B_EVM_BAL_PRE=""; B_EVM_BAL_POST=""
phase_6_mature_balance() {
  log "Phase 6 — record pre-mature EVM balances, wait past unbonding_time, re-record"
  local a_evm b_evm
  a_evm=$(meta_evm_addr "localnet-val-17")
  b_evm=$(meta_evm_addr "localnet-val-18")
  A_EVM_BAL_PRE=$(get_evm_balance "$a_evm")
  B_EVM_BAL_PRE=$(get_evm_balance "$b_evm")
  log "  pre-mature A EVM bal=$A_EVM_BAL_PRE  B EVM bal=$B_EVM_BAL_PRE"

  wait_height "$(( $(get_height) + 8 ))" >/dev/null  # give 10s+buffer

  A_EVM_BAL_POST=$(get_evm_balance "$a_evm")
  B_EVM_BAL_POST=$(get_evm_balance "$b_evm")
  log "  post-mature A EVM bal=$A_EVM_BAL_POST (delta=$((A_EVM_BAL_POST - A_EVM_BAL_PRE)))"
  log "  post-mature B EVM bal=$B_EVM_BAL_POST (delta=$((B_EVM_BAL_POST - B_EVM_BAL_PRE)))"
}

# ---------------- Phase 7 — summary ----------------
phase_7_summary() {
  printf "\n========== UNSTAKE PROBE CONCLUSIONS ==========\n"
  printf "CASE A (val-17, self-del only, 100%% unstake):\n"
  printf "  CLI rc=%s tx=%s\n" "$A_RC" "$A_TX"
  printf "  val-17 in store post-tx: %s (expected 'GONE' per source analysis: RemoveValidator fires)\n" "$A_VAL_STATUS_POST"
  printf "  UBD entries for operator: %s (expected >=1)\n" "$A_UBD_COUNT_POST"
  printf "  operator EVM balance delta: %s wei (expected ~ %s wei after mature)\n" "$((A_EVM_BAL_POST - A_EVM_BAL_PRE))" "$(echo "$VAL_A_TOKENS * 1000000000" | bc)"
  printf "\n"
  printf "CASE B (val-18, external del, 100%% self-unstake):\n"
  printf "  CLI rc=%s tx=%s\n" "$B_RC" "$B_TX"
  printf "  val-18 in store post-tx: %s (expected '1' UNBONDED, NOT removed — Anvil del keeps shares>0)\n" "$B_VAL_STATUS_POST"
  printf "  val-18 jailed: %s (expected 'true' — self-del drop below MinSelfDelegation triggers jail)\n" "$B_JAILED_POST"
  printf "  val-18 tokens: %s (expected ~2048e9 = anvil only)\n" "$B_TOKENS_POST"
  printf "  UBD entries for operator: %s (expected >=1)\n" "$B_UBD_COUNT_POST"
  printf "  operator EVM balance delta: %s wei (expected ~ %s wei after mature)\n" "$((B_EVM_BAL_POST - B_EVM_BAL_PRE))" "$(echo "$VAL_B_TOKENS * 1000000000" | bc)"
  printf "===============================================\n"
}

phase_8_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then
    log "Phase 8 — SKIP_TEARDOWN"
    return
  fi
  log "Phase 8 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

main() {
  phase_0_start
  phase_1_baseline
  phase_2_ext_del_B
  phase_3_fund_ops
  phase_4_submit_unstakes
  phase_5_verify_post
  phase_6_mature_balance
  phase_7_summary
  phase_8_teardown
}

main "$@"
