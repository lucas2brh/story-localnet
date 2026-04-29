#!/usr/bin/env bash
# probe_unbonding_window_unstake_redelegate.sh
#
# Verifies that during the unbonding window (post-V170 prune, before src val
# transitions from UNBONDING to UNBONDED), both unstake and redelegate
# operations execute end-to-end and tokens actually move — i.e., the
# silent-rollback bug from piplabs/lion-team-sync#619 does NOT fire on
# UNBONDING vals.
#
# This is the QA verification of the "free escape window" claim: operators
# on V170-pruned validators can move stake out atomically (redelegate) or
# via unstake during the first unbonding_time period after activation.
#
# Setup:
#   - Genesis patch staking.params.unbonding_time = 300s, so V170-pruned vals
#     stay UNBONDING for ~5 minutes — long enough to submit txs while the
#     vals are still status=2.
#   - Localnet gen_txs leave each val with self-delegation only, so the
#     V170-pruned vals (val-17 through val-20) are sole-delegator scenarios
#     identical in shape to the bug-trigger conditions on UNBONDED vals.
#
# Source vals chosen:
#   - val-19 (rank-19, self-delegator only) for unstake test
#   - val-20 (rank-20, self-delegator only) for redelegate test → val-1
#   Independent vals, so unstake and redelegate run on separate stake
#   without interfering with each other.
#
# Verification approach (intentionally end-state focused; not entry-shape):
#   - Both txs receipts status=1 (EVM-layer success)
#   - Redelegate end-state: val-20.tokens decreased by full amount,
#     val-1.tokens increased by exact same amount (atomic, immediate)
#   - Unstake end-state (waits ~300s for UBD to mature): val-19's operator
#     EVM balance increased by val-19_pre_tokens × 10^9 wei (the unstaked
#     amount returned via Story's evmstaking refund pipeline). Tolerance
#     of 1 IP allowed for gas burn on the unstake tx itself.
#   - Chain liveness: no halt, no panic, no CONSENSUS FAILURE in any node log.
#
# UBD = unbonding delegation: cosmos-sdk x/staking record created when a
#       delegator undelegates; tokens are locked in the queue for
#       unbonding_time, then released to the delegator's account.
#
# Usage:
#   ./scripts/probe_unbonding_window_unstake_redelegate.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_unbonding_window_unstake_redelegate.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-55}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

UNSTAKE_SRC_MONIKER=${UNSTAKE_SRC_MONIKER:-localnet-val-19}
REDEL_SRC_MONIKER=${REDEL_SRC_MONIKER:-localnet-val-20}
REDEL_DST_MONIKER=${REDEL_DST_MONIKER:-localnet-val-1}

