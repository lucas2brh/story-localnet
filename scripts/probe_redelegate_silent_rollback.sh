#!/usr/bin/env bash
# probe_redelegate_silent_rollback.sh — reproduce the silent-rollback bug
# documented in piplabs/lion-team-sync#619 and
# lucas-workspace docs/plans/v1.7.0-redelegate-bug-sot.md.
#
# Bug: BeginRedelegation removes the src validator (RemoveValidator fires
# at DelegatorShares == 0 && IsUnbonded == true), then getBeginInfo's
# GetValidator(src) returns ErrNoValidatorFound, the error propagates up,
# evmstaking's CacheContext writeCache is skipped (only runs on err==nil),
# all staking state changes silently roll back. EVM tx confirms with
# status=1, CLI returns rc=0, but on-chain redelegation never happened.
#
# Trigger conditions (all required):
#   1. src val is UNBONDED (status=1) — v1.7.0 prunes 64 mainnet vals to
#      this state at activation
#   2. delegator is the only one remaining on src (DelegatorShares hits 0
#      after Unbond)
#   3. single-call 100% of the only remaining delegation
#
# Probe sets up (1)-(3) on localnet:
#   - explicit unbonding_time=10s patch in Phase 0 so V170-pruned vals reach
#     status=1 (UNBONDED) by POST_UPGRADE_BLOCK. assemble_genesis.sh does NOT
#     reset this field, so the value can drift from prior probe runs; we always
#     re-patch to be deterministic.
#   - localnet gen_txs leave each val with self-delegation only (no external
#     delegators), so condition (2) holds for any pruned val out of the box
#   - redelegate amount = val.tokens (100% of self-delegation; uses string
#     append to avoid bash int64 overflow on the wei conversion)
#
# RED-GREEN test pattern (this probe inverts the usual PASS=good convention):
#   - PASS = bug still present (all 4 silent-rollback indicators hold)
#   - FAIL = bug fixed (at least one indicator flips, e.g. SRC tokens
#     actually changed because the redelegation persisted)
#
# Indicators checked in Phase 4:
#   (a) src val record still exists in store (rollback healed RemoveValidator)
#   (b) src val tokens unchanged from pre-state (Unbond rolled back)
#   (c) dst val tokens unchanged from pre-state (Delegate rolled back)
#   (d) container log on at least one validator-node shows the error string
#       "Failed to process redelegate" or "validator_not_found"
#
# Usage:
#   ./scripts/probe_redelegate_silent_rollback.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_redelegate_silent_rollback.sh
#   SRC_MONIKER=localnet-val-20 ./scripts/probe_redelegate_silent_rollback.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-65}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
SRC_MONIKER=${SRC_MONIKER:-localnet-val-19}   # rank-19; V170-pruned (UNBONDED post-V170)
DST_MONIKER=${DST_MONIKER:-localnet-val-1}    # rank-1; BONDED
UNBONDING_TIME=${UNBONDING_TIME:-10s}         # patched explicitly so V170-pruned vals reach status=1 by POST_UPGRADE_BLOCK; default genesis value is whatever was in the file last (assemble_genesis.sh does NOT reset this field)

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[silent]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[silent]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[silent]${C_RESET} FAIL %s\n" "$*"; exit 1; }
note() { printf "${C_YELLOW}[silent]${C_RESET} OBSERVED %s\n" "$*"; }

