#!/usr/bin/env bash
# investigate_100_pct_edge.sh — empirical verification of the piplabs/cosmos-sdk
# BeginRedelegation bug: 100% redelegate from an UNBONDED val with exactly one
# remaining delegation hits `validator_not_found` because Unbond calls
# RemoveValidator when shares hit zero, then getBeginInfo fails to look it up.
#
# Two probes on one fresh chain:
#   P1: on val-X1 (UNBONDED), redelegate 99% → expect SUCCESS (tokens move)
#   P2: on val-X2 (UNBONDED, different val), redelegate 100% → expect
#       silent fail (Failed to process redelegate | validator_not_found);
#       tokens unchanged despite CLI reporting success.
#
# Includes rpc1-node JWT race workaround: after start.sh, if rpc1 height stays
# at 0 past a deadline, restart rpc1-node to force JWT reload.

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
POST_UPGRADE=${POST_UPGRADE:-15}   # wait past upgrade + unbonding time
VSU_BLOCKS=${VSU_BLOCKS:-8}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[100pct]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[100pct]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[100pct]${C_RESET} FAIL %s\n" "$*"; }
note() { printf "${C_YELLOW}[100pct]${C_RESET} NOTE %s\n" "$*"; }

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

base64_pubkey_to_hex() { echo -n "$1" | base64 -d | xxd -p -c 66; }
meta_pubkey_hex() { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META" | xargs -I{} echo -n "{}" | base64 -d | xxd -p -c 66; }
meta_privkey()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }

# ---------------- Phase 0 — start fresh localnet w/ JWT workaround ----------------
phase_0_start() {
  log "Phase 0 — start fresh localnet"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    log "  cleaning up existing containers"
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -3)
    sleep 5
  fi
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)

  # rpc1 JWT race workaround
  log "  checking rpc1 sync (JWT race workaround)"
  local deadline h
  deadline=$(( $(date +%s) + 90 ))
  while :; do
    h=$(get_height)
    if [[ $h -gt 0 ]]; then
      log "  rpc1 height=$h — sync good"
      return
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      log "  rpc1 stuck at 0 — restarting rpc1-node to reload JWT"
      docker restart rpc1-node >/dev/null 2>&1
      sleep 15
      h=$(get_height)
      [[ $h -gt 0 ]] && { log "  rpc1 recovered, height=$h"; return; }
      fail "rpc1 did not recover after restart"
      exit 1
    fi
    sleep 3
  done
}

# ---------------- helpers for probe ----------------
get_val_info_by_moniker() {
  local moniker=$1
  curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" \
    | jq -c --arg m "$moniker" '.msg.validators[] | select(.description.moniker==$m) | {status, operator_address, tokens}'
}

val_exists() {
  # returns 0 if val still queryable, 1 if gone (REST returns empty / error)
  local op=$1 body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null)
  if [[ -n "$body" ]]; then
    local t
    t=$(jq -r '.msg.validator.tokens // empty' <<<"$body")
    [[ -n "$t" ]] && return 0
  fi
  return 1
}

# list pruned (UNBONDED status=1) monikers, sorted alpha
list_unbonded_monikers() {
  curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" \
    | jq -r '[.msg.validators[] | select(.status==1) | .description.moniker] | sort | .[]'
}

# ---------------- Phase 1 — wait past upgrade + unbonding ----------------
phase_1_wait() {
  local target=$((UPGRADE_HEIGHT + POST_UPGRADE))
  log "Phase 1 — wait block $target (upgrade+$POST_UPGRADE, unbonding settled)"
  local h
  h=$(wait_height "$target")
  log "  at block $h"
  local count
  count=$(list_unbonded_monikers | wc -l | tr -d ' ')
  log "  $count UNBONDED vals available"
}

