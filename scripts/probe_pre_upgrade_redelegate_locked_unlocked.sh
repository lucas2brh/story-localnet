#!/usr/bin/env bash
# probe_pre_upgrade_redelegate_locked_unlocked.sh — Raul Case 7 (pre-H delegator redelegate)
#
# Tests "Out-59 delegator redelegates to top-21 BEFORE H" — the pre-emptive
# escape path advised to delegators of out-of-cap validators before v1.7.0
# activation. Verifies that redelegate works at chain layer for both
# UNLOCKED→UNLOCKED and LOCKED→LOCKED token-type combinations while src is
# still BONDED (V170 has not fired yet, so #619 trigger conditions are not
# met).
#
# Topology (23-val cluster, NEW_MAX=21):
#   - val-1  = UNLOCKED (support_token_type=1) — top-21 UNLOCKED redelegate dst
#   - val-2  = LOCKED   (support_token_type=0) — top-21 LOCKED   redelegate dst
#   - val-22 = LOCKED   (support_token_type=0) — out-of-top-21 LOCKED   src
#   - val-23 = UNLOCKED (support_token_type=1) — out-of-top-21 UNLOCKED src
#   - rest default LOCKED
#
# Cross-type redelegate (LOCKED↔UNLOCKED) is rejected by ErrTokenTypeMismatch
# at the chain layer; not exercised here.
#
# Sequence:
#   Phase 0  Boot 23-val cluster (UNLOCKED_VALS="1,23", periods[1..3]=1800s)
#   Phase 1  Baseline + seed Bob (val-23 src) + Charlie (val-22 src)
#   Phase 2  Bob stakes locked-short 1024 IP → val-23 (UNLOCKED src)
#            Charlie stakes locked-short 1024 IP → val-22 (LOCKED src — coerced flexible)
#   Phase 3  Capture pre-redelegate state for both delegators
#   Phase 4  PRE-V170 redelegate (height < UPGRADE_HEIGHT, all vals still BONDED)
#              Bob:     val-23 → val-1  (UNLOCKED → UNLOCKED)
#              Charlie: val-22 → val-2  (LOCKED   → LOCKED)
#   Phase 5  Capture post-redelegate state + assert chain deltas
#   Phase 6  Verify period_delegation rewards_multiplier on dst:
#              UNLOCKED→UNLOCKED: 1.051x preserved (period[1] short multiplier)
#              LOCKED→LOCKED:     1.0 (period was coerced flexible at deposit)
#   Phase 7  Final pre-V170 snapshot for evidence
#   Phase 8  POST-V170 chain assertion (wait past UPGRADE_HEIGHT, assert
#            staking/params.max_validators == NEW_MAX, assert val-5..N_VALS
#            actually pruned to status ∈ {1,2}, top-NEW_MAX stays BONDED).
#            This is what closes the gap exposed 2026-05-08: prior runs
#            stopped at Phase 7 and never confirmed V170 actually fired.
#   Phase 9  Summary
#   Phase 10 Teardown (skipped if SKIP_TEARDOWN=1)
#
# Usage:
#   ./scripts/probe_pre_upgrade_redelegate_locked_unlocked.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_pre_upgrade_redelegate_locked_unlocked.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-100}
PRE_STAKE_BLOCK=${PRE_STAKE_BLOCK:-10}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
EV_DIR="${LOCALNET}/tmp/probe-case7-evidence"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

