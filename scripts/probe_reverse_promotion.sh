#!/usr/bin/env bash
# probe_reverse_promotion.sh — B1 scenario: external delegator (Anvil)
# delegates a large stake to a pruned UNBONDED validator post-upgrade,
# overtaking the current rank-16's tokens, causing the pruned val to be
# promoted back to BONDED and displacing the current rank-16.
#
# Tests post-upgrade dynamics: the validator set is NOT permanently fixed
# at the upgrade-time top-16. Any pruned val that accumulates enough stake
# climbs back, and any BONDED val that falls below the new boundary drops
# out. MaxValidators=16 cap stays.
#
# Expected:
#   - val-17 (pruned, single-del operator only) before delegation: status=1 UNBONDED
#   - After Anvil delegates ~1.2x rank-16's tokens: val-17 status=3 BONDED in top-16
#   - Current rank-16 (pre-delegation) demoted to status=1 UNBONDED
#   - BONDED count stays at 16 (cap unchanged)
#   - Chain progresses (no halt)
#
# Setup:
#   Fresh localnet, N=20, upgrade fires at block 50 prunes rank 17-20 to UNBONDED.
#   Reuses verify_upgrade_new_val.sh's rank-16 dynamic detection pattern.
#
# Usage:
#   ./scripts/probe_reverse_promotion.sh                  # full run
#   SKIP_TEARDOWN=1 ./scripts/probe_reverse_promotion.sh  # keep cluster
#
# Env: STORY_BIN, CHAIN_ID, ANVIL_PK, UPGRADE_HEIGHT, STAKE_MARGIN (defaults).

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
STAKE_MARGIN=${STAKE_MARGIN:-12}    # numerator/10 → stake = rank16_tokens * 1.2
WEI_PER_STAKE=${WEI_PER_STAKE:-1000000000}
NEW_MAX=${NEW_MAX:-16}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
TARGET_MONIKER="localnet-val-17"
VSU_BLOCKS=${VSU_BLOCKS:-10}        # blocks after delegation tx for promotion to take effect

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[promote]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[promote]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[promote]${C_RESET} FAIL %s\n" "$*"; exit 1; }