get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}
wait_height() { local target=$1 h; while :; do h=$(get_height); [[ $h -ge $target ]] && { echo "$h"; return; }; sleep 2; done; }
get_tx_status() {
  local tx=$1 hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$tx\"],\"id\":1}" 2>/dev/null \
    | jq -r '.result.status // ""')
  case "$hex" in
    0x1) echo 1;;
    0x0) echo 0;;
    *)   echo "";;
  esac
}
get_evm_balance() {
  local addr=$1 hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$addr\",\"latest\"],\"id\":1}" \
    | jq -r .result)
  python3 -c "print(int('$hex', 16))" 2>/dev/null || echo 0
}
val_field() {
  local body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${1}" 2>/dev/null)
  [[ -z $body ]] && { echo "GONE"; return; }
  jq -r ".msg.validator.${2} // \"GONE\"" <<<"$body"
}
val_exists() {
  local body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${1}" 2>/dev/null)
  [[ -n "$body" ]] && echo "yes" || echo "no"
}
meta_pubkey_hex() { local b64; b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META"); echo -n "$b64" | base64 -d | xxd -p -c 66; }
meta_privkey()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }
meta_op_evm()     { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }

# IP-domain → wei via string append (avoids bash int64 overflow on `IP × 10^18`).
ip_to_wei()    { printf '%s000000000000000000\n' "$1"; }
# Stake-unit (REST .tokens field) → wei via string append (×10^9).
stake_to_wei() { printf '%s000000000\n' "$1"; }

fund_operator() {
  local addr=$1 amount_eth=${2:-10}
  cast send --rpc-url http://localhost:8545 \
    --private-key "$ANVIL_PK" "$addr" \
    --value "${amount_eth}ether" --legacy --gas-price 50gwei >/dev/null 2>&1 || \
    log "  WARN: cast fund $addr failed (might already be funded)"
  sleep 3
}

DO_REDELEGATE_RC=""
DO_REDELEGATE_TX=""
DO_REDELEGATE_OUT=""
do_redelegate() {
  local src_moniker=$1 dst_moniker=$2 amount_wei=$3
  local src_pub dst_pub priv
  src_pub=$(meta_pubkey_hex "$src_moniker")
  dst_pub=$(meta_pubkey_hex "$dst_moniker")
  priv=$(meta_privkey "$src_moniker")
  DO_REDELEGATE_OUT=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$src_pub" \
    --validator-dst-pubkey "$dst_pub" \
    --redelegate "$amount_wei" \
    --delegation-id 0 \
    --rpc http://localhost:8545 \
    --chain-id "$CHAIN_ID" 2>&1)
  DO_REDELEGATE_RC=$?
  DO_REDELEGATE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$DO_REDELEGATE_OUT" | head -1)
}

wait_tx_status() {
  local tx=$1 deadline=$(( $(date +%s) + 30 )) status
  while :; do
    status=$(get_tx_status "$tx")
    [[ -n "$status" ]] && { echo "$status"; return; }
    [[ $(date +%s) -ge $deadline ]] && { echo ""; return; }
    sleep 2
  done
}

# ---------------- Phase 0 — fresh localnet, patch unbonding_time=10s ----------------
phase_0_start() {
  log "Phase 0 — start fresh 20-val localnet, patch unbonding_time=$UNBONDING_TIME"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2); sleep 5
  fi
  MAX_VALIDATORS_INIT=20 STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" 20 2>&1 | tail -1

  # assemble_genesis.sh leaves unbonding_time alone; previous probes (e.g.,
  # probe_redelegate_pruned_val.sh with 300s) can leave the file in a state
  # incompatible with this probe's "pruned val must reach UNBONDED before
  # POST_UPGRADE_BLOCK" requirement. Re-patch explicitly.
  local genesis="${LOCALNET}/config/story/genesis-node.json"
  jq --arg u "$UNBONDING_TIME" '.app_state.staking.params.unbonding_time = $u' \
    "$genesis" > "$genesis.tmp" && mv "$genesis.tmp" "$genesis"
  local ut; ut=$(jq -r '.app_state.staking.params.unbonding_time' "$genesis")
  log "  staking.unbonding_time=$ut (post-patch)"

  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "rpc1 didn't sync in 90s"
    sleep 3
  done
}

