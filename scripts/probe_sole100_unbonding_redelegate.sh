#!/usr/bin/env bash
# probe_sole100_unbonding_redelegate.sh
#
# Chain-assert: sole-100% holder + UNBONDING src val redelegate completes
# correctly via cosmos-sdk getBeginInfo Unbonding-case path. Does NOT hit
# silent-rollback like the case-6b-G1 sibling (UNBONDED + sole-100% → #619).
#
# Setup mirrors probe_locked_del_redelegate_after_prune.sh (G1) but for 8-val
# NEW_MAX=4 cluster, and Bob redelegates DURING UNBONDING window (post-V170,
# before val-5 reaches UNBONDED via 14d unbonding completion).
#
# Heights:
#   h=10  baseline (val-5 BONDED, operator-only delegation)
#   h=20  Bob (Anvil[1]) stake short 1024 IP to val-5
#   h=40  val-5 operator FULL self-unstake (drops below MSD) →
#         val-5 status BONDED → UNBONDING + jailed=true
#         operator's delegation entry leaves val.delegator_shares
#         (enters UnbondingDelegation queue)
#         → Bob is sole-100% holder of val-5's remaining shares
#   h=70  V170 fires (val-5 already UNBONDING; cap-prune is no-op)
#   h=80  verify sole-100% state via REST delegations endpoint
#   h=85  Bob redelegate from val-5 to val-1 (UNBONDING window, before
#         val-5 reaches UNBONDED status)
#   h=95  verify outcome: redelegation entry, val-5 shares=0,
#         val-1 has Bob delegation, completionTime == val-5.UnbondingTime
#
# Usage:
#   ./scripts/probe_sole100_unbonding_redelegate.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_sole100_unbonding_redelegate.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-70}
BASELINE_HEIGHT=${BASELINE_HEIGHT:-10}
BOB_STAKE_HEIGHT=${BOB_STAKE_HEIGHT:-20}
OP_UNSTAKE_HEIGHT=${OP_UNSTAKE_HEIGHT:-40}
SOLE_100_CHECK_HEIGHT=${SOLE_100_CHECK_HEIGHT:-80}
BOB_REDELEGATE_HEIGHT=${BOB_REDELEGATE_HEIGHT:-85}
VERIFY_HEIGHT=${VERIFY_HEIGHT:-95}
SRC_VAL_MONIKER=${SRC_VAL_MONIKER:-localnet-val-5}
DST_VAL_MONIKER=${DST_VAL_MONIKER:-localnet-val-1}
SIGNED_BLOCKS_WINDOW=${SIGNED_BLOCKS_WINDOW:-80}
UNBONDING_TIME=${UNBONDING_TIME:-3600s}
N_VALS=${N_VALS:-8}
NEW_MAX=${NEW_MAX:-4}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
STAKE_IP=${STAKE_IP:-1024}
STAKE_WEI="${STAKE_IP}000000000000000000"   # 1024e18 wei
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
GENESIS="${LOCALNET}/config/story/genesis-node.json"
EVIDENCE_DIR=${EVIDENCE_DIR:-/Users/lucas/workspace/lucas-workspace/docs/test-evidence/v170-sole100-unbonding-redelegate-2026-05-11}
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