get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}
wait_height() { local target=$1 h; while :; do h=$(get_height); [[ $h -ge $target ]] && { echo "$h"; return; }; sleep 2; done; }
val_field() {
  curl -fsS "http://localhost:1317/staking/validators/${1}" 2>/dev/null \
    | jq -r ".msg.validator.${2} // \"GONE\""
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

# ---------------- Phase 1 — wait past upgrade, capture baseline ----------------
TARGET_OP=""; TARGET_TOKENS_PRE=""
RANK16_OP_PRE=""; RANK16_TOKENS_PRE=""
STAKE_WEI=""
phase_1_baseline() {
  log "Phase 1 — wait past upgrade ($((UPGRADE_HEIGHT + 15))), capture baseline"
  wait_height "$((UPGRADE_HEIGHT + 15))" >/dev/null
  log "  chain at $(get_height)"

  # Sanity: target val is UNBONDED post-upgrade
  TARGET_OP=$(meta_op_evm "$TARGET_MONIKER")
  local status; status=$(val_field "$TARGET_OP" status)
  TARGET_TOKENS_PRE=$(val_field "$TARGET_OP" tokens)
  log "  $TARGET_MONIKER op=$TARGET_OP status=$status tokens=$TARGET_TOKENS_PRE"
  [[ "$status" == "1" ]] || fail "$TARGET_MONIKER expected UNBONDED (status=1) post-upgrade, got $status"

  # Find current rank-16 (the BONDED with smallest tokens)
  local vals count
  vals=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100")
  count=$(jq '.msg.validators | length' <<<"$vals")
  [[ "$count" == "$NEW_MAX" ]] || fail "bonded=$count (expected $NEW_MAX post-upgrade)"

  RANK16_OP_PRE=$(jq -r '.msg.validators | sort_by(-(.tokens|tonumber)) | .[15].operator_address' <<<"$vals")
  RANK16_TOKENS_PRE=$(jq -r '.msg.validators | sort_by(-(.tokens|tonumber)) | .[15].tokens' <<<"$vals")
  log "  current rank-16 op=$RANK16_OP_PRE tokens=$RANK16_TOKENS_PRE"

  # stake_wei = rank16_tokens * STAKE_MARGIN/10 * WEI_PER_STAKE (use bc; bash ints overflow)
  STAKE_WEI=$(echo "$RANK16_TOKENS_PRE * $STAKE_MARGIN / 10 * $WEI_PER_STAKE" | bc)
  local stake_ip; stake_ip=$(echo "$STAKE_WEI / 1000000000000000000" | bc)
  log "  Anvil will delegate $STAKE_WEI wei (~$stake_ip IP, ${STAKE_MARGIN}0% of rank-16 tokens) to $TARGET_MONIKER"
  pass "baseline captured"
}

# ---------------- Phase 2 — Anvil delegates massive stake to target ----------------
DELEGATE_TX=""; DELEGATE_RC=""
phase_2_anvil_delegate() {
  log "Phase 2 — Anvil delegates massive stake to $TARGET_MONIKER"
  local pub; pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  local out
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
    --validator-pubkey "$pub" --stake "$STAKE_WEI" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  DELEGATE_RC=$?
  DELEGATE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
  log "  tx=$DELEGATE_TX rc=$DELEGATE_RC"
  [[ "$DELEGATE_RC" == "0" ]] || fail "anvil delegate rc=$DELEGATE_RC"
}

# ---------------- Phase 3 — wait for validator-set update + verify promotion ----------------
phase_3_verify_promotion() {
  log "Phase 3 — wait $VSU_BLOCKS blocks for staking.EndBlock to apply VSU"
  wait_height "$(( $(get_height) + VSU_BLOCKS ))" >/dev/null

  # Target should now be BONDED
  local target_status_post target_tokens_post
  target_status_post=$(val_field "$TARGET_OP" status)
  target_tokens_post=$(val_field "$TARGET_OP" tokens)
  log "  $TARGET_MONIKER post-delegation: status=$target_status_post tokens=$target_tokens_post"
  [[ "$target_status_post" == "3" ]] || fail "expected $TARGET_MONIKER promoted to BONDED (status=3), got $target_status_post"

  # Original rank-16 should be UNBONDED (demoted)
  local r16_status_post r16_tokens_post
  r16_status_post=$(val_field "$RANK16_OP_PRE" status)
  r16_tokens_post=$(val_field "$RANK16_OP_PRE" tokens)
  log "  pre-delegation rank-16 ($RANK16_OP_PRE) post-delegation: status=$r16_status_post tokens=$r16_tokens_post"
  [[ "$r16_status_post" == "1" ]] || fail "expected pre-delegation rank-16 demoted to UNBONDED (status=1), got $r16_status_post"

  # Bonded count must stay at NEW_MAX
  local bonded_count
  bonded_count=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" \
    | jq '.msg.validators | length')
  log "  bonded count post-delegation: $bonded_count"
  [[ "$bonded_count" == "$NEW_MAX" ]] || fail "bonded=$bonded_count (expected $NEW_MAX, MaxValidators cap broken)"

  # Target now in top-16 by tokens
  local in_top16
  in_top16=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" \
    | jq --arg op "$TARGET_OP" '[.msg.validators[] | select(.operator_address==$op)] | length')
  [[ "$in_top16" == "1" ]] || fail "$TARGET_MONIKER not in BONDED top-16 set"

  # Chain still progressing
  local h=$(get_height); wait_height "$((h + 3))" >/dev/null
  pass "target promoted, original rank-16 demoted, bonded count=$NEW_MAX, chain healthy"
}

# ---------------- Phase 4 — summary ----------------
phase_4_summary() {
  printf "\n========== REVERSE PROMOTION PROBE CONCLUSIONS ==========\n"
  printf "Target: %s op=%s\n" "$TARGET_MONIKER" "$TARGET_OP"
  printf "  Pre-delegation: status=1 UNBONDED tokens=%s\n" "$TARGET_TOKENS_PRE"
  printf "  Anvil delegated: %s wei\n" "$STAKE_WEI"
  printf "  CLI rc=%s tx=%s\n" "$DELEGATE_RC" "$DELEGATE_TX"
  printf "  Post-delegation: status=%s tokens=%s\n" "$(val_field "$TARGET_OP" status)" "$(val_field "$TARGET_OP" tokens)"
  printf "Pre-delegation rank-16: %s\n" "$RANK16_OP_PRE"
  printf "  Pre-delegation: status=3 BONDED tokens=%s\n" "$RANK16_TOKENS_PRE"
  printf "  Post-delegation: status=%s tokens=%s\n" "$(val_field "$RANK16_OP_PRE" status)" "$(val_field "$RANK16_OP_PRE" tokens)"
  printf "Final chain height: %s\n" "$(get_height)"
  printf "=========================================================\n"
}

phase_5_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 5 — SKIP_TEARDOWN"; return; fi
  log "Phase 5 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline
phase_2_anvil_delegate
phase_3_verify_promotion
phase_4_summary
phase_5_teardown
