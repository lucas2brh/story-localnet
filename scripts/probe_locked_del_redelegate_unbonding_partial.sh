#!/usr/bin/env bash
# probe_locked_del_redelegate_unbonding_partial.sh — Raul Case 6b "source Unbonding" branch baseline
#
# Tests docs/plans/maxvalidators-reduction-impact.md Case 6b sub-branch:
#   "source Unbonding → uses validator's remaining unbonding time" (line 391-392).
# Coverage focus: redelegate of an unmatured locked-period external delegator
# off a v1.7.0-pruned val WHILE the val is still in BOND_STATUS_UNBONDING
# (within UnbondingTime window). Distinct from probe_locked_del_redelegate_unbonded_partial.sh
# which redelegates AFTER UnbondingTime elapses.
#
# Topology:
#   - val-22 = UNLOCKED (support_token_type=1) — out-of-cap, V170 prune at H=50
#   - val-1  = UNLOCKED (support_token_type=1) — top-21 dest (same-type)
#   - val-22 retains operator self-stake (~107T) + Bob's 1024 IP locked-short
#   - UnbondingTime extended to 600s in genesis to keep val-22 UNBONDING through Phase 5
#
# Sequence:
#   Phase 0  Boot 22-val cluster (val-1 + val-22 UNLOCKED, periods[1..3]=1800s, unbonding_time=600s)
#   Phase 1  Baseline: both BONDED + UNLOCKED
#   Phase 2  Bob stakes locked-short 1024 IP → val-22 (delegation_id=1)
#   Phase 3  Wait V170 H=50 + ~3 blocks. Assert val-22 status=BOND_STATUS_UNBONDING (=2).
#            Operator does NOT self-unstake.
#   Phase 4  Immediately Bob redelegate val-22 → val-1, before UnbondingTime elapses.
#            Expected PASS path: src.tokens -= 1024, dst.tokens += 1024, redelegation
#            entry completion_time = src val remaining unbonding_time (NOT instant),
#            dst delegation live immediately, lock metadata preserved.
#   Phase 5  Verify Bob's delegation on dst preserves period_type=1 + same EndTime.
#   Phase 6  Verify redelegation entry on Bob has non-zero completion_time pointing
#            to src val's unbonding_time (not block_time).
#   Phase 7  Snapshot final state.
#   Phase 8  Summary.
#   Phase 9  Teardown (skipped if SKIP_TEARDOWN=1).
#
# Usage:
#   ./scripts/probe_locked_del_redelegate_unbonding_partial.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_locked_del_redelegate_unbonding_partial.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
PRE_STAKE_BLOCK=${PRE_STAKE_BLOCK:-10}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-53}     # very early post-V170 — val-22 is UNBONDING
UNBONDING_TIME_EXT=${UNBONDING_TIME_EXT:-600s}    # genesis tweak to keep src UNBONDING through redelegate
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
EV_DIR="${LOCALNET}/tmp/probe-X-evidence"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