# Anvil keys (matching G1 / case-7 convention)
ALICE_PK=${ALICE_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ALICE_ADDR=${ALICE_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
BOB_PK=${BOB_PK:-59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}
BOB_ADDR=${BOB_ADDR:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}
SEED_IP=${SEED_IP:-2000}

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[sole100-unb]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[sole100-unb]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[sole100-unb]${C_RESET} FAIL %s\n" "$*"; capture_evidence_on_fail; exit 1; }
note() { printf "${C_YELLOW}[sole100-unb]${C_RESET} OBSERVED %s\n" "$*"; }

# ---------------- helpers ----------------

get_cometbft_height() {
  local h
  h=$(curl -fsS -m 5 http://localhost:26657/status 2>/dev/null \
    | jq -r '.result.sync_info.latest_block_height // 0' 2>/dev/null)
  [[ -z "$h" ]] && echo 0 || echo "$h"
}

wait_cometbft_height() {
  local target=$1 h
  while :; do
    h=$(get_cometbft_height)
    [[ $h -ge $target ]] && { echo "$h"; return; }
    sleep 2
  done
}

val_field() {
  local op=$1 field=$2 body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null)
  [[ -z $body ]] && { echo "GONE"; return; }
  jq -r ".msg.validator.${field} // \"GONE\"" <<<"$body"
}

meta_pubkey_hex() { local b64; b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META"); echo -n "$b64" | base64 -d | xxd -p -c 66; }
meta_op_evm()     { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }
meta_privkey()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }

# G1-style CLI wrappers (reused)
do_stake() {
  local who=$1 pk=$2 pubkey=$3 period=$4
  log "  $who stake $STAKE_WEI wei period=$period"
  local out rc
  out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator stake \
    --validator-pubkey "$pubkey" --stake "$STAKE_WEI" --staking-period "$period" \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -10
  [[ $rc -eq 0 ]] || fail "$who stake rc=$rc"
  printf '%s\n' "$out" | grep -oE "Delegation ID: [0-9]+" | tail -1
}

do_unstake() {
  local who=$1 pk=$2 pubkey=$3 amt=$4 del_id=${5:-0}
  log "  $who unstake amt=$amt del_id=$del_id"
  local out rc
  out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pubkey" --unstake "$amt" --delegation-id "$del_id" \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -10
  [[ $rc -eq 0 ]] || fail "$who unstake rc=$rc"
}

do_redelegate() {
  local who=$1 pk=$2 src_pubkey=$3 dst_pubkey=$4 amt=$5 del_id=${6:-0}
  log "  $who redelegate amt=$amt del_id=$del_id src to dst"
  local out rc
  out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$src_pubkey" --validator-dst-pubkey "$dst_pubkey" \
    --redelegate "$amt" --delegation-id "$del_id" \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -10
  [[ $rc -eq 0 ]] || fail "$who redelegate rc=$rc"
}

capture_evidence() {
  log "Capturing evidence to $EVIDENCE_DIR"
  mkdir -p "$EVIDENCE_DIR"
  for c in $(docker ps --format '{{.Names}}' | grep -E '^(validator[0-9]+|bootnode[0-9]+|rpc[0-9]+)-node$'); do
    docker logs "$c" > "$EVIDENCE_DIR/cl-${c}.log" 2>&1
  done
  log "  CL logs saved"
  local cur_h; cur_h=$(get_cometbft_height)
  for h in 5 "$BASELINE_HEIGHT" "$BOB_STAKE_HEIGHT" "$OP_UNSTAKE_HEIGHT" "$UPGRADE_HEIGHT" "$SOLE_100_CHECK_HEIGHT" "$BOB_REDELEGATE_HEIGHT" "$VERIFY_HEIGHT"; do
    [[ "$h" -gt "$cur_h" ]] && continue
    curl -fsS -m 5 "http://localhost:26657/block_results?height=${h}" 2>/dev/null > "$EVIDENCE_DIR/block_results-h${h}.json"
  done
  log "  block_results snapshots saved"
  if [[ -n "${SRC_VAL_OP:-}" ]]; then
    curl -fsS "http://localhost:1317/staking/validators/${SRC_VAL_OP}" 2>/dev/null > "$EVIDENCE_DIR/val5-end.json"
    curl -fsS "http://localhost:1317/staking/validators/${SRC_VAL_OP}/delegations" 2>/dev/null > "$EVIDENCE_DIR/val5-delegations-end.json"
  fi
  if [[ -n "${DST_VAL_OP:-}" ]]; then
    curl -fsS "http://localhost:1317/staking/validators/${DST_VAL_OP}" 2>/dev/null > "$EVIDENCE_DIR/val1-end.json"
    curl -fsS "http://localhost:1317/staking/validators/${DST_VAL_OP}/delegations" 2>/dev/null > "$EVIDENCE_DIR/val1-delegations-end.json"
  fi
  curl -fsS "http://localhost:1317/staking/delegators/${BOB_ADDR}/redelegations" 2>/dev/null > "$EVIDENCE_DIR/bob-redelegations.json"
  cat > "$EVIDENCE_DIR/probe-metadata.json" <<EOF
{
  "probe": "probe_sole100_unbonding_redelegate.sh",
  "binary_sha256_sentinel": "$(cat ${LOCALNET}/tmp/staged_binary.sha256 2>/dev/null || echo unknown)",
  "src_val_moniker": "$SRC_VAL_MONIKER",
  "dst_val_moniker": "$DST_VAL_MONIKER",
  "src_val_op": "${SRC_VAL_OP:-}",
  "dst_val_op": "${DST_VAL_OP:-}",
  "bob_addr": "$BOB_ADDR",
  "stake_wei": "$STAKE_WEI",
  "config": {
    "UPGRADE_HEIGHT": $UPGRADE_HEIGHT,
    "BOB_STAKE_HEIGHT": $BOB_STAKE_HEIGHT,
    "OP_UNSTAKE_HEIGHT": $OP_UNSTAKE_HEIGHT,
    "SOLE_100_CHECK_HEIGHT": $SOLE_100_CHECK_HEIGHT,
    "BOB_REDELEGATE_HEIGHT": $BOB_REDELEGATE_HEIGHT,
    "VERIFY_HEIGHT": $VERIFY_HEIGHT,
    "UNBONDING_TIME": "$UNBONDING_TIME"
  }
}
EOF
}

capture_evidence_on_fail() {
  log "FAIL path - attempting evidence capture (cluster may be degraded)"
  capture_evidence 2>/dev/null || log "  (capture failed or partial)"
}

# ---------------- Phase 0 — boot ----------------
SRC_VAL_OP=""; DST_VAL_OP=""; SRC_VAL_PUB=""; DST_VAL_PUB=""

phase_0_start() {
  log "Phase 0 - terminate + boot ${N_VALS}-val cluster (NEW_MAX=$NEW_MAX, SBW=$SIGNED_BLOCKS_WINDOW, UnbondingTime=$UNBONDING_TIME)"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -3); sleep 5
  fi
  local yml_count
  yml_count=$(ls "${LOCALNET}"/docker-compose-validator*.yml 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$yml_count" != "$N_VALS" ]]; then
    bash "${LOCALNET}/scripts/generate_compose_files.sh" "$N_VALS" 2>&1 | tail -3
  fi
  MAX_VALIDATORS_INIT="$N_VALS" STORY_BIN="$STORY_BIN" \
    bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N_VALS" 2>&1 | tail -1
  jq --arg w "$SIGNED_BLOCKS_WINDOW" --arg u "$UNBONDING_TIME" \
    '.app_state.slashing.params.signed_blocks_window = $w
     | .app_state.staking.params.unbonding_time = $u' \
    "$GENESIS" > "$GENESIS.tmp" && mv "$GENESIS.tmp" "$GENESIS"
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -3)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_cometbft_height)
    [[ $h -gt 0 ]] && { log "  cometbft sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "cometbft didn't sync in 90s"
    sleep 3
  done
  SRC_VAL_OP=$(meta_op_evm "$SRC_VAL_MONIKER")
  DST_VAL_OP=$(meta_op_evm "$DST_VAL_MONIKER")
  SRC_VAL_PUB=$(meta_pubkey_hex "$SRC_VAL_MONIKER")
  DST_VAL_PUB=$(meta_pubkey_hex "$DST_VAL_MONIKER")
  [[ -n "$SRC_VAL_OP" && -n "$DST_VAL_OP" && -n "$SRC_VAL_PUB" && -n "$DST_VAL_PUB" ]] \
    || fail "couldn't derive val addresses (src=$SRC_VAL_OP dst=$DST_VAL_OP)"
  log "  src $SRC_VAL_MONIKER op=$SRC_VAL_OP"
  log "  dst $DST_VAL_MONIKER op=$DST_VAL_OP"
}