# ---------------- Phase 1 — wait past V170, capture pre-state ----------------
SRC_OP=""; DST_OP=""
SRC_TOKENS_PRE=""; DST_TOKENS_PRE=""; SRC_STATUS_PRE=""
phase_1_baseline() {
  log "Phase 1 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_BLOCK, capture SRC=$SRC_MONIKER + DST=$DST_MONIKER pre-state"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  log "  chain at $(get_height)"

  SRC_OP=$(meta_op_evm "$SRC_MONIKER")
  DST_OP=$(meta_op_evm "$DST_MONIKER")
  SRC_STATUS_PRE=$(val_field "$SRC_OP" status)
  SRC_TOKENS_PRE=$(val_field "$SRC_OP" tokens)
  DST_TOKENS_PRE=$(val_field "$DST_OP" tokens)
  log "  SRC ($SRC_MONIKER) op=$SRC_OP status=$SRC_STATUS_PRE tokens=$SRC_TOKENS_PRE"
  log "  DST ($DST_MONIKER) op=$DST_OP tokens=$DST_TOKENS_PRE"

  # Bug requires SRC fully UNBONDED (status=1). UNBONDING (status=2) does not trigger RemoveValidator.
  [[ "$SRC_STATUS_PRE" == "1" ]] || fail "SRC $SRC_MONIKER status=$SRC_STATUS_PRE, expected 1 (UNBONDED). With unbonding_time=10s and post-upgrade-wait of $((POST_UPGRADE_BLOCK - UPGRADE_HEIGHT)) blocks, SRC should be fully UNBONDED."
  pass "SRC confirmed UNBONDED (status=1) — bug trigger condition (1) met"
}

# ---------------- Phase 2 — fund SRC operator EVM wallet for tx gas ----------------
phase_2_fund() {
  log "Phase 2 — Anvil sends 10 IP gas to SRC operator wallet $SRC_OP (operator wallets are not pre-funded in genesis)"
  local pre; pre=$(get_evm_balance "$SRC_OP")
  log "  SRC operator pre-fund balance: $pre wei"
  fund_operator "$SRC_OP" 10
  local post; post=$(get_evm_balance "$SRC_OP")
  log "  SRC operator post-fund balance: $post wei"
}

# ---------------- Phase 3 — submit 100% self-stake redelegate ----------------
PHASE3_TX=""; PHASE3_AMOUNT_WEI=""
phase_3_redelegate_100pct() {
  PHASE3_AMOUNT_WEI=$(stake_to_wei "$SRC_TOKENS_PRE")
  log "Phase 3 — submit 100% self-stake redelegate: $SRC_TOKENS_PRE stake = $PHASE3_AMOUNT_WEI wei from $SRC_MONIKER -> $DST_MONIKER"
  log "  trigger condition (3): single-call 100% of only remaining delegation -> DelegatorShares hits 0 -> RemoveValidator -> getBeginInfo fails -> silent rollback"

  do_redelegate "$SRC_MONIKER" "$DST_MONIKER" "$PHASE3_AMOUNT_WEI"
  log "  CLI: tx=$DO_REDELEGATE_TX rc=$DO_REDELEGATE_RC"
  [[ "$DO_REDELEGATE_RC" == "0" ]] || fail "Phase 3 CLI rc=$DO_REDELEGATE_RC; out:\n$DO_REDELEGATE_OUT"
  [[ -n "$DO_REDELEGATE_TX" ]] || fail "Phase 3 no tx hash; out:\n$DO_REDELEGATE_OUT"
  PHASE3_TX="$DO_REDELEGATE_TX"

  local status; status=$(wait_tx_status "$PHASE3_TX")
  log "  EVM tx status: $status (1 = success on EVM layer; gas burned, hash on-chain)"
  [[ "$status" == "1" ]] || fail "Phase 3 EVM tx rejected (status=$status). The bug requires EVM-success + Cosmos-rolled-back combo; CLI also did not surface the failure."
  wait_height "$(( $(get_height) + 5 ))" >/dev/null
}