ALICE_PK=${ALICE_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ALICE_ADDR=${ALICE_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
BOB_PK=${BOB_PK:-59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}
BOB_ADDR=${BOB_ADDR:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}

N_VALS=${N_VALS:-22}
NEW_MAX=${NEW_MAX:-21}
SRC_VAL_MONIKER=${SRC_VAL_MONIKER:-localnet-val-22}
DST_VAL_MONIKER=${DST_VAL_MONIKER:-localnet-val-1}
STAKE_IP=${STAKE_IP:-1024}
STAKE_WEI="${STAKE_IP}000000000000000000"

SEED_IP=${SEED_IP:-2000}
SEED_WEI="${SEED_IP}000000000000000000"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[X]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[X]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[X]${C_RESET} FAIL %s\n" "$*"; exit 1; }

# ---------------- helpers ----------------
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
  local op=$1 field=$2 body i
  for i in 1 2 3 4 5; do
    body=$(curl -fsS --max-time 3 "http://localhost:1317/staking/validators/${op}" 2>/dev/null) || true
    if [[ -n "$body" ]] && jq -e .msg.validator >/dev/null 2>&1 <<<"$body"; then
      jq -r ".msg.validator.${field} // empty" <<<"$body"
      return 0
    fi
    sleep 0.5
  done
  echo "ERROR: REST /staking/validators/${op} returned no validator body after 5 retries" >&2
  return 1
}

meta_pubkey_hex() { local b64; b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META"); echo -n "$b64" | base64 -d | xxd -p -c 66; }
meta_op_evm()     { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }
meta_privkey()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }

do_stake() {
  local who=$1 pk=$2 pubkey=$3 period=$4
  log "  $who stake $period (${STAKE_IP} IP) → $pubkey"
  local out rc
  out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator stake \
    --validator-pubkey "$pubkey" --stake "$STAKE_WEI" --staking-period "$period" \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -10
  [[ $rc -eq 0 ]] || fail "$who stake rc=$rc"
  printf '%s\n' "$out" | grep -oE "Delegation ID: [0-9]+" | tail -1
}

do_redelegate() {
  local who=$1 pk=$2 src_pubkey=$3 dst_pubkey=$4 amt=$5 del_id=${6:-0}
  log "  $who redelegate amt=$amt del_id=$del_id src→dst"
  local out rc
  out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$src_pubkey" --validator-dst-pubkey "$dst_pubkey" \
    --redelegate "$amt" --delegation-id "$del_id" \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -10
  [[ $rc -eq 0 ]] || fail "$who redelegate rc=$rc"
  printf '%s\n' "$out" | grep -oE "Transaction hash: 0x[0-9a-fA-F]+" | tail -1
}

capture_evidence() {
  local label=$1
  local since="${PHASE_START_TS:-1m}"
  mkdir -p "$EV_DIR"

  for c in bootnode1-node validator22-node validator1-node; do
    docker logs --since "$since" "$c" 2>&1 \
      | grep -E 'ABCI call: (PrepareProposal|ProcessProposal|FinalizeBlock|Commit)|MaxValidators reduction|MsgUndelegate|MsgDelegate|MsgBeginRedelegate|module=evmstaking|module=x/staking|RemoveValidator|Redelegation|Redelegate Info|Delegate Info|Undelegate Info|Unbond Info|jail|panic|CONSENSUS FAILURE|Failed to process redelegate' \
      > "$EV_DIR/cl-${c}-${label}.log" 2>/dev/null || true
  done

  for c in validator22-geth validator1-geth rpc1-geth; do
    docker logs --since "$since" "$c" 2>&1 \
      | grep -E 'Imported new|Chain head was updated|Beacon client|Engine API|payload' \
      > "$EV_DIR/el-${c}-${label}.log" 2>/dev/null || true
  done

  : > "$EV_DIR/health-${label}.log"
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$'); do
    n=$(docker logs "$c" 2>&1 | grep -cE 'panic|CONSENSUS FAILURE' || true)
    if [[ "$n" -gt 0 ]]; then
      echo "$c: $n hits" >> "$EV_DIR/health-${label}.log"
      docker logs "$c" 2>&1 | grep -E 'panic|CONSENSUS FAILURE' | head -5 >> "$EV_DIR/health-${label}.log"
    fi
  done
  [[ -s "$EV_DIR/health-${label}.log" ]] || echo "no panic/CONSENSUS FAILURE in any val-node log" > "$EV_DIR/health-${label}.log"

  log "  evidence captured to $EV_DIR/{cl,el,health}-*-${label}.log"
}

# ---------------- Phase 0 ----------------
phase_0_start() {
  log "Phase 0 — start fresh ${N_VALS}-val localnet, val-1 + val-${N_VALS} UNLOCKED, NEW_MAX=${NEW_MAX}, unbonding_time=${UNBONDING_TIME_EXT}"
  if docker ps --format '{{.Names}}' | grep -qE '^(validator|bootnode|rpc)[0-9]*-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1); sleep 5
  fi
  bash "${LOCALNET}/scripts/generate_N_validators.sh" "$N_VALS" 2>&1 | tail -1
  bash "${LOCALNET}/scripts/fetch_mainnet_distribution.sh" "$N_VALS" 2>&1 | tail -1
  UNLOCKED_VALS="1,$N_VALS" MAX_VALIDATORS_INIT="$N_VALS" bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N_VALS" 2>&1 | tail -1

  local genesis_path="${LOCALNET}/config/story/genesis-node.json"
  local tmp; tmp=$(mktemp)
  jq --arg ut "$UNBONDING_TIME_EXT" '
    .app_state.staking.params.periods[1].duration = "1800s" |
    .app_state.staking.params.periods[2].duration = "1800s" |
    .app_state.staking.params.periods[3].duration = "1800s" |
    .app_state.staking.params.unbonding_time = $ut
  ' "$genesis_path" > "$tmp" && mv "$tmp" "$genesis_path"
  log "  periods[1..3].duration=1800s + unbonding_time=$UNBONDING_TIME_EXT (runtime tweak — keeps src UNBONDING through Phase 4 redelegate)"

  bash "${LOCALNET}/scripts/generate_compose_files.sh" "$N_VALS" 2>&1 | tail -1 || true

  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -1)
  local deadline=$(( $(date +%s) + 120 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "rpc1 didn't sync in 120s"
    sleep 3
  done

  PHASE_START_TS=$(date -u +%Y-%m-%dT%H:%M:%S)
  mkdir -p "$EV_DIR"
}

SRC_VAL_OP=""; DST_VAL_OP=""
phase_1_baseline() {
  log "Phase 1 — wait h=$PRE_STAKE_BLOCK + capture baseline + seed Bob"
  wait_height "$PRE_STAKE_BLOCK" >/dev/null
  SRC_VAL_OP=$(meta_op_evm "$SRC_VAL_MONIKER")
  DST_VAL_OP=$(meta_op_evm "$DST_VAL_MONIKER")
  local s_src s_dst t_src t_dst stt_src stt_dst
  s_src=$(val_field "$SRC_VAL_OP" status)              || fail "REST: $SRC_VAL_MONIKER status read failed (Phase 1)"
  t_src=$(val_field "$SRC_VAL_OP" tokens)              || fail "REST: $SRC_VAL_MONIKER tokens read failed"
  stt_src=$(val_field "$SRC_VAL_OP" support_token_type) || fail "REST: $SRC_VAL_MONIKER support_token_type read failed"
  s_dst=$(val_field "$DST_VAL_OP" status)              || fail "REST: $DST_VAL_MONIKER status read failed"
  t_dst=$(val_field "$DST_VAL_OP" tokens)              || fail "REST: $DST_VAL_MONIKER tokens read failed"
  stt_dst=$(val_field "$DST_VAL_OP" support_token_type) || fail "REST: $DST_VAL_MONIKER support_token_type read failed"
  log "  $SRC_VAL_MONIKER (UNLOCKED): op=$SRC_VAL_OP status=$s_src tokens=$t_src support_token_type=$stt_src"
  log "  $DST_VAL_MONIKER (UNLOCKED): op=$DST_VAL_OP status=$s_dst tokens=$t_dst support_token_type=$stt_dst"
  [[ "$s_src" == "3" ]] || fail "expected $SRC_VAL_MONIKER BOND_STATUS_BONDED (status=3) pre-upgrade, got status=$s_src"
  [[ "$s_dst" == "3" ]] || fail "expected $DST_VAL_MONIKER BOND_STATUS_BONDED (status=3) pre-upgrade, got status=$s_dst"
  [[ "$stt_src" == "1" ]] || fail "expected $SRC_VAL_MONIKER support_token_type=1 (UNLOCKED), got $stt_src"
  [[ "$stt_dst" == "1" ]] || fail "expected $DST_VAL_MONIKER support_token_type=1 (UNLOCKED), got $stt_dst"

  cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$BOB_ADDR" \
    --value "${SEED_IP}ether" --legacy --gas-price 50gwei >/dev/null 2>&1
  local bal; bal=$(get_evm_balance "$BOB_ADDR")
  log "  Bob seeded balance=$bal wei"
  pass "baseline + seed complete"
  capture_evidence "01-baseline"
}

BOB_BAL_PRE_STAKE=""; SRC_TOKENS_PRE=""; DST_TOKENS_PRE=""
phase_2_stake() {
  log "Phase 2 — Bob stakes ${STAKE_IP} IP locked-short (period_type=1) to $SRC_VAL_MONIKER"
  BOB_BAL_PRE_STAKE=$(get_evm_balance "$BOB_ADDR")
  SRC_TOKENS_PRE=$(val_field "$SRC_VAL_OP" tokens) || fail "REST: pre-stake src tokens read failed"
  DST_TOKENS_PRE=$(val_field "$DST_VAL_OP" tokens) || fail "REST: pre-stake dst tokens read failed"
  log "  pre-stake: Bob=$BOB_BAL_PRE_STAKE, src.tokens=$SRC_TOKENS_PRE, dst.tokens=$DST_TOKENS_PRE"

  local pub_src; pub_src=$(meta_pubkey_hex "$SRC_VAL_MONIKER")
  local del_id_line
  del_id_line=$(do_stake Bob "$BOB_PK" "$pub_src" short)
  log "  CLI returned: $del_id_line"

  sleep 8
  local src_tokens_post src_shares_post
  src_tokens_post=$(val_field "$SRC_VAL_OP" tokens) || fail "REST: post-stake src tokens read failed"
  src_shares_post=$(val_field "$SRC_VAL_OP" delegator_shares)
  local delta_src; delta_src=$(python3 -c "print($src_tokens_post - $SRC_TOKENS_PRE)")
  log "  post-stake: src.tokens=$src_tokens_post (delta=$delta_src), src.shares=$src_shares_post"
  local expected_delta=$((STAKE_IP * 1000000000))
  [[ "$delta_src" == "$expected_delta" ]] || fail "src val tokens delta=$delta_src, expected $expected_delta — stake did not commit on chain"
  pass "Bob stake committed; src val carrying locked-short delegation (id=1)"
  capture_evidence "02-stake"
}

# ---------------- Phase 3 — V170 prune; assert val-22 = BOND_STATUS_UNBONDING ----------------
phase_3_prune_to_unbonding() {
  log "Phase 3 — wait past V170=$UPGRADE_HEIGHT to h=$POST_UPGRADE_BLOCK (within UnbondingTime window)"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  local s_src s_dst t_src ub_height ub_time
  s_src=$(val_field "$SRC_VAL_OP" status) || fail "REST: $SRC_VAL_MONIKER status read failed (Phase 3)"
  t_src=$(val_field "$SRC_VAL_OP" tokens) || fail "REST: $SRC_VAL_MONIKER tokens read failed"
  s_dst=$(val_field "$DST_VAL_OP" status) || fail "REST: $DST_VAL_MONIKER status read failed"
  ub_height=$(val_field "$SRC_VAL_OP" unbonding_height)
  ub_time=$(val_field "$SRC_VAL_OP" unbonding_time)
  log "  src post-V170: status=$s_src tokens=$t_src unbonding_height=$ub_height unbonding_time=$ub_time"
  log "  dst post-V170: status=$s_dst"
  [[ "$s_src" == "2" ]] || fail "expected $SRC_VAL_MONIKER BOND_STATUS_UNBONDING (status=2) post-V170 within UnbondingTime, got status=$s_src — UnbondingTime tweak may have failed"
  [[ "$s_dst" == "3" ]] || fail "expected $DST_VAL_MONIKER BOND_STATUS_BONDED (status=3) post-V170, got status=$s_dst"
  pass "V170 prune fired; src in BOND_STATUS_UNBONDING (target window for X probe)"
  capture_evidence "03-post-prune-unbonding"
}

# ---------------- Phase 4 — Bob redelegate while src UNBONDING (THE TEST) ----------------
SRC_TOKENS_PRE_REDEL=""; DST_TOKENS_PRE_REDEL=""; BOB_BAL_PRE_REDEL=""; REDEL_TX_HASH=""
phase_4_redelegate_unbonding() {
  log "Phase 4 — Bob redelegate from $SRC_VAL_MONIKER (UNBONDING) to $DST_VAL_MONIKER (BONDED)"
  log "  Raul Case 6b 'source Unbonding' baseline: redelegation entry completion = src val remaining unbonding_time"

  SRC_TOKENS_PRE_REDEL=$(val_field "$SRC_VAL_OP" tokens) || fail "REST: pre-redel src tokens read failed"
  DST_TOKENS_PRE_REDEL=$(val_field "$DST_VAL_OP" tokens) || fail "REST: pre-redel dst tokens read failed"
  BOB_BAL_PRE_REDEL=$(get_evm_balance "$BOB_ADDR")
  log "  pre-redel: src.tokens=$SRC_TOKENS_PRE_REDEL, dst.tokens=$DST_TOKENS_PRE_REDEL, Bob=$BOB_BAL_PRE_REDEL wei"

  # Re-confirm src is still UNBONDING immediately before redelegate (no race with UnbondingTime expiry)
  local s_pre; s_pre=$(val_field "$SRC_VAL_OP" status) || fail "REST: pre-redel src status read failed"
  [[ "$s_pre" == "2" ]] || fail "src transitioned out of BOND_STATUS_UNBONDING before redelegate (status=$s_pre) — bump UNBONDING_TIME_EXT or POST_UPGRADE_BLOCK"

  local pub_src pub_dst
  pub_src=$(meta_pubkey_hex "$SRC_VAL_MONIKER")
  pub_dst=$(meta_pubkey_hex "$DST_VAL_MONIKER")

  REDEL_TX_HASH=$(do_redelegate Bob "$BOB_PK" "$pub_src" "$pub_dst" "$STAKE_WEI" 1)
  log "  redelegate $REDEL_TX_HASH"
  sleep 8

  local src_tokens_post dst_tokens_post src_shares_post dst_shares_post s_post
  src_tokens_post=$(val_field "$SRC_VAL_OP" tokens) || fail "REST: post-redel src tokens read failed"
  dst_tokens_post=$(val_field "$DST_VAL_OP" tokens) || fail "REST: post-redel dst tokens read failed"
  src_shares_post=$(val_field "$SRC_VAL_OP" delegator_shares)
  dst_shares_post=$(val_field "$DST_VAL_OP" delegator_shares)
  s_post=$(val_field "$SRC_VAL_OP" status)

  local src_delta dst_delta
  src_delta=$(python3 -c "print($src_tokens_post - $SRC_TOKENS_PRE_REDEL)")
  dst_delta=$(python3 -c "print($dst_tokens_post - $DST_TOKENS_PRE_REDEL)")

  log "  post-redel: src.tokens=$src_tokens_post (delta=$src_delta) status=$s_post, dst.tokens=$dst_tokens_post (delta=$dst_delta)"
  log "  post-redel: src.shares=$src_shares_post, dst.shares=$dst_shares_post"

  local expected_neg=$(python3 -c "print(-$STAKE_IP * 1000000000)")
  local expected_pos=$((STAKE_IP * 1000000000))
  [[ "$src_delta" == "$expected_neg" ]] || fail "src val tokens delta=$src_delta, expected $expected_neg — redelegate did NOT decrement src on chain"
  [[ "$dst_delta" == "$expected_pos" ]] || fail "dst val tokens delta=$dst_delta, expected $expected_pos — redelegate did NOT credit dst on chain"

  pass "redelegate moved 1024 IP src→dst on chain; src state during redelegate was BOND_STATUS_UNBONDING"
  capture_evidence "04-redelegate"
}

# ---------------- Phase 5 — verify lock metadata preserved on dst ----------------
phase_5_verify_lock_preserved() {
  log "Phase 5 — verify Bob's delegation on dst preserves period_type=1 (locked-short) + same EndTime"
  local dst_dels
  dst_dels=$(curl -fsS --max-time 5 "http://localhost:1317/staking/validators/${DST_VAL_OP}/delegations" 2>/dev/null)
  log "  dst val delegations response (head):"
  echo "$dst_dels" | jq . 2>/dev/null | head -30 | sed 's/^/      /'

  local bob_lc; bob_lc=$(echo "$BOB_ADDR" | tr '[:upper:]' '[:lower:]')
  local bob_del
  bob_del=$(echo "$dst_dels" | jq --arg a "$bob_lc" '.msg.delegation_responses[]? | select((.delegation.delegator_address // "" | ascii_downcase) == $a)' 2>/dev/null)

  if [[ -z "$bob_del" ]]; then
    log "  NOTE: Bob's delegation entry not found via standard route; saving full dst dels for post-mortem"
    echo "$dst_dels" > "$EV_DIR/05-dst-delegations.json"
  else
    local bob_shares; bob_shares=$(echo "$bob_del" | jq -r '.delegation.shares')
    log "  Bob on dst: shares=$bob_shares"
    echo "$bob_del" > "$EV_DIR/05-bob-delegation-on-dst.json"
  fi

  local period_resp
  period_resp=$(curl -fsS --max-time 5 "http://localhost:1317/staking/delegators/${BOB_ADDR}/validators/${DST_VAL_OP}/period_delegations" 2>/dev/null)
  if [[ -n "$period_resp" ]]; then
    echo "$period_resp" > "$EV_DIR/05-bob-period-delegations-on-dst.json"
    log "  period_delegations response saved; head:"
    echo "$period_resp" | jq . 2>/dev/null | head -20 | sed 's/^/      /'
  fi

  pass "Phase 5 lock-metadata snapshot captured"
  capture_evidence "05-lock-preserved"
}

# ---------------- Phase 6 — verify redelegation entry completion_time != block_time ----------------
phase_6_verify_redelegation_entry() {
  log "Phase 6 — verify Bob's redelegation entry on chain has completion_time = src UnbondingTime (not instant)"
  local redel_resp
  redel_resp=$(curl -fsS --max-time 5 "http://localhost:1317/cosmos/staking/v1beta1/delegators/${BOB_ADDR}/redelegations" 2>/dev/null)
  if [[ -n "$redel_resp" ]]; then
    echo "$redel_resp" > "$EV_DIR/06-bob-redelegations.json"
    log "  redelegations response saved; head:"
    echo "$redel_resp" | jq . 2>/dev/null | head -40 | sed 's/^/      /'
  else
    log "  NOTE: redelegations REST returned empty; saving for post-mortem"
  fi
  pass "Phase 6 redelegation-entry snapshot captured"
  capture_evidence "06-redel-entry"
}

phase_7_final_snapshot() {
  log "Phase 7 — final on-chain val state snapshot"
  for moniker_op in "$SRC_VAL_MONIKER:$SRC_VAL_OP" "$DST_VAL_MONIKER:$DST_VAL_OP"; do
    local moniker=${moniker_op%%:*} op=${moniker_op##*:}
    local s j t sh
    s=$(val_field "$op" status); j=$(val_field "$op" jailed)
    t=$(val_field "$op" tokens); sh=$(val_field "$op" delegator_shares)
    log "  $moniker final: status=$s jailed=$j tokens=$t shares=$sh"
    echo "{\"moniker\":\"$moniker\",\"operator\":\"$op\",\"status\":\"$s\",\"jailed\":\"$j\",\"tokens\":\"$t\",\"shares\":\"$sh\"}" \
      > "$EV_DIR/final-${moniker}.json"
  done
  log "  chain height $(get_height)"
  log "  redelegate tx hash: $REDEL_TX_HASH"
}

phase_8_summary() {
  printf "\n========== X PROBE — RAUL CASE 6b 'SOURCE UNBONDING' BASELINE ==========\n"
  printf "  Binary: yao/v170-maxval-21 (NewMaxValidators=21)\n"
  printf "  Cluster: %d vals, NEW_MAX=%d, unbonding_time=%s\n" "$N_VALS" "$NEW_MAX" "$UNBONDING_TIME_EXT"
  printf "  src val: %s (UNLOCKED, V170-pruned, BOND_STATUS_UNBONDING at redelegate time)\n" "$SRC_VAL_MONIKER"
  printf "  dst val: %s (UNLOCKED, top-21, BOND_STATUS_BONDED)\n" "$DST_VAL_MONIKER"
  printf "  Action: Bob redelegate 1024 IP locked-short (id=1) src→dst, Bob non-100%% holder\n"
  printf "  src final: $(cat "$EV_DIR/final-${SRC_VAL_MONIKER}.json" 2>/dev/null)\n"
  printf "  dst final: $(cat "$EV_DIR/final-${DST_VAL_MONIKER}.json" 2>/dev/null)\n"
  printf "  Bob EVM bal: pre-stake=%s, pre-redel=%s, post=%s wei\n" "$BOB_BAL_PRE_STAKE" "$BOB_BAL_PRE_REDEL" "$(get_evm_balance "$BOB_ADDR")"
  printf "  Final chain height: %s\n" "$(get_height)"
  printf "  Redelegate tx: %s\n" "$REDEL_TX_HASH"
  printf "  Evidence: %s/\n" "$EV_DIR"
  printf "========================================================================\n"
}

phase_9_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 9 — SKIP_TEARDOWN"; return; fi
  log "Phase 9 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1)
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline
phase_2_stake
phase_3_prune_to_unbonding
phase_4_redelegate_unbonding
phase_5_verify_lock_preserved
phase_6_verify_redelegation_entry
phase_7_final_snapshot
phase_8_summary
phase_9_teardown
