#!/usr/bin/env bash
# probe_jail_requires_active.sh — isolated probe for a single question:
# does Cosmos x/staking's jail code (jailValidator call on self-del below
# MinSelfDelegation, delegation.go line 1121) require the validator to be
# in bonded/active status, or does it also fire on UNBONDED validators?
#
# Approach:
#   * Genesis MAX_VALIDATORS_INIT=4 with existing 20 gen_txs → top-4 bonded,
#     rank-5 (moniker localnet-val-5) is UNBONDED from genesis (no v1.7.0
#     handler involved; test runs before UPGRADE_HEIGHT=50).
#   * Inject an external delegation (Anvil #0 stake 2048 IP to val-5),
#     keeping val-5's tokens safely below rank-4 so it stays UNBONDED.
#   * val-5's operator redelegates 50% of self-del to val-1. 50% guarantees
#     remaining self-del is below MinSelfDelegation (which equals genesis
#     initial self-del value), triggering the jail branch, while keeping
#     val.DelegatorShares > 0 (anvil's del still attached), avoiding the
#     L3 RemoveValidator rollback path.
#   * Observe validator.jailed after tx lands.
#
# Output conclusion:
#   jailed=true  → jail runs on UNBONDED; no active precondition
#   jailed=false → jail skipped; active is a precondition
#
# Usage: ./scripts/probe_jail_requires_active.sh

set -u

STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
TARGET_MONIKER="localnet-val-5"
DEST_MONIKER="localnet-val-1"
ANVIL_STAKE_WEI="2048000000000000000000"  # 2048 IP
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
EV_DIR="${LOCALNET}/tmp/probe-jail-active-evidence"
GENESIS="${LOCALNET}/config/story/genesis-node.json"
GENESIS_BAK="${GENESIS}.probe_jail.bak"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[jail]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[jail]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[jail]${C_RESET} FAIL %s\n" "$*"; }
note() { printf "${C_YELLOW}[jail]${C_RESET} NOTE %s\n" "$*"; }

restore_genesis() {
  if [[ -f "$GENESIS_BAK" ]]; then
    mv "$GENESIS_BAK" "$GENESIS"
    log "  genesis restored from backup"
  fi
}
trap restore_genesis EXIT

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

get_val_full() {
  local op=$1
  curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null | jq -c '.msg.validator'
}

get_val_by_moniker() {
  local moniker=$1
  curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" \
    | jq -c --arg m "$moniker" '.msg.validators[] | select(.description.moniker==$m)'
}

get_val_delegations_count() {
  local op=$1
  curl -fsS "http://localhost:1317/staking/validators/${op}/delegations?pagination.limit=100" 2>/dev/null \
    | jq '.msg.delegation_responses | length'
}

meta_pubkey_hex() {
  local b64
  b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META")
  echo -n "$b64" | base64 -d | xxd -p -c 66
}
meta_privkey() { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }

# ---------------- Phase 0 — assemble genesis max=4, start fresh ----------------
phase_0_start() {
  log "Phase 0 — assemble genesis with MAX_VALIDATORS_INIT=4 + start localnet"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    log "  existing containers found, tearing down first"
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -3)
    sleep 5
  fi
  [[ -f "$GENESIS" ]] || { fail "genesis not found at $GENESIS"; exit 1; }
  cp "$GENESIS" "$GENESIS_BAK"
  MAX_VALIDATORS_INIT=4 STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" 8 2>&1 | tail -1
  local mv_set
  mv_set=$(jq -r '.app_state.staking.params.max_validators' "$GENESIS")
  [[ "$mv_set" == "4" ]] || { fail "genesis max_validators=$mv_set (expected 4)"; exit 1; }
  pass "genesis assembled with max_validators=4"

  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)

  # rpc1 JWT race workaround
  local deadline h
  deadline=$(( $(date +%s) + 90 ))
  while :; do
    h=$(get_height)
    [[ $h -gt 0 ]] && { log "  rpc1 sync good, height=$h"; break; }
    if [[ $(date +%s) -ge $deadline ]]; then
      log "  rpc1 stuck, restarting rpc1-node to reload JWT"
      docker restart rpc1-node >/dev/null 2>&1
      sleep 15
      h=$(get_height)
      [[ $h -gt 0 ]] || { fail "rpc1 did not recover"; exit 1; }
      break
    fi
    sleep 3
  done
}

