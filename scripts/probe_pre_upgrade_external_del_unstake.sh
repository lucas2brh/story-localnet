#!/usr/bin/env bash
# probe_pre_upgrade_external_del_unstake.sh — mainnet-realistic scenario:
# external delegator stakes BEFORE the upgrade (while val is BONDED), val
# is pruned at v1.7.0 activation, delegator unstakes AFTER the upgrade.
#
# Distinct from probe_external_del_unstake.sh which injects the Anvil
# delegation post-upgrade (delegating to an already-UNBONDED val). That
# is chain-legal but not how mainnet pruned vals look — on mainnet the
# external delegators existed during the BONDED period and carry through
# the V170 prune attached to a now-UNBONDED val.
#
# Setup:
#   Fresh 20-val localnet. genesis token distribution from
#   distribution_mainnet_snapshot.json gives val-19 baseline 247,568 IP
#   at rank 19 (well below rank-16's 307,785 IP). Anvil stakes 2048 IP
#   pre-upgrade — val-19 ends 249,616 IP, still rank 19, still in
#   pre-upgrade BONDED top-20, will be pruned at V170.
#
# Expected:
#   - val-19 status post-upgrade: 1 (UNBONDED, pruned)
#   - val-19 retained in store post-unstake (delegator_shares > 0 from operator self-del)
#   - val-19 NOT jailed (operator self-del unchanged)
#   - val-19 tokens drop by Anvil's portion (~2048 IP)
#   - chain progresses (no halt)
#   - Anvil EVM wallet credited ~2048 IP after unbonding mature
#
# Usage:
#   ./scripts/probe_pre_upgrade_external_del_unstake.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_pre_upgrade_external_del_unstake.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
PRE_UPGRADE_STAKE_BLOCK=${PRE_UPGRADE_STAKE_BLOCK:-10}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-65}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ANVIL_ADDR=${ANVIL_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
TARGET_MONIKER="localnet-val-19"
EXTERNAL_STAKE_IP=2048
EXTERNAL_STAKE_WEI="2048000000000000000000"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[pre-ext-del]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[pre-ext-del]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[pre-ext-del]${C_RESET} FAIL %s\n" "$*"; exit 1; }

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
meta_op_evm()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }

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

# ---------------- Phase 1 — pre-upgrade baseline at block 10 ----------------
VAL_OP=""; VAL_TOKENS_PRE=""; VAL_SHARES_PRE=""
phase_1_pre_upgrade_baseline() {
  log "Phase 1 — wait to block $PRE_UPGRADE_STAKE_BLOCK (well before V170=$UPGRADE_HEIGHT) and capture $TARGET_MONIKER baseline"
  wait_height "$PRE_UPGRADE_STAKE_BLOCK" >/dev/null
  log "  chain at $(get_height)"
  VAL_OP=$(meta_op_evm "$TARGET_MONIKER")
  local status; status=$(val_field "$VAL_OP" status)
  VAL_TOKENS_PRE=$(val_field "$VAL_OP" tokens)
  VAL_SHARES_PRE=$(val_field "$VAL_OP" delegator_shares)
  log "  $TARGET_MONIKER op=$VAL_OP status=$status tokens=$VAL_TOKENS_PRE shares=$VAL_SHARES_PRE"
  [[ "$status" == "3" ]] || fail "$TARGET_MONIKER expected BONDED (status=3) pre-upgrade, got status=$status"
  pass "target val confirmed BONDED pre-upgrade"
}

# ---------------- Phase 2 — Anvil delegates pre-upgrade ----------------
ANVIL_BAL_PRE_STAKE=""; ANVIL_BAL_POST_STAKE=""
VAL_TOKENS_POST_STAKE=""
phase_2_anvil_stake_pre_upgrade() {
  log "Phase 2 — Anvil stakes ${EXTERNAL_STAKE_IP} IP to $TARGET_MONIKER (pre-upgrade, val still BONDED)"
  ANVIL_BAL_PRE_STAKE=$(get_evm_balance "$ANVIL_ADDR")
  log "  Anvil pre-stake balance=$ANVIL_BAL_PRE_STAKE wei"
  local pub; pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  local out rc
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
    --validator-pubkey "$pub" --stake "$EXTERNAL_STAKE_WEI" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -5
  [[ $rc -eq 0 ]] || fail "anvil stake rc=$rc"
  sleep 15
  ANVIL_BAL_POST_STAKE=$(get_evm_balance "$ANVIL_ADDR")
  VAL_TOKENS_POST_STAKE=$(val_field "$VAL_OP" tokens)
  local shares_post status_post
  shares_post=$(val_field "$VAL_OP" delegator_shares)
  status_post=$(val_field "$VAL_OP" status)
  log "  Anvil post-stake balance=$ANVIL_BAL_POST_STAKE wei (delta=-$((ANVIL_BAL_PRE_STAKE - ANVIL_BAL_POST_STAKE)))"
  log "  $TARGET_MONIKER post-stake status=$status_post tokens=$VAL_TOKENS_POST_STAKE shares=$shares_post"
  [[ "$status_post" == "3" ]] || fail "expected $TARGET_MONIKER still BONDED after Anvil stake (small amount), got $status_post"
  [[ "$VAL_TOKENS_POST_STAKE" -gt "$VAL_TOKENS_PRE" ]] || fail "post-stake tokens did not grow"
  pass "external delegation injected pre-upgrade, val still BONDED"
}