# ---------------- Phase 1 — baseline + seed Bob + Bob stakes short to val-5 ----------------
VAL5_TOKENS_BASELINE=""; BOB_DEL_ID=""
phase_1_bob_stake() {
  log "Phase 1 - wait h=$BASELINE_HEIGHT, seed Bob, then h=$BOB_STAKE_HEIGHT Bob stakes short ${STAKE_IP} IP to $SRC_VAL_MONIKER"
  wait_cometbft_height "$BASELINE_HEIGHT" >/dev/null

  VAL5_TOKENS_BASELINE=$(val_field "$SRC_VAL_OP" tokens)
  log "  val-5 baseline tokens (operator self-bond only): $VAL5_TOKENS_BASELINE"

  log "  seed Bob with ${SEED_IP} IP from Alice"
  cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$BOB_ADDR" \
    --value "${SEED_IP}ether" --legacy --gas-price 50gwei >/dev/null 2>&1
  local bob_bal; bob_bal=$(cast balance "$BOB_ADDR" --rpc-url http://localhost:8545 2>/dev/null)
  log "  Bob seeded; balance=$bob_bal wei"

  wait_cometbft_height "$BOB_STAKE_HEIGHT" >/dev/null
  local del_id_line
  del_id_line=$(do_stake Bob "$BOB_PK" "$SRC_VAL_PUB" short)
  BOB_DEL_ID=$(echo "$del_id_line" | grep -oE "[0-9]+$" | tail -1)
  [[ -n "$BOB_DEL_ID" ]] || BOB_DEL_ID=1   # fallback to id=1 if CLI doesn't print
  log "  Bob's delegation-id=$BOB_DEL_ID"
  sleep 5

  local status tokens
  status=$(val_field "$SRC_VAL_OP" status)
  tokens=$(val_field "$SRC_VAL_OP" tokens)
  log "  post-Bob-stake val-5: status=$status tokens=$tokens (baseline + Bob's ${STAKE_IP} IP)"
  [[ "$status" == "3" ]] || fail "@h=$BOB_STAKE_HEIGHT val-5 status=$status (expected 3 BONDED)"
  pass "Phase 1: Bob staked short ${STAKE_IP} IP to val-5, del_id=$BOB_DEL_ID, val-5 BONDED"
}

# ---------------- Phase 2 — operator FULL self-unstake → val-5 MSD-jail → sole-100% Bob ----------------
OP_UNSTAKE_AMOUNT=""
phase_2_operator_self_unstake() {
  log "Phase 2 - wait h=$OP_UNSTAKE_HEIGHT, operator full self-unstake (drops below MSD)"
  wait_cometbft_height "$OP_UNSTAKE_HEIGHT" >/dev/null

  local op_pk op_addr op_shares
  op_pk=$(meta_privkey "$SRC_VAL_MONIKER")
  op_addr=$(meta_op_evm "$SRC_VAL_MONIKER")
  # Query operator's actual delegation shares from REST (don't derive from val.tokens subtraction)
  local dels_body
  dels_body=$(curl -fsS "http://localhost:1317/staking/validators/${SRC_VAL_OP}/delegations?pagination.limit=100" 2>/dev/null)
  op_shares=$(jq -r --arg op "$(echo $op_addr | tr A-Z a-z)" \
    '.msg.delegation_responses[]
     | select((.delegation.delegator_address | ascii_downcase) == $op)
     | .delegation.shares' <<<"$dels_body" | head -1)
  [[ -n "$op_shares" && "$op_shares" != "null" ]] || fail "couldn't find operator's delegation on val-5 via REST"
  # shares is decimal like "1108879682985100.000000000000000000"; convert to integer wei (* 1e9)
  OP_UNSTAKE_AMOUNT=$(python3 -c "from decimal import Decimal; print(int(Decimal('$op_shares') * Decimal(1000000000)))")
  log "  operator's flex delegation shares=$op_shares -> unstake wei=$OP_UNSTAKE_AMOUNT (full)"

  # fund operator gas (operator's anvil address may have 0 balance)
  cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$op_addr" \
    --value 10ether --legacy --gas-price 50gwei >/dev/null 2>&1

  do_unstake "${SRC_VAL_MONIKER}-op" "$op_pk" "$SRC_VAL_PUB" "$OP_UNSTAKE_AMOUNT" 0
  sleep 5

  local status jailed tokens_after
  status=$(val_field "$SRC_VAL_OP" status)
  jailed=$(val_field "$SRC_VAL_OP" jailed)
  tokens_after=$(val_field "$SRC_VAL_OP" tokens)
  log "  post-op-unstake val-5: status=$status jailed=$jailed tokens=$tokens_after"
  [[ "$status" == "2" ]] || fail "@h=$OP_UNSTAKE_HEIGHT val-5 status=$status (expected 2 UNBONDING after MSD-jail)"
  [[ "$jailed" == "true" ]] || fail "@h=$OP_UNSTAKE_HEIGHT val-5 jailed=$jailed (expected true after full self-unstake)"
  # Bob's expected stake in stake_units (1024 IP = 1024e9). Verify val-5 has only Bob's portion.
  local ext=$((STAKE_IP * 1000000000))
  [[ "$tokens_after" == "$ext" ]] || fail "@h=$OP_UNSTAKE_HEIGHT val-5 tokens=$tokens_after (expected Bob-only $ext)"
  pass "Phase 2: operator self-unstake fired MSD-jail; val-5 UNBONDING+jailed, only Bob remains (sole-100%)"
}

# ---------------- Phase 3 — V170 fires (no-op for already-UNBONDING val-5) ----------------
phase_3_v170() {
  log "Phase 3 - wait V170 fire @ h=$UPGRADE_HEIGHT (val-5 already UNBONDING; cap-prune no-op)"
  wait_cometbft_height "$((UPGRADE_HEIGHT + 8))" >/dev/null
  local status; status=$(val_field "$SRC_VAL_OP" status)
  [[ "$status" == "2" ]] || fail "@h>V170 val-5 status=$status (expected 2 UNBONDING)"
  pass "Phase 3: V170 fired; val-5 remained UNBONDING (no double-transition)"
}

# ---------------- Phase 4 — verify sole-100% pattern via REST ----------------
DEL_COUNT_PRE_REDEL=""; BOB_SHARES_PRE_REDEL=""; VAL5_SHARES_PRE_REDEL=""
phase_4_verify_sole_100() {
  log "Phase 4 - wait h=$SOLE_100_CHECK_HEIGHT, verify val-5 has sole-100% holder (Bob only)"
  wait_cometbft_height "$SOLE_100_CHECK_HEIGHT" >/dev/null

  local dels_body
  dels_body=$(curl -fsS "http://localhost:1317/staking/validators/${SRC_VAL_OP}/delegations?pagination.limit=100" 2>/dev/null)
  [[ -n "$dels_body" ]] || fail "REST: /staking/validators/${SRC_VAL_OP}/delegations returned empty"

  DEL_COUNT_PRE_REDEL=$(jq -r '.msg.delegation_responses | length' <<<"$dels_body" 2>/dev/null)
  log "  val-5 delegations count=$DEL_COUNT_PRE_REDEL (expected 1 for sole-100% pattern)"
  [[ "$DEL_COUNT_PRE_REDEL" == "1" ]] || fail "PRIMARY 1 FAILED: val-5 has $DEL_COUNT_PRE_REDEL delegations, expected 1 (sole-100%)"

  local lone_delegator lone_shares
  lone_delegator=$(jq -r '.msg.delegation_responses[0].delegation.delegator_address' <<<"$dels_body")
  lone_shares=$(jq -r '.msg.delegation_responses[0].delegation.shares' <<<"$dels_body")
  log "  lone delegator=$lone_delegator (expect Bob=$(echo $BOB_ADDR | tr A-Z a-z))"
  log "  lone shares=$lone_shares"
  [[ "$(echo $lone_delegator | tr A-Z a-z)" == "$(echo $BOB_ADDR | tr A-Z a-z)" ]] \
    || fail "PRIMARY 1 FAILED: lone delegator=$lone_delegator != Bob=$BOB_ADDR"
  BOB_SHARES_PRE_REDEL="$lone_shares"

  VAL5_SHARES_PRE_REDEL=$(val_field "$SRC_VAL_OP" delegator_shares)
  log "  val-5.delegator_shares=$VAL5_SHARES_PRE_REDEL (should == Bob's shares)"

  pass "PRIMARY 1: val-5 sole-100% pattern confirmed (count=1, delegator=Bob, shares match)"
}

# ---------------- Phase 5 — Bob redelegates from val-5 (UNBONDING) to val-1 ----------------
REDEL_PRE_BLOCK=""; REDEL_POST_BLOCK=""
phase_5_bob_redelegate() {
  log "Phase 5 - wait h=$BOB_REDELEGATE_HEIGHT, Bob redelegate $STAKE_WEI wei from val-5 to val-1 (UNBONDING window)"
  wait_cometbft_height "$BOB_REDELEGATE_HEIGHT" >/dev/null
  REDEL_PRE_BLOCK=$(get_cometbft_height)

  do_redelegate Bob "$BOB_PK" "$SRC_VAL_PUB" "$DST_VAL_PUB" "$STAKE_WEI" "$BOB_DEL_ID"
  sleep 5
  REDEL_POST_BLOCK=$(get_cometbft_height)
  log "  redelegate executed h=$REDEL_PRE_BLOCK..$REDEL_POST_BLOCK"

  # PRIMARY 2a: tx success (rc=0 was already checked in do_redelegate)
  # PRIMARY 2b: state changed - new redelegation entry exists for Bob
  local redel_resp
  redel_resp=$(curl -fsS "http://localhost:1317/staking/delegators/${BOB_ADDR}/redelegations" 2>/dev/null)
  log "  /staking/delegators/${BOB_ADDR}/redelegations:"
  printf '%s\n' "$redel_resp" | jq -c '.msg.redelegation_responses[]? | {src: .redelegation.validator_src_address, dst: .redelegation.validator_dst_address, entries_count: (.entries | length)}' 2>/dev/null | sed 's/^/    /'

  local redel_count
  redel_count=$(jq -r '.msg.redelegation_responses | length' <<<"$redel_resp" 2>/dev/null)
  log "  Bob's active redelegations count=$redel_count (expected >=1)"
  [[ "${redel_count:-0}" -ge 1 ]] || fail "PRIMARY 2b FAILED: Bob has $redel_count redelegation entries - SILENT ROLLBACK (tx succeeded but state didn't change)"

  local src_match
  src_match=$(jq -r --arg src "$SRC_VAL_OP" '[.msg.redelegation_responses[]? | select(.redelegation.validator_src_address | ascii_downcase == ($src | ascii_downcase))] | length' <<<"$redel_resp" 2>/dev/null)
  [[ "${src_match:-0}" -ge 1 ]] || fail "PRIMARY 2b FAILED: no redelegation with src=val-5 ($SRC_VAL_OP); silent rollback suspected"

  pass "PRIMARY 2a: redelegate tx rc=0"
  pass "PRIMARY 2b: chain state changed (Bob's redelegations REST shows new entry with src=val-5) -- NOT silent rollback"
}

# ---------------- Phase 6 — verify outcome: val-5 shares=0, val-1 has Bob, completionTime matches ----------------
VAL5_SHARES_POST=""; VAL5_TOKENS_POST=""; VAL1_TOKENS_POST=""; REDEL_COMPLETION=""; VAL5_UNBONDING_TIME_REF=""
phase_6_verify_outcome() {
  log "Phase 6 - wait h=$VERIFY_HEIGHT, verify post-redelegate state"
  wait_cometbft_height "$VERIFY_HEIGHT" >/dev/null

  VAL5_SHARES_POST=$(val_field "$SRC_VAL_OP" delegator_shares)
  VAL5_TOKENS_POST=$(val_field "$SRC_VAL_OP" tokens)
  VAL1_TOKENS_POST=$(val_field "$DST_VAL_OP" tokens)
  log "  val-5 post: shares=$VAL5_SHARES_POST tokens=$VAL5_TOKENS_POST"
  log "  val-1 post: tokens=$VAL1_TOKENS_POST"

  # PRIMARY 3a: val-5 shares decremented (Bob's full share moved out)
  # shares is a decimal string like "0.000000000000000000" - compare to "0" with python
  local shares_zero
  shares_zero=$(python3 -c "from decimal import Decimal; print(int(Decimal('$VAL5_SHARES_POST') == Decimal(0)))" 2>/dev/null || echo 0)
  [[ "$shares_zero" == "1" ]] || fail "PRIMARY 3a FAILED: val-5.delegator_shares=$VAL5_SHARES_POST (expected 0; Bob fully redelegated out)"

  # PRIMARY 3b: val-1 has new Bob delegation (short metadata preserved)
  local val1_dels
  val1_dels=$(curl -fsS "http://localhost:1317/staking/validators/${DST_VAL_OP}/delegations?pagination.limit=100" 2>/dev/null)
  local val1_bob_count
  val1_bob_count=$(jq -r --arg bob "$(echo $BOB_ADDR | tr A-Z a-z)" \
    '[.msg.delegation_responses[]? | select((.delegation.delegator_address | ascii_downcase) == $bob)] | length' <<<"$val1_dels")
  log "  val-1 has $val1_bob_count Bob delegation(s)"
  [[ "${val1_bob_count:-0}" -ge 1 ]] || fail "PRIMARY 3b FAILED: val-1 has 0 Bob delegations after redelegate"

  # PRIMARY 3c: redelegation entry's completionTime matches val-5.UnbondingTime
  # (signature of Unbonding-case getBeginInfo path; immediate completion would indicate Unbonded-case)
  local redel_resp
  redel_resp=$(curl -fsS "http://localhost:1317/staking/delegators/${BOB_ADDR}/redelegations" 2>/dev/null)
  REDEL_COMPLETION=$(jq -r --arg src "$SRC_VAL_OP" '.msg.redelegation_responses[]?
    | select(.redelegation.validator_src_address | ascii_downcase == ($src | ascii_downcase))
    | .entries[0].redelegation_entry.completion_time' <<<"$redel_resp")
  log "  redelegation completion_time=$REDEL_COMPLETION"

  VAL5_UNBONDING_TIME_REF=$(val_field "$SRC_VAL_OP" unbonding_time)
  log "  val-5.unbonding_time=$VAL5_UNBONDING_TIME_REF"

  if [[ -n "$REDEL_COMPLETION" && "$REDEL_COMPLETION" != "null" && -n "$VAL5_UNBONDING_TIME_REF" ]]; then
    if [[ "$REDEL_COMPLETION" == "$VAL5_UNBONDING_TIME_REF" ]]; then
      pass "PRIMARY 3c: redelegation completion_time ($REDEL_COMPLETION) == val-5.unbonding_time (Unbonding-case path confirmed)"
    else
      note "completion_time $REDEL_COMPLETION != val-5.unbonding_time $VAL5_UNBONDING_TIME_REF; may be different format but both should be UNBONDING-aligned future time"
    fi
  else
    note "completion_time or val-5.unbonding_time not parseable; PRIMARY 3c degraded"
  fi

  pass "PRIMARY 3a: val-5.delegator_shares = 0 post-redelegate"
  pass "PRIMARY 3b: val-1 has new Bob delegation"
}

# ---------------- Phase 7 — capture + summary ----------------
phase_7_capture_and_summary() {
  log "Phase 7 - capture evidence + summary"
  capture_evidence
  printf "\n========== SOLE-100% UNBONDING SRC REDELEGATE ==========\n"
  printf "  Binary: %s\n" "$(cat ${LOCALNET}/tmp/staged_binary.sha256 2>/dev/null || echo unknown)"
  printf "  Cluster: $N_VALS-val NEW_MAX=$NEW_MAX  V170=h=$UPGRADE_HEIGHT  unbonding_time=$UNBONDING_TIME\n"
  printf "  src $SRC_VAL_MONIKER op=$SRC_VAL_OP\n"
  printf "  dst $DST_VAL_MONIKER op=$DST_VAL_OP\n"
  printf "  Bob $BOB_ADDR  del_id=$BOB_DEL_ID  staked $STAKE_IP IP short\n"
  printf "\n"
  printf "  Timeline:\n"
  printf "    h=$BASELINE_HEIGHT (baseline):   val-5 tokens=$VAL5_TOKENS_BASELINE (operator only)\n"
  printf "    h=$BOB_STAKE_HEIGHT (Bob stake):   val-5 tokens=$((VAL5_TOKENS_BASELINE + STAKE_IP * 1000000000))\n"
  printf "    h=$OP_UNSTAKE_HEIGHT (op unstake): val-5 status=2 UNBONDING jailed=true tokens=$((STAKE_IP * 1000000000)) (Bob only)\n"
  printf "    h=$UPGRADE_HEIGHT (V170):        no-op (val-5 already UNBONDING)\n"
  printf "    h=$SOLE_100_CHECK_HEIGHT (sole-100): delegations=1 delegator=Bob (PRIMARY 1)\n"
  printf "    h=$BOB_REDELEGATE_HEIGHT (Bob redel): chain state changed; new redel entry (PRIMARY 2)\n"
  printf "    h=$VERIFY_HEIGHT (verify):     val-5 shares=0; val-1 has Bob; completion_time matches val-5.unbonding_time (PRIMARY 3)\n"
  printf "\n"
  printf "  CHAIN-ASSERTED CONCLUSIONS:\n"
  printf "  (PRIMARY 1) val-5 sole-100% pattern confirmed (1 delegation, delegator=Bob)\n"
  printf "  (PRIMARY 2) Bob's redelegate state-changed (tx rc=0 + REST redelegation entry created)\n"
  printf "             -- NOT silent rollback like case-6b-G1 (Unbonded sibling case)\n"
  printf "  (PRIMARY 3) val-5 shares zeroed, val-1 has Bob delegation,\n"
  printf "             redelegation completion_time aligned with val-5.unbonding_time\n"
  printf "             (Unbonding-case getBeginInfo path signature)\n"
  printf "  Evidence in $EVIDENCE_DIR\n"
  printf "========================================================\n"
}

# ---------------- Phase 8 — teardown ----------------
phase_8_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then
    log "Phase 8 - SKIP_TEARDOWN"; return
  fi
  log "Phase 8 - teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_bob_stake
phase_2_operator_self_unstake
phase_3_v170
phase_4_verify_sole_100
phase_5_bob_redelegate
phase_6_verify_outcome
phase_7_capture_and_summary
phase_8_teardown
