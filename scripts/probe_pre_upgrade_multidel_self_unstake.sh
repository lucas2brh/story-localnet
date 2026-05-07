#!/usr/bin/env bash
# probe_pre_upgrade_multidel_self_unstake.sh — mainnet-realistic scenario:
# external delegator existed pre-upgrade (BONDED period), val gets pruned at
# v1.7.0 activation, operator then 100% self-unstakes after the prune.
#
# Distinct from probe_unstake_pruned_val.sh's val-18 case which injects the
# Anvil delegation post-upgrade (delegating to an already-UNBONDED val).
# That is chain-legal but not how mainnet looks — this probe carries the
# multi-del shape THROUGH the V170 prune, matching mainnet pruned vals.
#
# Setup:
#   Fresh 20-val localnet. val-18 baseline 266,202 IP (rank 18, in BONDED top-20).
#   At block 10 Anvil delegates 2048 IP to val-18 — val-18 ends 268,250 IP,
#   still rank 18, still in pre-upgrade BONDED top-20, will be pruned at V170.
#   Past V170 the val carries (operator self-del + Anvil del) into UNBONDED.
#   Operator then 100% self-unstakes.
#
# Expected:
#   - val-18 status post-upgrade: 1 (UNBONDED, pruned)
#   - val-18 retained in store post-unstake (Anvil delegator_shares > 0 prevents RemoveValidator)
#   - val-18 jailed=true (operator self-del fell below MinSelfDelegation = 1024 IP)
#   - val-18 tokens drop by operator portion (~266k IP), retain ~2048 IP (Anvil only)
#   - chain progresses (no halt)
#   - operator EVM wallet credited ~266k IP after unbonding mature
#
# Usage:
#   ./scripts/probe_pre_upgrade_multidel_self_unstake.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_pre_upgrade_multidel_self_unstake.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-70}
PRE_UPGRADE_STAKE_BLOCK=${PRE_UPGRADE_STAKE_BLOCK:-10}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-75}
N_VALS=${N_VALS:-8}
NEW_MAX=${NEW_MAX:-4}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ANVIL_ADDR=${ANVIL_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
TARGET_MONIKER=${TARGET_MONIKER:-localnet-val-6}
EXTERNAL_STAKE_IP=${EXTERNAL_STAKE_IP:-2048}
EXTERNAL_STAKE_WEI=${EXTERNAL_STAKE_WEI:-${EXTERNAL_STAKE_IP}000000000000000000}
RUN_BOB_PHASES=${RUN_BOB_PHASES:-0}

# ---- Phase 2b: pre-V170 scenario (Raul Case 3c strict) ----
# Different target val (will-be-pruned). Anvil delegates externally first, then val-7
# operator FULLY self-unstakes BEFORE H. Anvil's del keeps DelegatorShares > 0 so
# RemoveValidator does NOT fire — val survives V170 prune and emerges UNBONDED+jailed.
PRE_H_TARGET_MONIKER=${PRE_H_TARGET_MONIKER:-localnet-val-7}

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[pre-multidel]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[pre-multidel]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[pre-multidel]${C_RESET} FAIL %s\n" "$*"; exit 1; }

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

# ---------------- Phase 1 — pre-upgrade baseline at block 10 ----------------
VAL_OP=""; VAL_TOKENS_GENESIS=""
phase_1_pre_upgrade_baseline() {
  log "Phase 1 — wait to block $PRE_UPGRADE_STAKE_BLOCK and capture $TARGET_MONIKER baseline"
  wait_height "$PRE_UPGRADE_STAKE_BLOCK" >/dev/null
  log "  chain at $(get_height)"
  VAL_OP=$(meta_op_evm "$TARGET_MONIKER")
  local status; status=$(val_field "$VAL_OP" status)
  VAL_TOKENS_GENESIS=$(val_field "$VAL_OP" tokens)
  log "  $TARGET_MONIKER op=$VAL_OP status=$status genesis_tokens=$VAL_TOKENS_GENESIS (= operator self-del; no external dels yet)"
  [[ "$status" == "3" ]] || fail "$TARGET_MONIKER expected BONDED (status=3) pre-upgrade, got status=$status"
  pass "target val confirmed BONDED pre-upgrade"
}

# ---------------- Phase 2 — Anvil delegates pre-upgrade ----------------
VAL_TOKENS_POST_STAKE=""
phase_2_anvil_stake_pre_upgrade() {
  log "Phase 2 — Anvil stakes ${EXTERNAL_STAKE_IP} IP to $TARGET_MONIKER (pre-upgrade, val still BONDED)"
  local pub; pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  local out rc
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
    --validator-pubkey "$pub" --stake "$EXTERNAL_STAKE_WEI" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -5
  [[ $rc -eq 0 ]] || fail "anvil stake rc=$rc"
  sleep 15
  VAL_TOKENS_POST_STAKE=$(val_field "$VAL_OP" tokens)
  local shares_post status_post
  shares_post=$(val_field "$VAL_OP" delegator_shares)
  status_post=$(val_field "$VAL_OP" status)
  log "  $TARGET_MONIKER post-stake status=$status_post tokens=$VAL_TOKENS_POST_STAKE shares=$shares_post"
  [[ "$status_post" == "3" ]] || fail "expected $TARGET_MONIKER still BONDED after Anvil stake, got $status_post"
  [[ "$VAL_TOKENS_POST_STAKE" -gt "$VAL_TOKENS_GENESIS" ]] || fail "post-stake tokens did not grow"
  pass "external delegation injected pre-upgrade, multi-del shape established"
}

# ---------------- Phase 2b — pre-V170 op fully-self-unstake on val-7 (Raul Case 3c strict) ----------------
PRE_H_VAL_OP=""; PRE_H_VAL_TOKENS_PRE=""; PRE_H_VAL_TOKENS_POST_DEL=""; PRE_H_VAL_TOKENS_POST_UNSTAKE=""
PRE_H_DELEGATE_TX=""; PRE_H_UNSTAKE_TX=""
phase_2b_pre_v170_full_self_unstake() {
  log "Phase 2b — pre-V170 scenario on $PRE_H_TARGET_MONIKER (Raul Case 3c strict: external del present + op fully self-unstakes BEFORE H)"
  PRE_H_VAL_OP=$(meta_op_evm "$PRE_H_TARGET_MONIKER")
  PRE_H_VAL_TOKENS_PRE=$(val_field "$PRE_H_VAL_OP" tokens)
  log "  $PRE_H_TARGET_MONIKER op=$PRE_H_VAL_OP genesis tokens=$PRE_H_VAL_TOKENS_PRE"

  # Step 1: Anvil delegates 2048 IP to val-7 (creates external del so RemoveValidator can't fire later)
  local pub; pub=$(meta_pubkey_hex "$PRE_H_TARGET_MONIKER")
  local out rc
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
    --validator-pubkey "$pub" --stake "$EXTERNAL_STAKE_WEI" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  PRE_H_DELEGATE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  [[ $rc -eq 0 ]] || fail "Anvil delegate to $PRE_H_TARGET_MONIKER: rc=$rc"
  log "  Anvil delegated ${EXTERNAL_STAKE_IP} IP → $PRE_H_TARGET_MONIKER, tx=$PRE_H_DELEGATE_TX"
  wait_height "$(( $(get_height) + 3 ))" >/dev/null
  PRE_H_VAL_TOKENS_POST_DEL=$(val_field "$PRE_H_VAL_OP" tokens)
  log "  $PRE_H_TARGET_MONIKER post-del tokens=$PRE_H_VAL_TOKENS_POST_DEL"
  [[ "$PRE_H_VAL_TOKENS_POST_DEL" -gt "$PRE_H_VAL_TOKENS_PRE" ]] || fail "post-del tokens did not grow"

  # Step 2: fund val-7 op for unstake gas
  local fund_rc fund_out
  fund_out=$(cast send --rpc-url http://localhost:8545 --private-key "$ANVIL_PK" "$PRE_H_VAL_OP" \
    --value 10ether --legacy --gas-price 50gwei 2>&1)
  fund_rc=$?
  [[ $fund_rc -eq 0 ]] || fail "fund $PRE_H_TARGET_MONIKER op: cast send rc=$fund_rc"
  sleep 5

  # Step 3: val-7 op FULLY self-unstakes (residual = 0 < MinSelfDel; jail trigger)
  local priv amount_wei
  priv=$(meta_privkey "$PRE_H_TARGET_MONIKER")
  amount_wei=$(echo "$PRE_H_VAL_TOKENS_PRE * 1000000000" | bc)
  log "  $PRE_H_TARGET_MONIKER op fully self-unstakes $PRE_H_VAL_TOKENS_PRE stake = $amount_wei wei"
  out=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  PRE_H_UNSTAKE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  [[ $rc -eq 0 ]] || fail "$PRE_H_TARGET_MONIKER op self-unstake: rc=$rc ($out)"
  log "  $PRE_H_TARGET_MONIKER op self-unstake tx=$PRE_H_UNSTAKE_TX"
  wait_height "$(( $(get_height) + 5 ))" >/dev/null

  # Verify pre-V170 state: NOT GONE (Anvil del keeps shares > 0), jailed=true
  local pre_st pre_jailed pre_tk
  pre_st=$(val_field "$PRE_H_VAL_OP" status)
  pre_jailed=$(val_field "$PRE_H_VAL_OP" jailed)
  pre_tk=$(val_field "$PRE_H_VAL_OP" tokens)
  PRE_H_VAL_TOKENS_POST_UNSTAKE=$pre_tk
  log "  $PRE_H_TARGET_MONIKER post-self-unstake (pre-V170): status=$pre_st jailed=$pre_jailed tokens=$pre_tk"
  [[ "$pre_st" != "GONE" ]] || fail "$PRE_H_TARGET_MONIKER GONE pre-V170 — Anvil del should keep DelegatorShares > 0"
  [[ "$pre_jailed" == "true" ]] || fail "$PRE_H_TARGET_MONIKER expected jailed=true (op self-del fell below MinSelfDel), got jailed=$pre_jailed"
  pass "Raul Case 3c strict pre-V170: $PRE_H_TARGET_MONIKER op fully self-unstaked, val survives (Anvil del present), jailed=true"
}

# ---------------- Phase 3 — wait past upgrade + cluster sanity ----------------
phase_3_post_upgrade_state() {
  log "Phase 3 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_BLOCK"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null

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

  # Verify pre-V170 target (val-7) carried through prune cleanly
  local pre_h_st pre_h_jailed pre_h_tk
  pre_h_st=$(val_field "$PRE_H_VAL_OP" status)
  pre_h_jailed=$(val_field "$PRE_H_VAL_OP" jailed)
  pre_h_tk=$(val_field "$PRE_H_VAL_OP" tokens)
  log "  $PRE_H_TARGET_MONIKER post-V170: status=$pre_h_st jailed=$pre_h_jailed tokens=$pre_h_tk (expected status=1, jailed=true, tokens == pre-V170-post-unstake $PRE_H_VAL_TOKENS_POST_UNSTAKE)"
  [[ "$pre_h_st" == "1" ]] || fail "$PRE_H_TARGET_MONIKER expected UNBONDED (status=1) post-V170, got $pre_h_st"
  [[ "$pre_h_jailed" == "true" ]] || fail "$PRE_H_TARGET_MONIKER jailed flag should persist through V170, got $pre_h_jailed"
  [[ "$pre_h_tk" == "$PRE_H_VAL_TOKENS_POST_UNSTAKE" ]] || fail "$PRE_H_TARGET_MONIKER tokens drift: pre-V170-post-unstake=$PRE_H_VAL_TOKENS_POST_UNSTAKE post-V170=$pre_h_tk"
  pass "Raul Case 3c strict: pre-V170 op self-unstake on $PRE_H_TARGET_MONIKER carried through V170 prune cleanly"

  local status; status=$(val_field "$VAL_OP" status)
  local tokens; tokens=$(val_field "$VAL_OP" tokens)
  log "  $TARGET_MONIKER post-upgrade status=$status tokens=$tokens (multi-del shape carried through prune)"
  [[ "$status" == "1" ]] || fail "expected $TARGET_MONIKER pruned to UNBONDED post-upgrade, got $status"
  pass "target val pruned to UNBONDED while carrying multi-del shape"
}

# ---------------- Phase 4 — fund operator EVM wallet for gas ----------------
OP_EVM_BAL_PRE=""
phase_4_fund_operator() {
  log "Phase 4 — Anvil sends 10 IP to $TARGET_MONIKER operator wallet for unstake gas"
  local op_addr; op_addr=$(meta_op_evm "$TARGET_MONIKER")
  OP_EVM_BAL_PRE=$(get_evm_balance "$op_addr")
  log "  operator $op_addr pre-fund balance=$OP_EVM_BAL_PRE wei"
  local out rc
  out=$(cast send --rpc-url http://localhost:8545 \
    --private-key "$ANVIL_PK" "$op_addr" \
    --value 10ether --legacy --gas-price 50gwei 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || fail "cast send rc=$rc ($out)"
  sleep 5
  local op_bal; op_bal=$(get_evm_balance "$op_addr")
  log "  operator post-fund balance=$op_bal wei"
}

# ---------------- Phase 5 — operator 100% self-unstake ----------------
SELF_UNSTAKE_TX=""; SELF_UNSTAKE_RC=""
phase_5_operator_self_unstake() {
  log "Phase 5 — operator 100% self-unstakes (amount = genesis tokens = $VAL_TOKENS_GENESIS stake)"
  local pub priv amount_wei
  pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  priv=$(meta_privkey "$TARGET_MONIKER")
  # operator self-del at genesis = val tokens (no external dels yet); convert stake -> wei (× 1e9)
  amount_wei=$(echo "$VAL_TOKENS_GENESIS * 1000000000" | bc)
  log "  $TARGET_MONIKER operator unstakes $VAL_TOKENS_GENESIS stake = $amount_wei wei (delegation-id=0)"
  local out
  out=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  SELF_UNSTAKE_RC=$?
  SELF_UNSTAKE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  log "  tx=$SELF_UNSTAKE_TX rc=$SELF_UNSTAKE_RC"
  [[ "$SELF_UNSTAKE_RC" == "0" ]] || fail "operator self-unstake rc=$SELF_UNSTAKE_RC"
  wait_height "$(( $(get_height) + 5 ))" >/dev/null
}

# ---------------- Phase 6 — verify post-unstake state ----------------
phase_6_verify() {
  log "Phase 6 — verify post-unstake state"
  local status jailed tokens shares
  status=$(val_field "$VAL_OP" status)
  jailed=$(val_field "$VAL_OP" jailed)
  tokens=$(val_field "$VAL_OP" tokens)
  shares=$(val_field "$VAL_OP" delegator_shares)
  log "  $TARGET_MONIKER post-unstake: status=$status jailed=$jailed tokens=$tokens shares=$shares"

  [[ "$status" != "GONE" ]]   || fail "val removed from store (RemoveValidator should not fire — Anvil delegator_shares > 0)"
  [[ "$status" == "1" ]]      || fail "expected UNBONDED (status=1), got $status"
  [[ "$jailed" == "true" ]]   || fail "expected jailed=true (operator self-del fell below MinSelfDelegation), got jailed=$jailed"
  # Tokens should drop to ~ EXTERNAL_STAKE_WEI/1e9 (just Anvil's portion remaining)
  # Parametric on EXTERNAL_STAKE_IP — expect ~ EXTERNAL_STAKE_IP IP retained (Anvil only),
  # with 50 IP slack for any incidental movement.
  local expected_min=$(( (EXTERNAL_STAKE_IP - 50) * 1000000000 ))
  [[ "$tokens" -lt "$VAL_TOKENS_GENESIS" ]] || fail "expected tokens dropped below genesis $VAL_TOKENS_GENESIS, got $tokens"
  [[ "$tokens" -gt "$expected_min" ]]      || fail "expected tokens still > $expected_min (Anvil portion retained), got $tokens"

  log "  tokens went genesis=$VAL_TOKENS_GENESIS post-stake=$VAL_TOKENS_POST_STAKE post-unstake=$tokens"
  log "  operator portion drained = $((VAL_TOKENS_POST_STAKE - tokens)) stake (expected ~$VAL_TOKENS_GENESIS)"

  local h=$(get_height)
  wait_height "$((h + 3))" >/dev/null
  pass "chain still progressing post-unstake (no halt)"
}

# ---------------- Phase 7 — wait unbonding mature, check operator EVM ----------------
OP_EVM_BAL_AFTER_UBD=""
phase_7_operator_balance() {
  log "Phase 7 — wait past unbonding_time (10s), sample operator EVM balance"
  wait_height "$(( $(get_height) + 8 ))" >/dev/null
  local op_addr; op_addr=$(meta_op_evm "$TARGET_MONIKER")
  OP_EVM_BAL_AFTER_UBD=$(get_evm_balance "$op_addr")
  log "  operator after-mature balance=$OP_EVM_BAL_AFTER_UBD wei (vs pre-fund $OP_EVM_BAL_PRE wei)"
  log "  expected refund ~ $VAL_TOKENS_GENESIS stake = $(echo "$VAL_TOKENS_GENESIS * 1000000000" | bc) wei"
}

# ---------- Phase 7b/c/d — Anvil/Bob recoverability after operator self-unstake ----------
# These run only when RUN_BOB_PHASES=1. Tests user scenario:
#   "bob delegated 1024 IP, then operator took self-del away (jailed val);
#    bob never unstaked manually — what happens to bob's tokens?"
BOB_BAL_AFTER_SELF=""; BOB_UNSTAKE_RC=""; BOB_UNSTAKE_TX=""
BOB_BAL_AFTER_RECOVERY=""
phase_7b_bob_observe() {
  [[ "$RUN_BOB_PHASES" == "1" ]] || { log "Phase 7b — RUN_BOB_PHASES=0, skip"; return; }
  log "Phase 7b — observe Anvil/Bob state after operator self-unstake (Bob still passive)"
  BOB_BAL_AFTER_SELF=$(get_evm_balance "$ANVIL_ADDR")
  log "  Anvil EVM bal after-self-unstake=$BOB_BAL_AFTER_SELF wei"
  local tokens shares status jailed
  tokens=$(val_field "$VAL_OP" tokens)
  shares=$(val_field "$VAL_OP" delegator_shares)
  status=$(val_field "$VAL_OP" status)
  jailed=$(val_field "$VAL_OP" jailed)
  log "  val state holding Anvil's stake: status=$status jailed=$jailed tokens=$tokens shares=$shares"
}

phase_7c_bob_unstake() {
  [[ "$RUN_BOB_PHASES" == "1" ]] || { log "Phase 7c — RUN_BOB_PHASES=0, skip"; return; }
  log "Phase 7c — Anvil/Bob attempts 100% unstake (val UNBONDED + jailed; can stake be recovered?)"
  local pub; pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  local out
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$EXTERNAL_STAKE_WEI" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  BOB_UNSTAKE_RC=$?
  BOB_UNSTAKE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  printf '%s\n' "$out" | sed 's/^/      /' | tail -8
  log "  Anvil unstake rc=$BOB_UNSTAKE_RC tx=$BOB_UNSTAKE_TX"
  wait_height "$(( $(get_height) + 5 ))" >/dev/null
}

phase_7d_bob_balance() {
  [[ "$RUN_BOB_PHASES" == "1" ]] || { log "Phase 7d — RUN_BOB_PHASES=0, skip"; return; }
  log "Phase 7d — wait past unbonding (10s), check Anvil EVM balance recovered"
  wait_height "$(( $(get_height) + 8 ))" >/dev/null
  BOB_BAL_AFTER_RECOVERY=$(get_evm_balance "$ANVIL_ADDR")
  # bash $((..)) is int64 — wei values exceed it; use python for arbitrary precision
  local delta=$(python3 -c "print($BOB_BAL_AFTER_RECOVERY - $BOB_BAL_AFTER_SELF)")
  log "  Anvil EVM bal: after-self-unstake=$BOB_BAL_AFTER_SELF after-recovery=$BOB_BAL_AFTER_RECOVERY delta=$delta wei"
  log "  expected delta ~= ${EXTERNAL_STAKE_IP} IP = $EXTERNAL_STAKE_WEI wei (minus gas)"
  if python3 -c "import sys; sys.exit(0 if $delta > 0 else 1)"; then
    local delta_ip
    delta_ip=$(python3 -c "print(f'{$delta / 1e18:.4f}')")
    pass "Anvil/Bob recovered tokens (delta=$delta wei = $delta_ip IP)"
  else
    fail "Anvil/Bob got NOTHING back from jailed-pruned val (stranding bug confirmed)"
  fi
}

# ---------------- Phase 8 — summary ----------------
phase_8_summary() {
  printf "\n========== PRE-UPGRADE MULTIDEL SELF-UNSTAKE PROBE CONCLUSIONS ==========\n"
  printf "Target: %s op=%s\n" "$TARGET_MONIKER" "$VAL_OP"
  printf "  Anvil stake timing:    PRE-UPGRADE (block %d, val BONDED)\n" "$PRE_UPGRADE_STAKE_BLOCK"
  printf "  Operator unstake:      POST-UPGRADE (after V170=%d)\n" "$UPGRADE_HEIGHT"
  printf "  CLI rc=%s tx=%s\n" "$SELF_UNSTAKE_RC" "$SELF_UNSTAKE_TX"
  printf "  val status: pre=BONDED(3) post-prune=UNBONDED(1) post-unstake=%s jailed=%s\n" "$(val_field "$VAL_OP" status)" "$(val_field "$VAL_OP" jailed)"
  printf "  tokens genesis=%s post-stake=%s post-unstake=%s (operator drained = %d stake; Anvil retained ~2048e9)\n" \
    "$VAL_TOKENS_GENESIS" "$VAL_TOKENS_POST_STAKE" "$(val_field "$VAL_OP" tokens)" "$((VAL_TOKENS_POST_STAKE - $(val_field "$VAL_OP" tokens)))"
  printf "  operator EVM bal pre-fund=%s after-ubd=%s\n" "$OP_EVM_BAL_PRE" "$OP_EVM_BAL_AFTER_UBD"
  printf "  Final chain height: %s (no halt)\n" "$(get_height)"
  printf "=========================================================================\n"
}

phase_9_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 9 — SKIP_TEARDOWN"; return; fi
  log "Phase 9 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_pre_upgrade_baseline
phase_2_anvil_stake_pre_upgrade
phase_2b_pre_v170_full_self_unstake
phase_3_post_upgrade_state
phase_4_fund_operator
phase_5_operator_self_unstake
phase_6_verify
phase_7_operator_balance
phase_7b_bob_observe
phase_7c_bob_unstake
phase_7d_bob_balance
phase_8_summary
phase_9_teardown