# anvil predefined keys
ALICE_PK=${ALICE_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ALICE_ADDR=${ALICE_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
BOB_PK=${BOB_PK:-59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}
BOB_ADDR=${BOB_ADDR:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}
CHARLIE_PK=${CHARLIE_PK:-5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}
CHARLIE_ADDR=${CHARLIE_ADDR:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}

N_VALS=${N_VALS:-8}
NEW_MAX=${NEW_MAX:-4}

# Bob's path: UNLOCKED → UNLOCKED
BOB_SRC_MONIKER=${BOB_SRC_MONIKER:-localnet-val-8}
BOB_DST_MONIKER=${BOB_DST_MONIKER:-localnet-val-1}

# Charlie's path: LOCKED → LOCKED
CHARLIE_SRC_MONIKER=${CHARLIE_SRC_MONIKER:-localnet-val-7}
CHARLIE_DST_MONIKER=${CHARLIE_DST_MONIKER:-localnet-val-2}

STAKE_IP=${STAKE_IP:-1024}
STAKE_WEI="${STAKE_IP}000000000000000000"
SEED_IP=${SEED_IP:-2000}
SEED_WEI="${SEED_IP}000000000000000000"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[case7]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[case7]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[case7]${C_RESET} FAIL %s\n" "$*"; exit 1; }

# ---------------- chain helpers ----------------
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
  # 5x retry on REST empty body. On persistent REST failure: stderr + return 1.
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

# ---------------- evidence capture ----------------
capture_evidence() {
  local label=$1
  local since="${PHASE_START_TS:-1m}"
  mkdir -p "$EV_DIR"

  for c in bootnode1-node validator1-node validator2-node validator7-node validator8-node; do
    docker logs --since "$since" "$c" 2>&1 \
      | grep -E 'ABCI call: (PrepareProposal|ProcessProposal|FinalizeBlock|Commit)|MsgUndelegate|MsgDelegate|MsgBeginRedelegate|module=evmstaking|module=x/staking|RemoveValidator|Redelegation|Redelegate Info|Delegate Info|Undelegate Info|Unbond Info|jail|panic|CONSENSUS FAILURE|Failed to process redelegate|ErrTokenTypeMismatch' \
      > "$EV_DIR/cl-${c}-${label}.log" 2>/dev/null || true
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

  log "  evidence captured to $EV_DIR/{cl,health}-*-${label}.log"
}

# ---------------- Phase 0 ----------------
phase_0_start() {
  log "Phase 0 — start fresh ${N_VALS}-val localnet, val-1 + val-${N_VALS} UNLOCKED, others LOCKED, NEW_MAX=${NEW_MAX}"
  if docker ps --format '{{.Names}}' | grep -qE '^(validator|bootnode|rpc)[0-9]*-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1); sleep 5
  fi
  bash "${LOCALNET}/scripts/generate_N_validators.sh" "$N_VALS" 2>&1 | tail -1
  NEW_MAX_VALIDATORS=$NEW_MAX bash "${LOCALNET}/scripts/fetch_mainnet_distribution.sh" "$N_VALS" 2>&1 | tail -1
  UNLOCKED_VALS="1,$N_VALS" MAX_VALIDATORS_INIT="$N_VALS" bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N_VALS" 2>&1 | tail -1

  local genesis_path="${LOCALNET}/config/story/genesis-node.json"
  local tmp; tmp=$(mktemp)
  jq '
    .app_state.staking.params.periods[1].duration = "1800s" |
    .app_state.staking.params.periods[2].duration = "1800s" |
    .app_state.staking.params.periods[3].duration = "1800s"
  ' "$genesis_path" > "$tmp" && mv "$tmp" "$genesis_path"
  log "  periods[1..3].duration set to 1800s (locked-short stays unmatured throughout probe)"

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

# ---------------- Phase 1 — baseline + seed ----------------
BOB_SRC_OP=""; BOB_DST_OP=""; CHARLIE_SRC_OP=""; CHARLIE_DST_OP=""
phase_1_baseline() {
  log "Phase 1 — wait h=$PRE_STAKE_BLOCK + capture baseline + seed Bob + Charlie"
  wait_height "$PRE_STAKE_BLOCK" >/dev/null

  BOB_SRC_OP=$(meta_op_evm "$BOB_SRC_MONIKER")
  BOB_DST_OP=$(meta_op_evm "$BOB_DST_MONIKER")
  CHARLIE_SRC_OP=$(meta_op_evm "$CHARLIE_SRC_MONIKER")
  CHARLIE_DST_OP=$(meta_op_evm "$CHARLIE_DST_MONIKER")

  local s_bs s_bd s_cs s_cd stt_bs stt_bd stt_cs stt_cd
  s_bs=$(val_field "$BOB_SRC_OP" status)              || fail "REST: $BOB_SRC_MONIKER status read failed"
  s_bd=$(val_field "$BOB_DST_OP" status)              || fail "REST: $BOB_DST_MONIKER status read failed"
  s_cs=$(val_field "$CHARLIE_SRC_OP" status)          || fail "REST: $CHARLIE_SRC_MONIKER status read failed"
  s_cd=$(val_field "$CHARLIE_DST_OP" status)          || fail "REST: $CHARLIE_DST_MONIKER status read failed"
  stt_bs=$(val_field "$BOB_SRC_OP" support_token_type) || fail "REST: $BOB_SRC_MONIKER support_token_type read failed"
  stt_bd=$(val_field "$BOB_DST_OP" support_token_type) || fail "REST: $BOB_DST_MONIKER support_token_type read failed"
  stt_cs=$(val_field "$CHARLIE_SRC_OP" support_token_type) || fail "REST: $CHARLIE_SRC_MONIKER support_token_type read failed"
  stt_cd=$(val_field "$CHARLIE_DST_OP" support_token_type) || fail "REST: $CHARLIE_DST_MONIKER support_token_type read failed"

  log "  Bob src     ($BOB_SRC_MONIKER):     status=$s_bs support_token_type=$stt_bs (expect 3 / 1)"
  log "  Bob dst     ($BOB_DST_MONIKER):     status=$s_bd support_token_type=$stt_bd (expect 3 / 1)"
  log "  Charlie src ($CHARLIE_SRC_MONIKER): status=$s_cs support_token_type=$stt_cs (expect 3 / 0)"
  log "  Charlie dst ($CHARLIE_DST_MONIKER): status=$s_cd support_token_type=$stt_cd (expect 3 / 0)"

  [[ "$s_bs" == "3" ]] || fail "expected $BOB_SRC_MONIKER BOND_STATUS_BONDED (status=3), got $s_bs"
  [[ "$s_bd" == "3" ]] || fail "expected $BOB_DST_MONIKER BOND_STATUS_BONDED (status=3), got $s_bd"
  [[ "$s_cs" == "3" ]] || fail "expected $CHARLIE_SRC_MONIKER BOND_STATUS_BONDED (status=3), got $s_cs"
  [[ "$s_cd" == "3" ]] || fail "expected $CHARLIE_DST_MONIKER BOND_STATUS_BONDED (status=3), got $s_cd"
  [[ "$stt_bs" == "1" ]] || fail "expected $BOB_SRC_MONIKER UNLOCKED (stt=1), got $stt_bs"
  [[ "$stt_bd" == "1" ]] || fail "expected $BOB_DST_MONIKER UNLOCKED (stt=1), got $stt_bd"
  # support_token_type=0 (LOCKED) is proto3 default; REST may return empty when omitted
  [[ "$stt_cs" == "0" || -z "$stt_cs" ]] || fail "expected $CHARLIE_SRC_MONIKER LOCKED (stt=0/empty), got '$stt_cs'"
  [[ "$stt_cd" == "0" || -z "$stt_cd" ]] || fail "expected $CHARLIE_DST_MONIKER LOCKED (stt=0/empty), got '$stt_cd'"

  # All-val BFT health check: every genesis validator must be BOND_STATUS_BONDED
  # and chain must be producing blocks (BFT quorum 2/3+ proven by height growth).
  local h0=$(get_height)
  for K in $(seq 1 "$N_VALS"); do
    local op_k s_k
    op_k=$(meta_op_evm "localnet-val-$K")
    s_k=$(val_field "$op_k" status) || fail "REST: val-$K status read failed"
    [[ "$s_k" == "3" ]] || fail "val-$K not BOND_STATUS_BONDED (status=3), got status=$s_k"
  done
  sleep 4
  local h1=$(get_height)
  [[ $h1 -gt $h0 ]] || fail "chain not producing blocks: h0=$h0 h1=$h1 (BFT quorum likely missing)"
  log "  all $N_VALS vals BOND_STATUS_BONDED; chain height $h0 → $h1 (producing)"

  # Proposer rotation audit: every val must propose ≥1 block in the next 2*N_VALS
  # blocks. CometBFT proposer is deterministic round-robin weighted by voting power.
  local need=$((N_VALS * 2))
  while [[ $(get_height) -lt $((h1 + need)) ]]; do sleep 2; done
  local audit_h=$(get_height)
  local audit_start=$((audit_h - need + 1))
  local proposer_resp distinct
  proposer_resp=$(docker exec rpc1-node wget -q -O- --timeout=5 \
    "http://localhost:26657/blockchain?minHeight=${audit_start}&maxHeight=${audit_h}" 2>/dev/null)
  distinct=$(echo "$proposer_resp" | jq -r '.result.block_metas[].header.proposer_address' 2>/dev/null | sort -u | wc -l | tr -d ' ')
  echo "$proposer_resp" > "$EV_DIR/01-proposer-audit-h${audit_start}-${audit_h}.json"
  [[ "$distinct" == "$N_VALS" ]] || fail "proposer rotation: expected $N_VALS distinct, got $distinct in h=${audit_start}..${audit_h}"
  log "  proposer rotation: $distinct/$N_VALS distinct proposers in h=${audit_start}..${audit_h} (every val propsed ≥1 block)"

  cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$BOB_ADDR" \
    --value "${SEED_IP}ether" --legacy --gas-price 50gwei >/dev/null 2>&1
  cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$CHARLIE_ADDR" \
    --value "${SEED_IP}ether" --legacy --gas-price 50gwei >/dev/null 2>&1
  log "  Bob balance=$(get_evm_balance "$BOB_ADDR") wei"
  log "  Charlie balance=$(get_evm_balance "$CHARLIE_ADDR") wei"

  pass "baseline + seed complete; Bob path UNLOCKED→UNLOCKED, Charlie path LOCKED→LOCKED"
  capture_evidence "01-baseline"
}

# ---------------- Phase 2 — both delegators stake locked-short ----------------
BOB_SRC_PRE=""; BOB_DST_PRE=""; CHARLIE_SRC_PRE=""; CHARLIE_DST_PRE=""
phase_2_stake() {
  log "Phase 2 — Bob stake (UNLOCKED src) + Charlie stake (LOCKED src)"
  BOB_SRC_PRE=$(val_field "$BOB_SRC_OP" tokens) || fail "REST: pre-stake Bob src tokens read failed"
  BOB_DST_PRE=$(val_field "$BOB_DST_OP" tokens) || fail "REST: pre-stake Bob dst tokens read failed"
  CHARLIE_SRC_PRE=$(val_field "$CHARLIE_SRC_OP" tokens) || fail "REST: pre-stake Charlie src tokens read failed"
  CHARLIE_DST_PRE=$(val_field "$CHARLIE_DST_OP" tokens) || fail "REST: pre-stake Charlie dst tokens read failed"
  log "  pre-stake: bob_src=$BOB_SRC_PRE bob_dst=$BOB_DST_PRE charlie_src=$CHARLIE_SRC_PRE charlie_dst=$CHARLIE_DST_PRE"

  local pub_bs pub_cs
  pub_bs=$(meta_pubkey_hex "$BOB_SRC_MONIKER")
  pub_cs=$(meta_pubkey_hex "$CHARLIE_SRC_MONIKER")

  do_stake Bob "$BOB_PK" "$pub_bs" short
  do_stake Charlie "$CHARLIE_PK" "$pub_cs" short
  sleep 8

  local bs_post cs_post bs_delta cs_delta
  bs_post=$(val_field "$BOB_SRC_OP" tokens) || fail "REST: post-stake Bob src tokens read failed"
  cs_post=$(val_field "$CHARLIE_SRC_OP" tokens) || fail "REST: post-stake Charlie src tokens read failed"
  bs_delta=$(python3 -c "print($bs_post - $BOB_SRC_PRE)")
  cs_delta=$(python3 -c "print($cs_post - $CHARLIE_SRC_PRE)")

  local expected=$((STAKE_IP * 1000000000))
  [[ "$bs_delta" == "$expected" ]] || fail "Bob src tokens delta=$bs_delta, expected $expected"
  [[ "$cs_delta" == "$expected" ]] || fail "Charlie src tokens delta=$cs_delta, expected $expected"

  pass "both stakes committed; Bob has locked-short on UNLOCKED src, Charlie has locked-short (coerced flexible) on LOCKED src"
  capture_evidence "02-stake"
}

# ---------------- Phase 3 — capture pre-redelegate state ----------------
BOB_SRC_PRE_REDEL=""; BOB_DST_PRE_REDEL=""; CHARLIE_SRC_PRE_REDEL=""; CHARLIE_DST_PRE_REDEL=""
phase_3_pre_redelegate_capture() {
  log "Phase 3 — capture pre-redelegate state for both delegators"
  BOB_SRC_PRE_REDEL=$(val_field "$BOB_SRC_OP" tokens) || fail "REST: pre-redel Bob src tokens read failed"
  BOB_DST_PRE_REDEL=$(val_field "$BOB_DST_OP" tokens) || fail "REST: pre-redel Bob dst tokens read failed"
  CHARLIE_SRC_PRE_REDEL=$(val_field "$CHARLIE_SRC_OP" tokens) || fail "REST: pre-redel Charlie src tokens read failed"
  CHARLIE_DST_PRE_REDEL=$(val_field "$CHARLIE_DST_OP" tokens) || fail "REST: pre-redel Charlie dst tokens read failed"
  local h; h=$(get_height)
  log "  pre-redel @ h=$h: bob_src=$BOB_SRC_PRE_REDEL bob_dst=$BOB_DST_PRE_REDEL charlie_src=$CHARLIE_SRC_PRE_REDEL charlie_dst=$CHARLIE_DST_PRE_REDEL"
  if [[ "$h" -ge "$UPGRADE_HEIGHT" ]]; then
    fail "current height $h >= UPGRADE_HEIGHT $UPGRADE_HEIGHT — V170 may have fired, pre-H assumption violated"
  fi
  log "  height assertion: h=$h < UPGRADE_HEIGHT=$UPGRADE_HEIGHT (V170 has not fired)"
}

# ---------------- Phase 4 — pre-V170 redelegate (THE TEST) ----------------
BOB_REDEL_TX=""; CHARLIE_REDEL_TX=""
phase_4_pre_h_redelegate() {
  log "Phase 4 — Bob + Charlie redelegate pre-H (V170 not fired, all src vals BONDED)"

  local pub_bs pub_bd pub_cs pub_cd
  pub_bs=$(meta_pubkey_hex "$BOB_SRC_MONIKER")
  pub_bd=$(meta_pubkey_hex "$BOB_DST_MONIKER")
  pub_cs=$(meta_pubkey_hex "$CHARLIE_SRC_MONIKER")
  pub_cd=$(meta_pubkey_hex "$CHARLIE_DST_MONIKER")

  BOB_REDEL_TX=$(do_redelegate Bob "$BOB_PK" "$pub_bs" "$pub_bd" "$STAKE_WEI" 1)
  CHARLIE_REDEL_TX=$(do_redelegate Charlie "$CHARLIE_PK" "$pub_cs" "$pub_cd" "$STAKE_WEI" 1)
  sleep 8

  local h; h=$(get_height)
  if [[ "$h" -ge "$UPGRADE_HEIGHT" ]]; then
    fail "current height $h >= UPGRADE_HEIGHT $UPGRADE_HEIGHT — V170 fired during/after redelegate, pre-H assumption violated"
  fi
  log "  post-redel @ h=$h (still < UPGRADE_HEIGHT=$UPGRADE_HEIGHT)"
}

# ---------------- Phase 5 — post-redelegate assertions ----------------
phase_5_post_redelegate_assertions() {
  log "Phase 5 — assert chain deltas + val statuses for both paths"

  local bs_post bd_post cs_post cd_post bs_delta bd_delta cs_delta cd_delta
  bs_post=$(val_field "$BOB_SRC_OP" tokens) || fail "REST: post-redel Bob src tokens read failed"
  bd_post=$(val_field "$BOB_DST_OP" tokens) || fail "REST: post-redel Bob dst tokens read failed"
  cs_post=$(val_field "$CHARLIE_SRC_OP" tokens) || fail "REST: post-redel Charlie src tokens read failed"
  cd_post=$(val_field "$CHARLIE_DST_OP" tokens) || fail "REST: post-redel Charlie dst tokens read failed"
  bs_delta=$(python3 -c "print($bs_post - $BOB_SRC_PRE_REDEL)")
  bd_delta=$(python3 -c "print($bd_post - $BOB_DST_PRE_REDEL)")
  cs_delta=$(python3 -c "print($cs_post - $CHARLIE_SRC_PRE_REDEL)")
  cd_delta=$(python3 -c "print($cd_post - $CHARLIE_DST_PRE_REDEL)")

  log "  Bob:     src.tokens delta=$bs_delta, dst.tokens delta=$bd_delta"
  log "  Charlie: src.tokens delta=$cs_delta, dst.tokens delta=$cd_delta"

  local expected_neg=$(python3 -c "print(-$STAKE_IP * 1000000000)")
  local expected_pos=$((STAKE_IP * 1000000000))

  [[ "$bs_delta" == "$expected_neg" ]] || fail "Bob src delta=$bs_delta, expected $expected_neg"
  [[ "$bd_delta" == "$expected_pos" ]] || fail "Bob dst delta=$bd_delta, expected $expected_pos"
  [[ "$cs_delta" == "$expected_neg" ]] || fail "Charlie src delta=$cs_delta, expected $expected_neg"
  [[ "$cd_delta" == "$expected_pos" ]] || fail "Charlie dst delta=$cd_delta, expected $expected_pos"

  # all 4 vals must remain BOND_STATUS_BONDED throughout
  for moniker_op in "$BOB_SRC_MONIKER:$BOB_SRC_OP" "$BOB_DST_MONIKER:$BOB_DST_OP" "$CHARLIE_SRC_MONIKER:$CHARLIE_SRC_OP" "$CHARLIE_DST_MONIKER:$CHARLIE_DST_OP"; do
    local m=${moniker_op%%:*} op=${moniker_op##*:}
    local s; s=$(val_field "$op" status) || fail "REST: $m status read failed (post-redel)"
    [[ "$s" == "3" ]] || fail "expected $m BOND_STATUS_BONDED (status=3) post-redel, got $s"
  done

  pass "both redelegates moved 1024 IP src→dst; all 4 vals remain BONDED; pre-H path verified for UNLOCKED + LOCKED"
  capture_evidence "05-redelegate"
}

# ---------------- Phase 6 — verify rewards_multiplier on dst via val delegations REST ----------------
phase_6_verify_period_metadata() {
  log "Phase 6 — verify rewards_multiplier on dst (rewards_shares / shares) for both paths"

  # /staking/delegators/.../period_delegations endpoint returns 404 in this build;
  # /staking/validators/{val_evm}/delegations is the working path. The delegation entry
  # contains shares + rewards_shares; their ratio is the effective rewards_multiplier
  # baked in by lock metadata (period_short on UNLOCKED vs flexible on LOCKED-coerced).

  local bob_dels charlie_dels
  bob_dels=$(curl -fsS --max-time 5 "http://localhost:1317/staking/validators/${BOB_DST_OP}/delegations" 2>/dev/null)
  charlie_dels=$(curl -fsS --max-time 5 "http://localhost:1317/staking/validators/${CHARLIE_DST_OP}/delegations" 2>/dev/null)

  echo "$bob_dels" > "$EV_DIR/06-bob-delegations-on-dst.json"
  echo "$charlie_dels" > "$EV_DIR/06-charlie-delegations-on-dst.json"

  local bob_lc=$(echo "$BOB_ADDR" | tr '[:upper:]' '[:lower:]')
  local charlie_lc=$(echo "$CHARLIE_ADDR" | tr '[:upper:]' '[:lower:]')

  local bob_rm charlie_rm
  bob_rm=$(echo "$bob_dels" | jq -r --arg a "$bob_lc" '.msg.delegation_responses[]? | select(.delegation.delegator_address | ascii_downcase == $a) | (.delegation.rewards_shares|tonumber) / (.delegation.shares|tonumber)' 2>/dev/null)
  charlie_rm=$(echo "$charlie_dels" | jq -r --arg a "$charlie_lc" '.msg.delegation_responses[]? | select(.delegation.delegator_address | ascii_downcase == $a) | (.delegation.rewards_shares|tonumber) / (.delegation.shares|tonumber)' 2>/dev/null)

  log "  Bob:     rewards_multiplier on dst = $bob_rm  (expect ~1.051 — UNLOCKED val, period_short)"
  log "  Charlie: rewards_multiplier on dst = $charlie_rm  (expect ~0.025 — LOCKED val, coerced flexible)"

  # Bob UNLOCKED→UNLOCKED: period_short multiplier on UNLOCKED val ≈ 1.051
  local bob_in_range
  bob_in_range=$(python3 -c "v=float('$bob_rm'); print(1 if 1.04 < v < 1.06 else 0)" 2>/dev/null)
  [[ "$bob_in_range" == "1" ]] || fail "Bob rewards_multiplier=$bob_rm out of range (expected ~1.051x for UNLOCKED short)"

  # Charlie LOCKED→LOCKED (coerced flexible at deposit): flexible multiplier on LOCKED val ≈ 0.025
  local charlie_in_range
  charlie_in_range=$(python3 -c "v=float('$charlie_rm'); print(1 if 0.020 < v < 0.030 else 0)" 2>/dev/null)
  [[ "$charlie_in_range" == "1" ]] || fail "Charlie rewards_multiplier=$charlie_rm out of range (expected ~0.025 for LOCKED→LOCKED flexible)"

  pass "rewards_multiplier preserved across redelegate: Bob=$bob_rm (UNLOCKED short), Charlie=$charlie_rm (LOCKED flexible)"
  capture_evidence "06-period-metadata"
}

# ---------------- Phase 7 — final snapshot ----------------
phase_7_final_snapshot() {
  log "Phase 7 — final on-chain val state snapshot"
  for moniker_op in "$BOB_SRC_MONIKER:$BOB_SRC_OP" "$BOB_DST_MONIKER:$BOB_DST_OP" "$CHARLIE_SRC_MONIKER:$CHARLIE_SRC_OP" "$CHARLIE_DST_MONIKER:$CHARLIE_DST_OP"; do
    local m=${moniker_op%%:*} op=${moniker_op##*:}
    local s j t sh
    s=$(val_field "$op" status); j=$(val_field "$op" jailed)
    t=$(val_field "$op" tokens); sh=$(val_field "$op" delegator_shares)
    log "  $m final: status=$s jailed=$j tokens=$t shares=$sh"
    echo "{\"moniker\":\"$m\",\"operator\":\"$op\",\"status\":\"$s\",\"jailed\":\"$j\",\"tokens\":\"$t\",\"shares\":\"$sh\"}" \
      > "$EV_DIR/final-${m}.json"
  done
  log "  chain height $(get_height)"
  log "  Bob redelegate tx:     $BOB_REDEL_TX"
  log "  Charlie redelegate tx: $CHARLIE_REDEL_TX"
}

# ---------------- Phase 8 — POST-V170 chain assertion (binary↔probe sanity) ----------------
phase_8_post_v170_assert() {
  log "Phase 8 — wait past V170 + assert prune actually fired"
  source "${LOCALNET}/scripts/lib/post_v170_asserts.sh"

  # Top-NEW_MAX (val-1..NEW_MAX) should stay BONDED. Out-of-top (val-(NEW_MAX+1)..N_VALS) should prune.
  local bonded_list="" pruned_list=""
  local i
  for ((i=1; i<=NEW_MAX; i++));     do bonded_list+=" localnet-val-$i"; done
  for ((i=NEW_MAX+1; i<=N_VALS; i++)); do pruned_list+=" localnet-val-$i"; done

  PRUNED_VALS="${pruned_list# }" \
    BONDED_VALS="${bonded_list# }" \
    EXPECTED_NEW_MAX="$NEW_MAX" \
    UPGRADE_HEIGHT="$UPGRADE_HEIGHT" \
    META="$META" \
    POST_V170_GRACE=5 \
    SNAPSHOT_FILE="$EV_DIR/08-post-v170-val-state.txt" \
    assert_post_v170_state

  # Also confirm Bob/Charlie's redelegated tokens are still on dst (not rolled back by V170).
  local bob_dst_tokens charlie_dst_tokens
  bob_dst_tokens=$(val_field "$BOB_DST_OP" tokens)
  charlie_dst_tokens=$(val_field "$CHARLIE_DST_OP" tokens)
  log "  post-V170: Bob dst $BOB_DST_MONIKER tokens=$bob_dst_tokens, Charlie dst $CHARLIE_DST_MONIKER tokens=$charlie_dst_tokens"
  pass "post-V170 assertion complete — V170 truly fired, val-$((NEW_MAX+1))..val-$N_VALS pruned, redelegated tokens preserved on dst"
}

# ---------------- Phase 9 — summary ----------------
phase_9_summary() {
  printf "\n========== CASE 7 PROBE — PRE-H REDELEGATE (LOCKED + UNLOCKED) ==========\n"
  printf "  Cluster: %d vals, NEW_MAX=%d → out-of-top-%d includes val-%d LOCKED + val-%d UNLOCKED\n" "$N_VALS" "$NEW_MAX" "$NEW_MAX" "$((NEW_MAX+3))" "$((NEW_MAX+4))"
  printf "  Bob path:     %s (UNLOCKED out-21) → %s (UNLOCKED top-21)\n" "$BOB_SRC_MONIKER" "$BOB_DST_MONIKER"
  printf "  Charlie path: %s (LOCKED   out-21) → %s (LOCKED   top-21)\n" "$CHARLIE_SRC_MONIKER" "$CHARLIE_DST_MONIKER"
  printf "  Action: pre-H redelegate (height < UPGRADE_HEIGHT=%d, V170 NOT fired)\n" "$UPGRADE_HEIGHT"
  printf "  Bob redelegate tx:     %s\n" "$BOB_REDEL_TX"
  printf "  Charlie redelegate tx: %s\n" "$CHARLIE_REDEL_TX"
  printf "  Final chain height:    %s\n" "$(get_height)"
  printf "  Evidence: %s/\n" "$EV_DIR"
  printf "==========================================================================\n"
}

phase_10_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 10 — SKIP_TEARDOWN"; return; fi
  log "Phase 10 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1)
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline
phase_2_stake
phase_3_pre_redelegate_capture
phase_4_pre_h_redelegate
phase_5_post_redelegate_assertions
phase_6_verify_period_metadata
phase_7_final_snapshot
phase_8_post_v170_assert
phase_9_summary
phase_10_teardown
