#!/usr/bin/env bash
# probe_unjail_pruned_val.sh — recovery flow for a jailed pruned validator.
#
# Mainnet realism: after v1.7.0 a pruned multi-delegator validator can end up
# jailed (operator 100% self-unstakes -> self-del falls below MinSelfDelegation
# -> auto-jail). Operators will then re-stake above MinSelfDelegation and call
# MsgUnjail to recover. This probe verifies the full recovery flow under the
# new MaxValidators=16 cap on Hans's branch.
#
# Setup:
#   Same as probe_pre_upgrade_multidel_self_unstake.sh up to and including
#   the operator 100%-self-unstake (val-18 ends up UNBONDED + jailed, with
#   only Anvil's 2048 IP delegation remaining). Then this probe re-stakes
#   2000 IP from the operator, calls unjail, asserts jailed=false.
#
# Expected:
#   - After re-stake: val-18 self-del back above MinSelfDelegation (>= 1024 IP)
#   - After MsgUnjail: val-18 jailed field absent (= false)
#   - val-18 remains UNBONDED (re-stake amount is small, no promotion)
#   - chain progresses (no halt)
#
# Usage:
#   ./scripts/probe_unjail_pruned_val.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_unjail_pruned_val.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
PRE_UPGRADE_STAKE_BLOCK=${PRE_UPGRADE_STAKE_BLOCK:-10}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-65}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
TARGET_MONIKER="localnet-val-18"
EXTERNAL_STAKE_WEI="2048000000000000000000"      # Anvil pre-upgrade delegation: 2048 IP
RESTAKE_WEI="2000000000000000000000"             # operator re-stake post-jail: 2000 IP (> 1024 IP MinSelfDelegation)

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[unjail]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[unjail]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[unjail]${C_RESET} FAIL %s\n" "$*"; exit 1; }

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
  MAX_VALIDATORS_INIT=20 STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" 20 2>&1 | tail -1
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "rpc1 didn't sync in 90s"
    sleep 3
  done
}

# ---------------- Phase 1 — Anvil pre-upgrade delegate to val-18 ----------------
VAL_OP=""; VAL_TOKENS_GENESIS=""
phase_1_anvil_pre_upgrade_stake() {
  log "Phase 1 — wait to block $PRE_UPGRADE_STAKE_BLOCK and Anvil delegates 2048 IP to $TARGET_MONIKER (val BONDED)"
  wait_height "$PRE_UPGRADE_STAKE_BLOCK" >/dev/null
  VAL_OP=$(meta_op_evm "$TARGET_MONIKER")
  VAL_TOKENS_GENESIS=$(val_field "$VAL_OP" tokens)
  log "  $TARGET_MONIKER op=$VAL_OP genesis_tokens=$VAL_TOKENS_GENESIS"
  local pub; pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  local out rc
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
    --validator-pubkey "$pub" --stake "$EXTERNAL_STAKE_WEI" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -3
  [[ $rc -eq 0 ]] || fail "anvil pre-upgrade stake rc=$rc"
  sleep 15
  pass "external delegation injected pre-upgrade"
}

# ---------------- Phase 2 — wait past upgrade, val pruned ----------------
phase_2_wait_post_upgrade() {
  log "Phase 2 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_BLOCK"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  local status; status=$(val_field "$VAL_OP" status)
  log "  $TARGET_MONIKER post-upgrade status=$status (expected UNBONDED=1)"
  [[ "$status" == "1" ]] || fail "expected $TARGET_MONIKER pruned to UNBONDED, got $status"
}

