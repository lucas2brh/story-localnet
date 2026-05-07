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

N_VALS=${N_VALS:-8}
NEW_MAX=${NEW_MAX:-4}
UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-70}
PRE_UPGRADE_STAKE_BLOCK=${PRE_UPGRADE_STAKE_BLOCK:-10}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-75}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ANVIL_ADDR=${ANVIL_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
TARGET_MONIKER=${TARGET_MONIKER:-localnet-val-7}
EXTERNAL_STAKE_IP=2048
EXTERNAL_STAKE_WEI="2048000000000000000000"

# ---- Phase 2b: pre-V170 scenario (Raul Case 4 strict) ----
# Different target val. Anvil delegates pre-V170, then Anvil 100% UNSTAKES BEFORE H.
# This is the strict Raul Case 4: external delegator preemptively undelegates before H.
PRE_H_TARGET_MONIKER=${PRE_H_TARGET_MONIKER:-localnet-val-8}

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

# ---------------- Phase 2b — pre-V170 Anvil 100% unstake on val-8 (Raul Case 4 strict) ----------------
PRE_H_VAL_OP=""; PRE_H_VAL_TOKENS_PRE=""; PRE_H_VAL_TOKENS_POST_DEL=""; PRE_H_VAL_TOKENS_POST_UNSTAKE=""
PRE_H_DELEGATE_TX=""; PRE_H_UNSTAKE_TX=""; PRE_H_ANVIL_BAL_AFTER_UNSTAKE=""
phase_2b_pre_v170_external_unstake() {
  log "Phase 2b — pre-V170 scenario on $PRE_H_TARGET_MONIKER (Raul Case 4 strict: Anvil delegates + 100% unstakes BEFORE H)"
  PRE_H_VAL_OP=$(meta_op_evm "$PRE_H_TARGET_MONIKER")
  PRE_H_VAL_TOKENS_PRE=$(val_field "$PRE_H_VAL_OP" tokens)
  log "  $PRE_H_TARGET_MONIKER op=$PRE_H_VAL_OP genesis tokens=$PRE_H_VAL_TOKENS_PRE"

  # Step 1: Anvil delegates 2048 IP to val-8 pre-V170
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

  # Step 2: Anvil 100% UNSTAKES from val-8 (preemptive, BEFORE H)
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$EXTERNAL_STAKE_WEI" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  PRE_H_UNSTAKE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  [[ $rc -eq 0 ]] || fail "Anvil pre-V170 unstake from $PRE_H_TARGET_MONIKER: rc=$rc ($out)"
  log "  Anvil 100% unstaked from $PRE_H_TARGET_MONIKER pre-V170, tx=$PRE_H_UNSTAKE_TX"
  wait_height "$(( $(get_height) + 5 ))" >/dev/null

  # Verify pre-V170: val-8 still BONDED (operator self-stake intact > MinSelfDel),
  # tokens reduced back near genesis (Anvil's portion in unbonding)
  local pre_st pre_jailed pre_tk
  pre_st=$(val_field "$PRE_H_VAL_OP" status)
  pre_jailed=$(val_field "$PRE_H_VAL_OP" jailed)
  pre_tk=$(val_field "$PRE_H_VAL_OP" tokens)
  PRE_H_VAL_TOKENS_POST_UNSTAKE=$pre_tk
  log "  $PRE_H_TARGET_MONIKER post-unstake (pre-V170): status=$pre_st jailed=$pre_jailed tokens=$pre_tk (expected status=3, jailed=false, tokens ≈ genesis $PRE_H_VAL_TOKENS_PRE)"
  [[ "$pre_st" == "3" ]] || fail "$PRE_H_TARGET_MONIKER expected still BONDED pre-V170 (operator self-stake intact), got $pre_st"
  [[ "$pre_jailed" != "true" ]] || fail "$PRE_H_TARGET_MONIKER unexpectedly jailed (operator self-stake unchanged), got jailed=$pre_jailed"
  [[ "$pre_tk" == "$PRE_H_VAL_TOKENS_PRE" ]] || fail "$PRE_H_TARGET_MONIKER tokens drift after Anvil unstake: pre=$PRE_H_VAL_TOKENS_PRE post=$pre_tk (expected ≈ genesis since Anvil portion goes to unbonding)"
  pass "Raul Case 4 strict pre-V170: Anvil 100% unstaked from $PRE_H_TARGET_MONIKER, val still BONDED + not jailed (operator self-del intact)"
}

# ---------------- Phase 3 — wait past upgrade + cluster sanity ----------------
phase_3_post_upgrade_state() {
  log "Phase 3 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_BLOCK (let prune settle)"
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

  # Verify pre-V170 target (val-8) carried through prune; Anvil's pre-V170 unstake
  # should have completed (unbonding_time on localnet ~10s short, easily mature by now)
  local pre_h_st pre_h_jailed pre_h_tk
  pre_h_st=$(val_field "$PRE_H_VAL_OP" status)
  pre_h_jailed=$(val_field "$PRE_H_VAL_OP" jailed)
  pre_h_tk=$(val_field "$PRE_H_VAL_OP" tokens)
  log "  $PRE_H_TARGET_MONIKER post-V170: status=$pre_h_st jailed=$pre_h_jailed tokens=$pre_h_tk (expected status=1, jailed=false, tokens ≈ genesis $PRE_H_VAL_TOKENS_PRE — Anvil unbonded pre-V170)"
  [[ "$pre_h_st" == "1" ]] || fail "$PRE_H_TARGET_MONIKER expected UNBONDED (status=1) post-V170, got $pre_h_st"
  [[ "$pre_h_jailed" != "true" ]] || fail "$PRE_H_TARGET_MONIKER jailed unexpectedly post-V170, got jailed=$pre_h_jailed"
  pass "Raul Case 4 strict: pre-V170 Anvil 100% unstake on $PRE_H_TARGET_MONIKER carried through V170 prune"

  # Anvil EVM balance check — pre-V170 unstake should have matured (10s unbonding_time on localnet)
  PRE_H_ANVIL_BAL_AFTER_UNSTAKE=$(get_evm_balance "$ANVIL_ADDR")
  log "  Anvil EVM balance after $PRE_H_TARGET_MONIKER unstake mature: $PRE_H_ANVIL_BAL_AFTER_UNSTAKE wei"

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
phase_2b_pre_v170_external_unstake
phase_3_post_upgrade_state
phase_4_anvil_unstake_post_upgrade
phase_5_verify
phase_6_anvil_balance
phase_7_summary
phase_8_teardown