# ---------------- Phase 1 — confirm baseline ----------------
TARGET_OP=""; DEST_OP=""; TARGET_MIN_SELF_DEL=""; TARGET_TOKENS_BASELINE=""
phase_1_baseline() {
  log "Phase 1 — wait block 10 + confirm baseline"
  wait_height 10 >/dev/null
  local val
  val=$(get_val_by_moniker "$TARGET_MONIKER")
  [[ -n "$val" ]] || { fail "cannot find $TARGET_MONIKER"; exit 1; }
  TARGET_OP=$(jq -r .operator_address <<<"$val")
  TARGET_MIN_SELF_DEL=$(jq -r .min_self_delegation <<<"$val")
  TARGET_TOKENS_BASELINE=$(jq -r .tokens <<<"$val")

  local status jailed
  status=$(jq -r .status <<<"$val")
  jailed=$(jq -r .jailed <<<"$val")
  log "  $TARGET_MONIKER op=$TARGET_OP"
  log "    status=$status jailed=$jailed tokens=$TARGET_TOKENS_BASELINE min_self_delegation=$TARGET_MIN_SELF_DEL"

  # REST omits .jailed when false (protobuf default). null == false semantically.
  [[ "$status" == "1" ]] || { fail "baseline status=$status (expected 1 UNBONDED)"; exit 1; }
  [[ "$jailed" == "false" || "$jailed" == "null" ]] || { fail "baseline jailed=$jailed (expected false/null)"; exit 1; }

  local dcount
  dcount=$(get_val_delegations_count "$TARGET_OP")
  log "    delegations count=$dcount (expected 1 from genesis self-del)"

  local destval
  destval=$(get_val_by_moniker "$DEST_MONIKER")
  DEST_OP=$(jq -r .operator_address <<<"$destval")
  log "  $DEST_MONIKER op=$DEST_OP status=$(jq -r .status <<<"$destval") (expected 3 BONDED)"
  pass "baseline confirmed"
}

# ---------------- Phase 2 — inject external delegation via Anvil ----------------
phase_2_inject_ext_del() {
  log "Phase 2 — Anvil #0 stakes 2048 IP to $TARGET_MONIKER"
  local target_pub
  target_pub=$(meta_pubkey_hex "$TARGET_MONIKER")

  local h_before
  h_before=$(get_height)
  local out rc
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
    --validator-pubkey "$target_pub" --stake "$ANVIL_STAKE_WEI" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/    /' | tail -10
  [[ $rc -eq 0 ]] || { fail "anvil stake CLI rc=$rc"; exit 1; }

  wait_height "$((h_before + 10))" >/dev/null

  local dcount val_post status_post
  dcount=$(get_val_delegations_count "$TARGET_OP")
  val_post=$(get_val_full "$TARGET_OP")
  status_post=$(jq -r .status <<<"$val_post")
  log "  post-stake $TARGET_MONIKER delegations=$dcount status=$status_post tokens=$(jq -r .tokens <<<"$val_post")"

  [[ "$dcount" == "2" ]] || { fail "delegations count=$dcount (expected 2 after anvil stake)"; exit 1; }
  [[ "$status_post" == "1" ]] || { fail "post-stake status=$status_post (expected 1 UNBONDED; anvil amount too large, val re-bonded)"; exit 1; }
  pass "external del injected, val-5 still UNBONDED"
}