# ---------------- Phase 3 — fund operator EVM for gas ----------------
phase_3_fund_operator() {
  log "Phase 3 — Anvil sends 10 IP to $TARGET_MONIKER operator wallet for gas"
  local op_addr; op_addr=$(meta_op_evm "$TARGET_MONIKER")
  local out rc
  out=$(cast send --rpc-url http://localhost:8545 \
    --private-key "$ANVIL_PK" "$op_addr" \
    --value 10ether --legacy --gas-price 50gwei 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || fail "cast send rc=$rc"
  sleep 5
}

# ---------------- Phase 4 — operator 100% self-unstake (triggers jail) ----------------
phase_4_operator_self_unstake() {
  log "Phase 4 — operator 100% self-unstake (= $VAL_TOKENS_GENESIS stake) to drain self-del below MinSelfDelegation"
  local pub priv amount_wei
  pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  priv=$(meta_privkey "$TARGET_MONIKER")
  amount_wei=$(echo "$VAL_TOKENS_GENESIS * 1000000000" | bc)
  local out rc
  out=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || fail "operator self-unstake rc=$rc"
  wait_height "$(( $(get_height) + 5 ))" >/dev/null
}

# ---------------- Phase 5 — verify val jailed (prerequisite for unjail) ----------------
phase_5_verify_jailed() {
  log "Phase 5 — verify $TARGET_MONIKER is jailed (prerequisite for unjail test)"
  local jailed status; jailed=$(val_field "$VAL_OP" jailed); status=$(val_field "$VAL_OP" status)
  log "  $TARGET_MONIKER status=$status jailed=$jailed"
  [[ "$jailed" == "true" ]] || fail "expected jailed=true after operator self-unstake, got jailed=$jailed (test setup broken)"
  pass "val confirmed jailed (setup ready for unjail flow test)"
}

# ---------------- Phase 6 — operator re-stakes above MinSelfDelegation ----------------
RESTAKE_TX=""; RESTAKE_RC=""
phase_6_operator_restake() {
  log "Phase 6 — operator re-stakes 2000 IP to $TARGET_MONIKER (above 1024 IP MinSelfDelegation)"
  local pub priv
  pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  priv=$(meta_privkey "$TARGET_MONIKER")
  local out
  # Wait extra blocks before restake so the operator's self-unstake refund
  # has time to land in the EVM wallet (10s unbonding_time + safety margin).
  # Original Phase 4 +5 wait was marginal and caused transient rc=1 failures.
  wait_height "$(( $(get_height) + 5 ))" >/dev/null
  out=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator stake \
    --validator-pubkey "$pub" --stake "$RESTAKE_WEI" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  RESTAKE_RC=$?
  RESTAKE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  log "  restake tx=$RESTAKE_TX rc=$RESTAKE_RC"
  if [[ "$RESTAKE_RC" != "0" ]]; then
    printf '%s\n' "$out" | sed 's/^/      /' | tail -10
    fail "operator re-stake rc=$RESTAKE_RC (cli stdout above)"
  fi
  wait_height "$(( $(get_height) + 5 ))" >/dev/null
  local tokens; tokens=$(val_field "$VAL_OP" tokens)
  log "  $TARGET_MONIKER post-restake tokens=$tokens"
}

# ---------------- Phase 7 — operator submits MsgUnjail ----------------
UNJAIL_TX=""; UNJAIL_RC=""
phase_7_operator_unjail() {
  log "Phase 7 — operator submits MsgUnjail"
  local priv
  priv=$(meta_privkey "$TARGET_MONIKER")
  # NB: `story validator unjail` does NOT accept --validator-pubkey. Signer
  # comes from PRIVATE_KEY env; pubkey is implicitly derived from the key.
  # Available flags: --chain-id, --enc-key-file, --explorer, --rpc, --story-api.
  local out
  out=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator unjail \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  UNJAIL_RC=$?
  UNJAIL_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  log "  unjail tx=$UNJAIL_TX rc=$UNJAIL_RC"
  printf '%s\n' "$out" | sed 's/^/      /' | tail -5
  [[ "$UNJAIL_RC" == "0" ]] || fail "operator unjail rc=$UNJAIL_RC (cli stdout above)"
  wait_height "$(( $(get_height) + 5 ))" >/dev/null
}

# ---------------- Phase 8 — verify val jailed=false ----------------
phase_8_verify_unjailed() {
  log "Phase 8 — verify $TARGET_MONIKER is no longer jailed"
  local jailed status tokens
  jailed=$(val_field "$VAL_OP" jailed)
  status=$(val_field "$VAL_OP" status)
  tokens=$(val_field "$VAL_OP" tokens)
  log "  $TARGET_MONIKER post-unjail: status=$status jailed=$jailed tokens=$tokens"
  # jailed field is omitted from JSON when false, so we treat "GONE" (no field) as not-jailed
  [[ "$jailed" != "true" ]] || fail "expected jailed != true post-unjail, got jailed=$jailed"
  pass "val unjailed successfully (jailed field absent or false)"

  local h=$(get_height)
  wait_height "$((h + 3))" >/dev/null
  pass "chain still progressing post-unjail"
}

# ---------------- Phase 9 — summary ----------------
phase_9_summary() {
  printf "\n========== UNJAIL PRUNED VAL PROBE CONCLUSIONS ==========\n"
  printf "Target: %s op=%s\n" "$TARGET_MONIKER" "$VAL_OP"
  printf "  Setup: pre-upgrade Anvil 2048 IP delegation, V170 prunes val to UNBONDED, operator 100%% self-unstake -> jailed\n"
  printf "  Re-stake tx=%s rc=%s\n" "$RESTAKE_TX" "$RESTAKE_RC"
  printf "  Unjail tx=%s rc=%s\n" "$UNJAIL_TX" "$UNJAIL_RC"
  printf "  Final: status=%s jailed=%s tokens=%s\n" "$(val_field "$VAL_OP" status)" "$(val_field "$VAL_OP" jailed)" "$(val_field "$VAL_OP" tokens)"
  printf "  Final chain height: %s (no halt)\n" "$(get_height)"
  printf "=========================================================\n"
}

phase_10_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 10 — SKIP_TEARDOWN"; return; fi
  log "Phase 10 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_anvil_pre_upgrade_stake
phase_2_wait_post_upgrade
phase_3_fund_operator
phase_4_operator_self_unstake
phase_5_verify_jailed
phase_6_operator_restake
phase_7_operator_unjail
phase_8_verify_unjailed
phase_9_summary
phase_10_teardown