UNBONDING_TIME=${UNBONDING_TIME:-90s}
UBD_WAIT_BLOCKS=${UBD_WAIT_BLOCKS:-55}   # 90s unbonding_time / 2s block + 10-block buffer
GAS_TOLERANCE_WEI=${GAS_TOLERANCE_WEI:-3000000000000000000}  # 3 IP — Story IPTokenStaking precompile unstake burn ~1.002 IP, headroom for variance

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[unbond-win]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[unbond-win]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[unbond-win]${C_RESET} FAIL %s\n" "$*"; exit 1; }
note() { printf "${C_YELLOW}[unbond-win]${C_RESET} OBSERVED %s\n" "$*"; }

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
wait_tx_status() {
  local tx=$1 deadline=$(( $(date +%s) + 30 )) status
  while :; do
    status=$(get_tx_status "$tx")
    [[ -n "$status" ]] && { echo "$status"; return; }
    [[ $(date +%s) -ge $deadline ]] && { echo ""; return; }
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

# Stake-unit (REST .tokens) → wei via string append (×10^9). Avoids bash int64 overflow on the IP × 10^18 product.
stake_to_wei() { printf '%s000000000\n' "$1"; }

# Compare two big-int decimal strings via python (bash int64 unsafe at this scale).
big_int_diff() { python3 -c "print(int('$1') - int('$2'))"; }
big_int_abs()  { python3 -c "v=int('$1'); print(-v if v<0 else v)"; }
big_int_ge()   { python3 -c "print(1 if int('$1') >= int('$2') else 0)"; }

fund_operator() {
  local addr=$1 amount_eth=${2:-10}
  cast send --rpc-url http://localhost:8545 \
    --private-key "$ANVIL_PK" "$addr" \
    --value "${amount_eth}ether" --legacy --gas-price 50gwei >/dev/null 2>&1 || \
    log "  WARN: cast fund $addr failed (might already be funded)"
  sleep 3
}

DO_UNSTAKE_RC=""; DO_UNSTAKE_TX=""; DO_UNSTAKE_OUT=""
do_unstake() {
  local moniker=$1 amount_wei=$2
  local pub priv
  pub=$(meta_pubkey_hex "$moniker")
  priv=$(meta_privkey "$moniker")
  DO_UNSTAKE_OUT=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" \
    --unstake "$amount_wei" \
    --delegation-id 0 \
    --rpc http://localhost:8545 \
    --chain-id "$CHAIN_ID" 2>&1)
  DO_UNSTAKE_RC=$?
  DO_UNSTAKE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$DO_UNSTAKE_OUT" | head -1)
}

DO_REDELEGATE_RC=""; DO_REDELEGATE_TX=""; DO_REDELEGATE_OUT=""
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

# ---------------- Phase 0 ----------------
phase_0_start() {
  log "Phase 0 — fresh 20-val localnet, patch unbonding_time=$UNBONDING_TIME so V170-pruned vals stay UNBONDING for the test window"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2); sleep 5
  fi
  MAX_VALIDATORS_INIT=20 STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" 20 2>&1 | tail -1

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

# ---------------- Phase 1 ----------------
UNSTAKE_OP=""; UNSTAKE_TOKENS_PRE=""; UNSTAKE_OP_BAL_PRE=""
REDEL_SRC_OP=""; REDEL_SRC_TOKENS_PRE=""
REDEL_DST_OP=""; REDEL_DST_TOKENS_PRE=""
phase_1_baseline() {
  log "Phase 1 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_BLOCK; capture pre-state"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  log "  chain at $(get_height)"

  UNSTAKE_OP=$(meta_op_evm "$UNSTAKE_SRC_MONIKER")
  REDEL_SRC_OP=$(meta_op_evm "$REDEL_SRC_MONIKER")
  REDEL_DST_OP=$(meta_op_evm "$REDEL_DST_MONIKER")

  local s_status r_status d_status
  s_status=$(val_field "$UNSTAKE_OP" status)
  r_status=$(val_field "$REDEL_SRC_OP" status)
  d_status=$(val_field "$REDEL_DST_OP" status)
  UNSTAKE_TOKENS_PRE=$(val_field "$UNSTAKE_OP" tokens)
  REDEL_SRC_TOKENS_PRE=$(val_field "$REDEL_SRC_OP" tokens)
  REDEL_DST_TOKENS_PRE=$(val_field "$REDEL_DST_OP" tokens)

  log "  $UNSTAKE_SRC_MONIKER op=$UNSTAKE_OP status=$s_status tokens=$UNSTAKE_TOKENS_PRE"
  log "  $REDEL_SRC_MONIKER op=$REDEL_SRC_OP status=$r_status tokens=$REDEL_SRC_TOKENS_PRE"
  log "  $REDEL_DST_MONIKER op=$REDEL_DST_OP status=$d_status tokens=$REDEL_DST_TOKENS_PRE"

  [[ "$s_status" == "2" ]] || fail "$UNSTAKE_SRC_MONIKER status=$s_status, expected 2 (UNBONDING). Test premise broken — possibly unbonding_time too short or POST_UPGRADE_BLOCK too late."
  [[ "$r_status" == "2" ]] || fail "$REDEL_SRC_MONIKER status=$r_status, expected 2 (UNBONDING)."
  [[ "$d_status" == "3" ]] || fail "$REDEL_DST_MONIKER status=$d_status, expected 3 (BONDED)."
  pass "both src vals confirmed UNBONDING (status=2); dst val BONDED"

  log "Phase 1.1 — fund operator EVM wallets for tx gas (operator wallets are not pre-funded in genesis)"
  fund_operator "$UNSTAKE_OP" 10
  fund_operator "$REDEL_SRC_OP" 10

  UNSTAKE_OP_BAL_PRE=$(get_evm_balance "$UNSTAKE_OP")
  log "  $UNSTAKE_SRC_MONIKER operator EVM balance post-fund: $UNSTAKE_OP_BAL_PRE wei"
}

# ---------------- Phase 2 ----------------
UNSTAKE_TX=""; REDELEGATE_TX=""
phase_2_submit_txs() {
  log "Phase 2 — submit unstake + redelegate within UNBONDING window"

  local unstake_amount_wei; unstake_amount_wei=$(stake_to_wei "$UNSTAKE_TOKENS_PRE")
  log "  $UNSTAKE_SRC_MONIKER: 100% self-unstake $UNSTAKE_TOKENS_PRE stake = $unstake_amount_wei wei"
  do_unstake "$UNSTAKE_SRC_MONIKER" "$unstake_amount_wei"
  log "    tx=$DO_UNSTAKE_TX rc=$DO_UNSTAKE_RC"
  [[ "$DO_UNSTAKE_RC" == "0" ]] || fail "unstake CLI rc=$DO_UNSTAKE_RC; out:\n$DO_UNSTAKE_OUT"
  [[ -n "$DO_UNSTAKE_TX" ]] || fail "unstake no tx hash; out:\n$DO_UNSTAKE_OUT"
  UNSTAKE_TX="$DO_UNSTAKE_TX"

  local redel_amount_wei; redel_amount_wei=$(stake_to_wei "$REDEL_SRC_TOKENS_PRE")
  log "  $REDEL_SRC_MONIKER -> $REDEL_DST_MONIKER: 100% self-redelegate $REDEL_SRC_TOKENS_PRE stake = $redel_amount_wei wei"
  do_redelegate "$REDEL_SRC_MONIKER" "$REDEL_DST_MONIKER" "$redel_amount_wei"
  log "    tx=$DO_REDELEGATE_TX rc=$DO_REDELEGATE_RC"
  [[ "$DO_REDELEGATE_RC" == "0" ]] || fail "redelegate CLI rc=$DO_REDELEGATE_RC; out:\n$DO_REDELEGATE_OUT"
  [[ -n "$DO_REDELEGATE_TX" ]] || fail "redelegate no tx hash; out:\n$DO_REDELEGATE_OUT"
  REDELEGATE_TX="$DO_REDELEGATE_TX"

  log "  wait for both tx receipts"
  local us_status; us_status=$(wait_tx_status "$UNSTAKE_TX")
  local rd_status; rd_status=$(wait_tx_status "$REDELEGATE_TX")
  log "    unstake EVM tx status: $us_status"
  log "    redelegate EVM tx status: $rd_status"
  [[ "$us_status" == "1" ]] || fail "unstake tx $UNSTAKE_TX EVM status=$us_status, expected 1"
  [[ "$rd_status" == "1" ]] || fail "redelegate tx $REDELEGATE_TX EVM status=$rd_status, expected 1"

  wait_height "$(( $(get_height) + 5 ))" >/dev/null
}

# ---------------- Phase 3 — immediate state check ----------------
phase_3_immediate_state() {
  log "Phase 3 — immediate post-tx state check (atomic redelegate token transfer + unstake src val drain)"

  local us_tokens_post rd_src_tokens_post rd_dst_tokens_post
  us_tokens_post=$(val_field "$UNSTAKE_OP" tokens)
  rd_src_tokens_post=$(val_field "$REDEL_SRC_OP" tokens)
  rd_dst_tokens_post=$(val_field "$REDEL_DST_OP" tokens)

  log "  $UNSTAKE_SRC_MONIKER tokens: $UNSTAKE_TOKENS_PRE -> $us_tokens_post (expected 0; full self-stake unbonded)"
  log "  $REDEL_SRC_MONIKER tokens: $REDEL_SRC_TOKENS_PRE -> $rd_src_tokens_post (expected 0; full self-stake redelegated)"
  log "  $REDEL_DST_MONIKER tokens: $REDEL_DST_TOKENS_PRE -> $rd_dst_tokens_post (expected $REDEL_DST_TOKENS_PRE + $REDEL_SRC_TOKENS_PRE)"

  [[ "$us_tokens_post" == "0" ]] || fail "$UNSTAKE_SRC_MONIKER tokens=$us_tokens_post, expected 0"
  [[ "$rd_src_tokens_post" == "0" ]] || fail "$REDEL_SRC_MONIKER tokens=$rd_src_tokens_post, expected 0"

  local expected_dst; expected_dst=$(python3 -c "print(int('$REDEL_DST_TOKENS_PRE') + int('$REDEL_SRC_TOKENS_PRE'))")
  [[ "$rd_dst_tokens_post" == "$expected_dst" ]] || \
    fail "$REDEL_DST_MONIKER tokens=$rd_dst_tokens_post, expected $expected_dst (delta should equal $REDEL_SRC_MONIKER pre-tokens $REDEL_SRC_TOKENS_PRE)"

  pass "redelegate atomic transfer: val-1 received exactly $REDEL_SRC_TOKENS_PRE stake; src vals drained to 0 as expected"

  # Container log scan for silent-rollback signatures (should be absent on UNBONDING vals)
  local found_log=""
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$'); do
    if docker logs "$c" 2>&1 | grep -qE "Failed to process redelegate|validator_not_found|validator does not exist"; then
      found_log="$c"
      break
    fi
  done
  [[ -z "$found_log" ]] || fail "found silent-rollback signature in $found_log log — UNBONDING-window operations should not trigger this"
  pass "no silent-rollback signature in any validator-node log"
}

# ---------------- Phase 4 — wait UBD maturity, verify EVM balance refund ----------------
phase_4_ubd_maturity() {
  local h_now=$(get_height)
  local target_h=$(( h_now + UBD_WAIT_BLOCKS ))
  log "Phase 4 — wait $UBD_WAIT_BLOCKS blocks ($h_now -> $target_h) for unbonding queue maturity ($UNBONDING_TIME) + evmstaking refund"
  wait_height "$target_h" >/dev/null
  log "  chain at $(get_height)"

  local bal_post; bal_post=$(get_evm_balance "$UNSTAKE_OP")
  local delta; delta=$(big_int_diff "$bal_post" "$UNSTAKE_OP_BAL_PRE")
  local expected; expected=$(stake_to_wei "$UNSTAKE_TOKENS_PRE")
  local diff_from_expected; diff_from_expected=$(big_int_diff "$expected" "$delta")
  local abs_diff; abs_diff=$(big_int_abs "$diff_from_expected")

  log "  $UNSTAKE_SRC_MONIKER operator EVM balance: pre=$UNSTAKE_OP_BAL_PRE post=$bal_post delta=$delta wei"
  log "  expected refund: $expected wei (= $UNSTAKE_TOKENS_PRE stake × 10^9)"
  log "  shortfall vs expected: $abs_diff wei (gas tolerance: $GAS_TOLERANCE_WEI wei)"

  if [[ $(big_int_ge "$delta" "$expected") == "1" ]]; then
    pass "EVM balance delta $delta >= expected refund $expected (operator gained at least the unstaked amount)"
  elif [[ $(big_int_ge "$GAS_TOLERANCE_WEI" "$abs_diff") == "1" ]]; then
    pass "EVM balance delta $delta within gas tolerance ($abs_diff <= $GAS_TOLERANCE_WEI) of expected refund $expected"
  else
    fail "EVM balance delta $delta differs from expected $expected by $abs_diff wei (> tolerance $GAS_TOLERANCE_WEI). Refund pipeline appears to have not delivered the unstaked amount."
  fi
}

# ---------------- Phase 5 — chain liveness ----------------
phase_5_liveness() {
  log "Phase 5 — verify chain still progressing"
  local h=$(get_height)
  wait_height "$((h + 5))" >/dev/null
  pass "chain produced 5+ blocks past UBD maturity (no halt)"

  local panics=0 c
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$'); do
    local n; n=$(docker logs "$c" 2>&1 | grep -cE 'panic|CONSENSUS FAILURE' || true)
    panics=$((panics + n))
  done
  [[ $panics -eq 0 ]] || fail "$panics panic / CONSENSUS FAILURE lines across validator-node containers"
  pass "no panic / CONSENSUS FAILURE in any validator-node log"
}

# ---------------- Phase 6 — summary ----------------
phase_6_summary() {
  printf "\n========== UNBONDING-WINDOW UNSTAKE+REDELEGATE PROBE CONCLUSIONS ==========\n"
  printf "  unbonding_time = %s (patched for test deterministic UNBONDING window)\n" "$UNBONDING_TIME"
  printf "  Both vals confirmed UNBONDING (status=2) at tx submission.\n"
  printf "  Unstake (%s 100%%, %s stake): tx %s status=1; src tokens drained to 0; operator EVM balance refunded after UBD maturity.\n" \
    "$UNSTAKE_SRC_MONIKER" "$UNSTAKE_TOKENS_PRE" "$UNSTAKE_TX"
  printf "  Redelegate (%s -> %s, %s stake): tx %s status=1; src tokens drained to 0; dst tokens increased by exact pre-amount.\n" \
    "$REDEL_SRC_MONIKER" "$REDEL_DST_MONIKER" "$REDEL_SRC_TOKENS_PRE" "$REDELEGATE_TX"
  printf "  No silent-rollback signature in any validator-node log.\n"
  printf "  Conclusion: post-V170 unbonding window IS a free-escape window — both unstake and redelegate from a single-delegator UNBONDING val execute end-to-end without triggering #619 silent rollback.\n"
  printf "  Final chain height: %s\n" "$(get_height)"
  printf "============================================================================\n"
}

phase_7_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 7 — SKIP_TEARDOWN"; return; fi
  log "Phase 7 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline
phase_2_submit_txs
phase_3_immediate_state
phase_4_ubd_maturity
phase_5_liveness
phase_6_summary
phase_7_teardown