# ---------------- Phase 4 — assert silent-rollback indicators ----------------
phase_4_assert_rollback() {
  log "Phase 4 — assert 4 silent-rollback indicators (PASS = bug still present)"

  # (a) val record still in store
  local src_present; src_present=$(val_exists "$SRC_OP")
  log "  (a) SRC val record in store post-tx: $src_present (expected: yes; rollback healed RemoveValidator)"
  [[ "$src_present" == "yes" ]] || fail "(a) SRC val record GONE — the RemoveValidator was NOT rolled back. Either the bug is fixed or some path actually persisted the removal."

  # (b) SRC tokens unchanged
  local src_tokens_post; src_tokens_post=$(val_field "$SRC_OP" tokens)
  log "  (b) SRC tokens: $SRC_TOKENS_PRE -> $src_tokens_post (expected: unchanged; Unbond rolled back)"
  [[ "$src_tokens_post" == "$SRC_TOKENS_PRE" ]] || fail "(b) SRC tokens changed by $((src_tokens_post - SRC_TOKENS_PRE)). The Unbond persisted. The bug appears FIXED on this binary."

  # (c) DST tokens unchanged
  local dst_tokens_post; dst_tokens_post=$(val_field "$DST_OP" tokens)
  log "  (c) DST tokens: $DST_TOKENS_PRE -> $dst_tokens_post (expected: unchanged; Delegate rolled back)"
  [[ "$dst_tokens_post" == "$DST_TOKENS_PRE" ]] || fail "(c) DST tokens changed by $((dst_tokens_post - DST_TOKENS_PRE)). The Delegate persisted. The bug appears FIXED on this binary."

  # (d) container log carries the diagnostic error string
  local found_log="" matched_line=""
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$'); do
    matched_line=$(docker logs "$c" 2>&1 | grep -E "Failed to process redelegate|validator_not_found|validator does not exist" | head -1 || true)
    if [[ -n "$matched_line" ]]; then
      found_log="$c"
      log "  (d) found error string in $c log:"
      log "      $matched_line"
      break
    fi
  done
  [[ -n "$found_log" ]] || fail "(d) NO validator-node container log shows 'Failed to process redelegate' or 'validator_not_found'. Either the bug is fixed (ProcessRedelegate succeeded) or grep target is stale."

  pass "all 4 silent-rollback indicators confirmed — bug reproduces on this binary"
}

# ---------------- Phase 5 — summary ----------------
phase_5_summary() {
  printf "\n========== SILENT-ROLLBACK PROBE CONCLUSIONS ==========\n"
  printf "  Bug: BeginRedelegation removes UNBONDED-with-zero-DelegatorShares src; getBeginInfo can't re-find it; ErrNoValidatorFound bubbles up; evmstaking CacheContext writeCache skipped; state silently rolled back.\n"
  printf "  Tx hash: %s\n" "$PHASE3_TX"
  printf "  EVM tx status: 1 (success — gas burned, hash on-chain)\n"
  printf "  On-chain effect: SRC tokens %s -> %s (unchanged); DST tokens %s -> %s (unchanged) — silent rollback confirmed.\n" \
    "$SRC_TOKENS_PRE" "$(val_field "$SRC_OP" tokens)" \
    "$DST_TOKENS_PRE" "$(val_field "$DST_OP" tokens)"
  printf "  PROBE PASS = bug still present on this binary.\n"
  printf "  Once a fix lands (cosmos-sdk-private-fork getBeginInfo tolerates ErrNoValidatorFound, or BeginRedelegation pre-captures completion info), this probe's Phase 4 assertions will flip and the probe will FAIL — that is the GREEN signal.\n"
  printf "=======================================================\n"
}

phase_6_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 6 — SKIP_TEARDOWN"; return; fi
  log "Phase 6 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline
phase_2_fund
phase_3_redelegate_100pct
phase_4_assert_rollback
phase_5_summary
phase_6_teardown