# ---------------- Phase 3 — wait past upgrade, val gets pruned ----------------
phase_3_post_upgrade_state() {
  log "Phase 3 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_BLOCK (let prune settle)"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  local status; status=$(val_field "$VAL_OP" status)
  local tokens; tokens=$(val_field "$VAL_OP" tokens)
  log "  $TARGET_MONIKER post-upgrade status=$status tokens=$tokens"
  [[ "$status" == "1" ]] || fail "expected $TARGET_MONIKER pruned to UNBONDED (status=1) post-upgrade, got $status"
  pass "target val pruned to UNBONDED, multi-del shape carried through"
}

# ---------------- Phase 4 — Anvil 100% unstakes post-upgrade ----------------
UNSTAKE_TX=""; UNSTAKE_RC=""
phase_4_anvil_unstake_post_upgrade() {
  log "Phase 4 — Anvil 100% unstakes from $TARGET_MONIKER (delegation-id=0, post-upgrade)"
  local pub; pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  local out
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$EXTERNAL_STAKE_WEI" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  UNSTAKE_RC=$?
  UNSTAKE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  log "  tx=$UNSTAKE_TX rc=$UNSTAKE_RC"
  [[ "$UNSTAKE_RC" == "0" ]] || fail "anvil unstake rc=$UNSTAKE_RC"
  wait_height "$(( $(get_height) + 5 ))" >/dev/null
}

# ---------------- Phase 5 — verify post-unstake state ----------------
phase_5_verify() {
  log "Phase 5 — verify post-unstake state"
  local status jailed tokens shares
  status=$(val_field "$VAL_OP" status)
  jailed=$(val_field "$VAL_OP" jailed)
  tokens=$(val_field "$VAL_OP" tokens)
  shares=$(val_field "$VAL_OP" delegator_shares)
  log "  $TARGET_MONIKER post-unstake: status=$status jailed=$jailed tokens=$tokens shares=$shares"

  [[ "$status" != "GONE" ]]      || fail "val removed from store (RemoveValidator should not fire — operator self-del keeps shares > 0)"
  [[ "$status" == "1" ]]         || fail "expected UNBONDED (status=1), got $status"
  [[ "$jailed" != "true" ]]      || fail "expected NOT jailed (operator self-del unchanged), got jailed=$jailed"
  [[ "$tokens" -lt "$VAL_TOKENS_POST_STAKE" ]] || fail "expected tokens reduced from post-stake (Anvil's portion drained), got $tokens >= post-stake $VAL_TOKENS_POST_STAKE"

  log "  tokens went pre=$VAL_TOKENS_PRE post-stake=$VAL_TOKENS_POST_STAKE post-unstake=$tokens (Anvil portion = $((VAL_TOKENS_POST_STAKE - tokens)) stake; expected ${EXTERNAL_STAKE_IP}e9)"

  local h=$(get_height)
  wait_height "$((h + 3))" >/dev/null
  pass "chain still progressing post-unstake (no halt)"
}

# ---------------- Phase 6 — wait unbonding mature, check Anvil EVM ----------------
ANVIL_BAL_AFTER_UBD=""
phase_6_anvil_balance() {
  log "Phase 6 — wait past unbonding_time (10s on localnet), sample Anvil EVM balance"
  wait_height "$(( $(get_height) + 8 ))" >/dev/null
  ANVIL_BAL_AFTER_UBD=$(get_evm_balance "$ANVIL_ADDR")
  local delta=$((ANVIL_BAL_AFTER_UBD - ANVIL_BAL_POST_STAKE))
  log "  Anvil after-mature balance=$ANVIL_BAL_AFTER_UBD wei (delta vs post-stake=$delta)"
  log "  expected ~ ${EXTERNAL_STAKE_IP} IP refund = ${EXTERNAL_STAKE_WEI} wei"
}

# ---------------- Phase 7 — summary ----------------
phase_7_summary() {
  printf "\n========== PRE-UPGRADE EXTERNAL-DEL UNSTAKE PROBE CONCLUSIONS ==========\n"
  printf "Target: %s op=%s\n" "$TARGET_MONIKER" "$VAL_OP"
  printf "  Anvil stake timing:   PRE-UPGRADE (block %d, val BONDED at the time)\n" "$PRE_UPGRADE_STAKE_BLOCK"
  printf "  Anvil unstake timing: POST-UPGRADE (after V170=%d)\n" "$UPGRADE_HEIGHT"
  printf "  CLI rc=%s tx=%s\n" "$UNSTAKE_RC" "$UNSTAKE_TX"
  printf "  val status: pre=BONDED(3) post-prune=UNBONDED(1) post-unstake=%s jailed=%s\n" "$(val_field "$VAL_OP" status)" "$(val_field "$VAL_OP" jailed)"
  printf "  tokens pre=%s post-stake=%s post-unstake=%s (Anvil portion drained = %d stake)\n" "$VAL_TOKENS_PRE" "$VAL_TOKENS_POST_STAKE" "$(val_field "$VAL_OP" tokens)" "$((VAL_TOKENS_POST_STAKE - $(val_field "$VAL_OP" tokens)))"
  printf "  Anvil balance: pre-stake=%s post-stake=%s after-ubd=%s\n" "$ANVIL_BAL_PRE_STAKE" "$ANVIL_BAL_POST_STAKE" "$ANVIL_BAL_AFTER_UBD"
  printf "  Final chain height: %s (no halt)\n" "$(get_height)"
  printf "========================================================================\n"
}

phase_8_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 8 — SKIP_TEARDOWN"; return; fi
  log "Phase 8 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_pre_upgrade_baseline
phase_2_anvil_stake_pre_upgrade
phase_3_post_upgrade_state
phase_4_anvil_unstake_post_upgrade
phase_5_verify
phase_6_anvil_balance
phase_7_summary
phase_8_teardown