# ---------------- do_redelegate ----------------
do_redelegate() {
  local src_moniker=$1 dst_moniker=$2 percent=$3  # percent = 99 or 100
  local src_pub src_priv dst_pub src_info dst_info src_tokens dst_tokens_pre
  src_pub=$(meta_pubkey_hex "$src_moniker")
  dst_pub=$(meta_pubkey_hex "$dst_moniker")
  src_priv=$(meta_privkey "$src_moniker")
  src_info=$(get_val_info_by_moniker "$src_moniker")
  dst_info=$(get_val_info_by_moniker "$dst_moniker")
  src_tokens=$(jq -r .tokens <<<"$src_info")
  dst_tokens_pre=$(jq -r .tokens <<<"$dst_info")

  local amount_stake amount_wei
  if [[ "$percent" == "100" ]]; then
    amount_stake="$src_tokens"
  else
    amount_stake=$(echo "$src_tokens * $percent / 100" | bc)
  fi
  amount_wei=$(echo "$amount_stake * 1000000000" | bc)

  log "  $src_moniker (${percent}% = $amount_stake stake = $amount_wei wei) -> $dst_moniker"
  log "  src status=$(jq -r .status <<<"$src_info"), tokens=$src_tokens"
  log "  dst pre-tokens=$dst_tokens_pre"

  local err_before ok_before
  err_before=$(docker logs rpc1-node 2>&1 | grep -c "Failed to process redelegate" || true)
  ok_before=$(docker logs rpc1-node 2>&1 | grep -c "RedelegateSuccess" || true)

  local h_before tx_out cli_rc tx_hash
  h_before=$(get_height)
  tx_out=$(PRIVATE_KEY="$src_priv" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$src_pub" --validator-dst-pubkey "$dst_pub" \
    --redelegate "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  cli_rc=$?
  tx_hash=$(grep -oE '0x[0-9a-f]{64}' <<<"$tx_out" | head -1)

  wait_height "$((h_before + VSU_BLOCKS))" >/dev/null

  local err_after ok_after src_info_post dst_info_post dst_tokens_post
  err_after=$(docker logs rpc1-node 2>&1 | grep -c "Failed to process redelegate" || true)
  ok_after=$(docker logs rpc1-node 2>&1 | grep -c "RedelegateSuccess" || true)
  src_info_post=$(get_val_info_by_moniker "$src_moniker")
  dst_info_post=$(get_val_info_by_moniker "$dst_moniker")
  dst_tokens_post=$(jq -r .tokens <<<"$dst_info_post")

  # Check if src was removed from store
  local src_op src_gone=0
  src_op=$(jq -r .operator_address <<<"$src_info")
  if ! val_exists "$src_op"; then
    src_gone=1
  fi

  local err_delta=$((err_after - err_before))

  log "  CLI rc=$cli_rc  tx=$tx_hash"
  log "  Failed_log_delta=$err_delta"
  log "  src post-info: $src_info_post   src_removed_from_store=$src_gone"
  log "  dst post-tokens=$dst_tokens_post   delta=$((dst_tokens_post - dst_tokens_pre))"

  # Classify outcome
  if [[ $cli_rc -ne 0 ]]; then
    echo "OUTCOME=CLI_ERROR"
  elif [[ $err_delta -gt 0 ]]; then
    echo "OUTCOME=COSMOS_REJECTED_SILENT_ROLLBACK"
  elif [[ "$dst_tokens_post" == "$dst_tokens_pre" ]]; then
    echo "OUTCOME=NO_EFFECT"
  else
    echo "OUTCOME=SUCCESS"
  fi
}

# ---------------- Phase 2 — probe A: 99% ----------------
P_A_RESULT=""
phase_2_99pct() {
  log "Phase 2 [probe A] — 99% redelegate from UNBONDED val"
  local unbonded
  unbonded=$(list_unbonded_monikers)
  local src dst
  src=$(head -1 <<<"$unbonded")
  dst="localnet-val-1"  # val-1 is reliably bonded
  log "  chose src=$src  dst=$dst"
  P_A_RESULT=$(do_redelegate "$src" "$dst" 99 | tail -1)
  log "  probe A => $P_A_RESULT"
}

# ---------------- Phase 3 — probe B: 100% ----------------
P_B_RESULT=""
phase_3_100pct() {
  log "Phase 3 [probe B] — 100% redelegate from a DIFFERENT UNBONDED val"
  local unbonded
  unbonded=$(list_unbonded_monikers)
  local src dst
  # Pick 2nd UNBONDED (1st was used for probe A, now has 99% drained)
  src=$(sed -n '2p' <<<"$unbonded")
  dst="localnet-val-2"
  log "  chose src=$src  dst=$dst"
  P_B_RESULT=$(do_redelegate "$src" "$dst" 100 | tail -1)
  log "  probe B => $P_B_RESULT"
}

# ---------------- Phase 4 — summary ----------------
phase_4_summary() {
  printf "\n========== 100pct EDGE INVESTIGATION SUMMARY ==========\n"
  printf "Probe A (99%% redelegate from UNBONDED): %s\n" "$P_A_RESULT"
  printf "Probe B (100%% redelegate from UNBONDED): %s\n" "$P_B_RESULT"
  printf "Expected per theory:\n"
  printf "  A => SUCCESS (tokens move, src stays in store)\n"
  printf "  B => COSMOS_REJECTED_SILENT_ROLLBACK (validator_not_found, rollback)\n"
  printf "======================================================\n"
}

phase_5_teardown() {
  if [[ $SKIP_TEARDOWN -eq 1 ]]; then
    log "Phase 5 — SKIP_TEARDOWN"
    return
  fi
  log "Phase 5 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

main() {
  phase_0_start
  phase_1_wait
  phase_2_99pct
  phase_3_100pct
  phase_4_summary
  phase_5_teardown
}

main "$@"