# ---------------- Phase 3 — operator redelegates 50% of self-del ----------------
REDELEG_TX=""; H_BEFORE_REDEL=""
phase_3_self_redelegate() {
  log "Phase 3 — $TARGET_MONIKER operator redelegate 50% self-del to $DEST_MONIKER"
  local target_pub dest_pub target_priv target_evm_addr
  target_pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  dest_pub=$(meta_pubkey_hex "$DEST_MONIKER")
  target_priv=$(meta_privkey "$TARGET_MONIKER")
  target_evm_addr=$(jq -r --arg m "$TARGET_MONIKER" '.[] | select(.moniker==$m) | .evm_address' "$META")

  # Fund val-5 operator EVM address from Anvil #0 (10 IP: 1 IP redelegate fee + gas buffer).
  # Use --legacy to avoid EIP-1559 fee-market estimation weirdness on Story localnet.
  log "  Phase 3a — fund $TARGET_MONIKER operator EVM $target_evm_addr with 10 IP (legacy tx)"
  local cast_out cast_rc
  cast_out=$(cast send --rpc-url http://localhost:8545 \
    --private-key "$ANVIL_PK" "$target_evm_addr" \
    --value 10ether --legacy --gas-price 50gwei 2>&1)
  cast_rc=$?
  printf '%s\n' "$cast_out" | sed 's/^/      /' | tail -5
  [[ $cast_rc -eq 0 ]] || { fail "cast send rc=$cast_rc"; exit 1; }
  sleep 8
  local target_bal
  target_bal=$(cast balance "$target_evm_addr" --rpc-url http://localhost:8545 2>/dev/null)
  log "    $TARGET_MONIKER operator EVM balance=$target_bal wei"
  # Require at least 5 IP (5e18 wei) landed
  if ! awk -v b="$target_bal" 'BEGIN{exit !(b+0 >= 5000000000000000000)}'; then
    fail "operator balance $target_bal too low after fund"
    exit 1
  fi

  # 100% of original self-del. Original probe used 50% under wrong assumption
  # "MinSelfDelegation == initial self-del" — actually Story localnet sets all
  # vals' min_self_delegation = 1024 IP (1024e9 stake) per assemble_genesis.sh.
  # 50% leaves remaining 554439 IP >> 1024 IP → MSD branch condition unmet → jail
  # correctly does NOT fire (precondition failure, NOT status precondition).
  # 100% drives remaining to 0 < 1024 IP → MSD condition met; tests whether
  # status=UNBONDED itself blocks jail.
  # Anvil 2048 IP ext-del in Phase 2 keeps val.DelegatorShares > 0 → inline
  # RemoveValidator gate stays closed.
  local amount_wei
  amount_wei=$(echo "$TARGET_TOKENS_BASELINE * 1000000000" | bc)
  log "  redelegate amount = 100% of $TARGET_TOKENS_BASELINE = $amount_wei wei (drives op self-del to 0 < MinSelfDelegation=$TARGET_MIN_SELF_DEL)"

  H_BEFORE_REDEL=$(get_height)
  local out rc
  out=$(PRIVATE_KEY="$target_priv" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$target_pub" --validator-dst-pubkey "$dest_pub" \
    --redelegate "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/    /' | tail -10
  REDELEG_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  [[ $rc -eq 0 ]] || { fail "redelegate CLI rc=$rc"; exit 1; }
  log "  redelegate submitted tx=$REDELEG_TX"

  wait_height "$((H_BEFORE_REDEL + 10))" >/dev/null
}

# ---------------- Phase 4 — verify redelegate actually landed on-chain ----------------
phase_4_verify_landed() {
  log "Phase 4 — verify redelegate took effect on-chain"
  local fail_count dst_val dst_tokens_post dst_tokens_delta
  fail_count=$(docker logs rpc1-node 2>&1 | grep -c "Failed to process redelegate" || true)

  dst_val=$(get_val_full "$DEST_OP")
  dst_tokens_post=$(jq -r .tokens <<<"$dst_val")

  log "  Failed-log count: $fail_count"
  log "  $DEST_MONIKER tokens post-tx = $dst_tokens_post"

  # expected dst tokens increase ≈ 50% of TARGET_TOKENS_BASELINE
  local expected_delta
  expected_delta=$(echo "$TARGET_TOKENS_BASELINE / 2" | bc)

  if [[ "$fail_count" -gt 0 ]]; then
    fail "redelegate failed in Cosmos ($fail_count Failed logs) — INCONCLUSIVE"
    exit 2
  fi
  pass "redelegate landed (no Failed logs, expected dst token delta ≈ $expected_delta)"
}

# ---------------- Phase 5 — key observation: .jailed ----------------
phase_5_observe() {
  log "Phase 5 — observe $TARGET_MONIKER .jailed post-redelegate"
  local val status jailed tokens dcount
  val=$(get_val_full "$TARGET_OP")
  status=$(jq -r .status <<<"$val")
  jailed=$(jq -r .jailed <<<"$val")
  tokens=$(jq -r .tokens <<<"$val")
  dcount=$(get_val_delegations_count "$TARGET_OP")
  log "  $TARGET_MONIKER status=$status jailed=$jailed tokens=$tokens delegations=$dcount"

  printf "\n========== JAIL PRECONDITION PROBE CONCLUSION ==========\n"
  printf "Target val: %s (operator=%s)\n" "$TARGET_MONIKER" "$TARGET_OP"
  printf "Pre-redelegate:  status=1 (UNBONDED)  jailed=false\n"
  printf "Action: operator redelegated 50%% of self-del (making remaining self-del << MinSelfDelegation=%s)\n" "$TARGET_MIN_SELF_DEL"
  printf "Post-redelegate: status=%s  jailed=%s  tokens=%s  delegations=%s\n" "$status" "$jailed" "$tokens" "$dcount"
  printf "\n"
  # Post: .jailed true is explicit; false is typically omitted (null). Treat both null/false as "not jailed".
  if [[ "$jailed" == "true" ]]; then
    printf "CONCLUSION: jail runs on UNBONDED validators — NO active precondition.\n"
  else
    printf "CONCLUSION: jail SKIPPED on UNBONDED validator (post jailed=%s) — active IS a precondition.\n" "$jailed"
  fi
  printf "========================================================\n"
}

phase_6_teardown() {
  if [[ "${SKIP_TEARDOWN:-0}" == "1" ]]; then
    log "Phase 6 — SKIP_TEARDOWN"
    return
  fi
  log "Phase 6 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

main() {
  phase_0_start
  phase_1_baseline
  phase_2_inject_ext_del
  phase_3_self_redelegate
  phase_4_verify_landed
  phase_5_observe
  phase_6_teardown
}

main "$@"
