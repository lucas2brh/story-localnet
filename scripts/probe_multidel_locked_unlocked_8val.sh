#!/usr/bin/env bash
# probe_multidel_locked_unlocked_8val.sh
#
# 8-val NEW_MAX=4 adaptation of probe_multidel_locked_unlocked_after_prune.sh.
# Original ran on 20-val with val-17 (UNLOCKED) + val-18 (LOCKED) cap-pruned at
# V170=50 (NEW_MAX=16). This version: 8-val with val-5/6 cap-pruned at V170=70
# (NEW_MAX=4). Same multi-delegator + locked/unlocked period coverage.
#
# Tests v1.7.0 prune handler for multi-delegator scenarios across both
# LOCKED and UNLOCKED validator types, with CL+EL log evidence capture.
#
# Genesis pre-conditions:
#   - val-5 = UNLOCKED (support_token_type=1) — allows all 4 staking periods
#   - val-6 = LOCKED   (support_token_type=0) — only flexible delegations
#   - Both rank 5 / 6 are pruned at V170 (h=70)
#   - staking.params.periods[3].duration = 180s (runtime tweak via Phase 0,
#     shortened from default 900s for tractable probe wallclock)
#
# Delegators (Anvil[0..3]): Alice / Bob / Carol / Dave
#
# Stake matrix (5 stakes):
#   Alice → val-5 flexible (period=0)        1024 IP
#   Bob   → val-5 locked-1 60s  (period=1)   1024 IP
#   Carol → val-5 locked-2 120s (period=2)   1024 IP
#   Dave  → val-5 locked-3 180s (period=3)   1024 IP
#   Alice → val-6 flexible (period=0)        1024 IP
#
# Probe self-bug FIX vs original probe (2026-04-30):
#   Captures each "Delegation ID: N" from `validator stake` stdout and stores
#   per delegator. Each unstake uses the real id. Original used --delegation-id=0
#   for all, which silently no-op'd for Bob/Carol/Dave (their actual ids on
#   val-5 were 1/2/3 — second-stake-onwards auto-increments per delegator on
#   the same val). Verified pattern in probe_locked_del_redelegate_after_prune.sh.
#
# Phases:
#   0  boot fresh 8-val with UNLOCKED_VALS=5, MAX_VALIDATORS_INIT=8
#   1  pre-upgrade baseline (h=10) + fund Bob/Carol/Dave EVM wallets
#   2  5 stakes pre-upgrade, capture delegation_id per delegator
#   3  wait past V170 (h>=80) → both vals pruned to UNBONDED
#   4  operator on val-5 + operator on val-6 each 100% self-unstake → both jailed
#   5  Alice/Bob/Carol unstake from val-5 with real delegation_ids (locks already expired by ~h=80+ on val-5 short=60s, medium=120s; Dave deferred to Phase 7)
#   6  Alice unstake from val-6 (flexible, id=0)
#   7  wait Dave's 180s lock to expire, Dave unstake from val-5 with real id
#   8  wait unbonding mature, verify all 5 EVM balances credited
#   9  CL+EL log capture (codified) per phase
#  10  summary + final on-chain snapshots
#  11  optional teardown
#
# Usage:
#   ./scripts/probe_multidel_locked_unlocked_8val.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_multidel_locked_unlocked_8val.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-70}
PRE_STAKE_BLOCK=${PRE_STAKE_BLOCK:-10}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-80}
UNBONDING_TIME=${UNBONDING_TIME:-10s}    # patched explicitly so V170-pruned vals reach status=1 by POST_UPGRADE_BLOCK; default genesis is 3600s (per probe_redelegate_silent_rollback.sh)
N_VALS=${N_VALS:-8}
MAX_VALIDATORS_INIT=${MAX_VALIDATORS_INIT:-8}
NEW_MAX=${NEW_MAX:-4}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
EV_DIR="${LOCALNET}/tmp/probe-multidel-evidence-8val"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

# 4 anvil dev keys (well-known)
ALICE_PK=${ALICE_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ALICE_ADDR=${ALICE_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
BOB_PK=${BOB_PK:-59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}
BOB_ADDR=${BOB_ADDR:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}
CAROL_PK=${CAROL_PK:-5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}
CAROL_ADDR=${CAROL_ADDR:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}
DAVE_PK=${DAVE_PK:-7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6}
DAVE_ADDR=${DAVE_ADDR:-0x90F79bf6EB2c4f870365E785982E1f101E93b906}

UNLOCKED_VAL_MONIKER=${UNLOCKED_VAL_MONIKER:-localnet-val-5}
LOCKED_VAL_MONIKER=${LOCKED_VAL_MONIKER:-localnet-val-6}
UNLOCKED_VALS_GENESIS=${UNLOCKED_VALS_GENESIS:-5}  # 1-based index passed to assemble_genesis.sh
STAKE_IP=${STAKE_IP:-1024}
STAKE_WEI="${STAKE_IP}000000000000000000"
DAVE_LOCK_SEC=${DAVE_LOCK_SEC:-180}

# Wallet seed: how much IP Alice transfers to Bob/Carol/Dave at start
SEED_IP=${SEED_IP:-2000}
SEED_WEI="${SEED_IP}000000000000000000"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[multidel-8val]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[multidel-8val]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[multidel-8val]${C_RESET} FAIL %s\n" "$*"; exit 1; }
FAILS=0

# Per-delegator delegation IDs on val-5 (captured in Phase 2)
ALICE_VAL5_ID=""; BOB_VAL5_ID=""; CAROL_VAL5_ID=""; DAVE_VAL5_ID=""
ALICE_VAL6_ID=""

# ---------------- chain query helpers ----------------
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
  local body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${1}" 2>/dev/null)
  [[ -z $body ]] && { echo "GONE"; return; }
  jq -r ".msg.validator.${2} // \"GONE\"" <<<"$body"
}

meta_pubkey_hex() { local b64; b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META"); echo -n "$b64" | base64 -d | xxd -p -c 66; }
meta_op_evm()     { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }
meta_privkey()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }

# do_stake who pk pubkey period
# Returns delegation_id integer on stdout (parsed from CLI output).
# All log/CLI-echo output is routed to stderr so caller's $() captures only the id.
# Fails fast on non-zero rc.
do_stake() {
  local who=$1 pk=$2 pubkey=$3 period=$4
  log "  $who stake $period (${STAKE_IP} IP) → ${pubkey:0:16}..." >&2
  local out rc
  out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator stake \
    --validator-pubkey "$pubkey" --stake "$STAKE_WEI" --staking-period "$period" \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -10 >&2
  [[ $rc -eq 0 ]] || { printf "${C_RED}[multidel-8val]${C_RESET} FAIL %s\n" "$who stake rc=$rc — fatal CLI error" >&2; exit 1; }
  local id_line
  id_line=$(printf '%s\n' "$out" | grep -oE "Delegation ID: [0-9]+" | tail -1)
  [[ -n "$id_line" ]] || { printf "${C_RED}[multidel-8val]${C_RESET} FAIL %s\n" "$who stake: no 'Delegation ID: N' line in CLI output" >&2; exit 1; }
  echo "${id_line##*: }"
}

# do_unstake who pk pubkey amount_wei delegation_id
do_unstake() {
  local who=$1 pk=$2 pubkey=$3 amt=$4 del_id=$5
  log "  $who unstake $amt wei (delegation-id=$del_id)"
  local out rc
  out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pubkey" --unstake "$amt" --delegation-id "$del_id" \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -10
  [[ $rc -eq 0 ]] || fail "$who unstake rc=$rc — fatal CLI error"
}

# ---------------- evidence capture (CL/EL logs) ----------------
capture_evidence() {
  local label=$1
  local since="${PHASE_START_TS:-1m}"
  mkdir -p "$EV_DIR"

  # CL: bootnode + val-5/6 nodes — filtered events
  for c in bootnode1-node validator5-node validator6-node; do
    docker logs --since "$since" "$c" 2>&1 \
      | grep -E 'ABCI call: (PrepareProposal|ProcessProposal|FinalizeBlock|Commit)|MaxValidators reduction|MsgUndelegate|MsgDelegate|module=evmstaking|module=x/staking|RemoveValidator|jail|panic|CONSENSUS FAILURE' \
      > "$EV_DIR/cl-${c}-${label}.log" 2>/dev/null || true
  done

  # EL: val-5/6 geth + rpc-geth
  for c in validator5-geth validator6-geth rpc1-geth; do
    docker logs --since "$since" "$c" 2>&1 \
      | grep -E 'Imported new|Chain head was updated|Beacon client|Engine API|payload' \
      > "$EV_DIR/el-${c}-${label}.log" 2>/dev/null || true
  done

  # Liveness scan — any panic/CONSENSUS FAILURE across all val-nodes
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

# ---------------- Phase 0 — fresh 8-val localnet ----------------
phase_0_start() {
  log "Phase 0 — start fresh ${N_VALS}-val localnet (MaxValidators_init=$MAX_VALIDATORS_INIT, NEW_MAX=$NEW_MAX), val-5 UNLOCKED, val-6 LOCKED, period[3]=180s"
  if docker ps --format '{{.Names}}' | grep -qE '^(validator|bootnode|rpc)[0-9]*-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1); sleep 5
  fi

  bash "${LOCALNET}/scripts/generate_N_validators.sh" "$N_VALS" 2>&1 | tail -1
  bash "${LOCALNET}/scripts/fetch_mainnet_distribution.sh" "$N_VALS" 2>&1 | tail -1
  UNLOCKED_VALS="$UNLOCKED_VALS_GENESIS" MAX_VALIDATORS_INIT="$MAX_VALIDATORS_INIT" STORY_BIN="$STORY_BIN" \
    bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N_VALS" 2>&1 | tail -1

  # Genesis runtime tweaks (not committed):
  #  - period[1].duration: 1800s → 60s   (short, Bob's lock)
  #  - period[2].duration: 1800s → 120s  (medium, Carol's lock)
  #  - period[3].duration: 900s → 180s   (long, Dave's lock)
  #    Without these, default localnet has all three at 1800s/180s — Bob/Carol
  #    unstake calls would be rejected with "period delegation not completed"
  #    even though probe wallclock far exceeds the original probe's stated
  #    60s/120s lock durations.
  #  - unbonding_time: 3600s → 10s so V170-pruned vals reach status=1 UNBONDED
  #    before Phase 3 assertion (assemble_genesis.sh does NOT reset this field;
  #    matches probe_redelegate_silent_rollback.sh:159 pattern)
  local genesis_path="${LOCALNET}/config/story/genesis-node.json"
  local tmp; tmp=$(mktemp)
  jq --arg ubt "$UNBONDING_TIME" '
    .app_state.staking.params.periods[1].duration = "60s"
    | .app_state.staking.params.periods[2].duration = "120s"
    | .app_state.staking.params.periods[3].duration = "180s"
    | .app_state.staking.params.unbonding_time = $ubt
  ' "$genesis_path" > "$tmp" && mv "$tmp" "$genesis_path"
  local p1 p2 p3 ubt
  p1=$(jq -r '.app_state.staking.params.periods[1].duration' "$genesis_path")
  p2=$(jq -r '.app_state.staking.params.periods[2].duration' "$genesis_path")
  p3=$(jq -r '.app_state.staking.params.periods[3].duration' "$genesis_path")
  ubt=$(jq -r '.app_state.staking.params.unbonding_time' "$genesis_path")
  [[ "$p1" == "60s" ]] || fail "failed to set period[1]=60s, got $p1"
  [[ "$p2" == "120s" ]] || fail "failed to set period[2]=120s, got $p2"
  [[ "$p3" == "180s" ]] || fail "failed to set period[3]=180s, got $p3"
  [[ "$ubt" == "$UNBONDING_TIME" ]] || fail "failed to set unbonding_time=$UNBONDING_TIME, got $ubt"
  log "  genesis tweaks: period[1]=60s period[2]=120s period[3]=180s, unbonding_time=$UNBONDING_TIME"

  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -1)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && { fail "rpc1 didn't sync in 90s"; exit 1; }
    sleep 3
  done

  PHASE_START_TS=$(date -u +%Y-%m-%dT%H:%M:%S)
  mkdir -p "$EV_DIR"
}

# ---------------- Phase 1 — baseline + seed Bob/Carol/Dave ----------------
VAL5_OP=""; VAL6_OP=""
phase_1_baseline() {
  log "Phase 1 — wait h=$PRE_STAKE_BLOCK + capture baseline + seed Bob/Carol/Dave"
  wait_height "$PRE_STAKE_BLOCK" >/dev/null
  VAL5_OP=$(meta_op_evm "$UNLOCKED_VAL_MONIKER")
  VAL6_OP=$(meta_op_evm "$LOCKED_VAL_MONIKER")
  local s5 s6 t5 t6
  s5=$(val_field "$VAL5_OP" status); t5=$(val_field "$VAL5_OP" tokens)
  s6=$(val_field "$VAL6_OP" status); t6=$(val_field "$VAL6_OP" tokens)
  log "  val-5 (UNLOCKED): op=$VAL5_OP status=$s5 tokens=$t5"
  log "  val-6 (LOCKED):   op=$VAL6_OP status=$s6 tokens=$t6"
  [[ "$s5" == "3" && "$s6" == "3" ]] || fail "expected both BONDED pre-upgrade, got val5=$s5 val6=$s6"

  # Sanity check support_token_type — uses "// 0" fallback for proto3 zero-value omission
  # (see probe_create_val_across_v170.sh and SoT story-l1-staking-module.md)
  local t5_type t6_type
  t5_type=$(curl -fsS "http://localhost:1317/staking/validators/${VAL5_OP}" 2>/dev/null \
    | jq -r ".msg.validator.support_token_type // 0")
  t6_type=$(curl -fsS "http://localhost:1317/staking/validators/${VAL6_OP}" 2>/dev/null \
    | jq -r ".msg.validator.support_token_type // 0")
  log "  val-5 support_token_type=$t5_type (expect 1 UNLOCKED)"
  log "  val-6 support_token_type=$t6_type (expect 0 LOCKED)"
  [[ "$t5_type" == "1" ]] || fail "val-5 expected UNLOCKED (type=1), got $t5_type"
  [[ "$t6_type" == "0" ]] || fail "val-6 expected LOCKED (type=0), got $t6_type"

  # Seed Bob/Carol/Dave from Alice (~$SEED_IP IP each for stake + gas)
  for who_addr in "Bob:$BOB_ADDR" "Carol:$CAROL_ADDR" "Dave:$DAVE_ADDR"; do
    local who=${who_addr%%:*} addr=${who_addr##*:}
    cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$addr" \
      --value "${SEED_IP}ether" --legacy --gas-price 50gwei >/dev/null 2>&1
    local bal; bal=$(get_evm_balance "$addr")
    log "  seeded $who $addr balance=$bal wei"
  done
  pass "baseline + seed complete (val-5 UNLOCKED, val-6 LOCKED, both BONDED)"
  capture_evidence "01-baseline"
}

# ---------------- Phase 2 — 5 stakes, capture delegation_ids ----------------
ALICE_BAL_PRE=""; BOB_BAL_PRE=""; CAROL_BAL_PRE=""; DAVE_BAL_PRE=""
DAVE_STAKE_TS=""
phase_2_stakes() {
  log "Phase 2 — 5 stakes pre-upgrade (capture delegation_id per delegator)"
  ALICE_BAL_PRE=$(get_evm_balance "$ALICE_ADDR")
  BOB_BAL_PRE=$(get_evm_balance "$BOB_ADDR")
  CAROL_BAL_PRE=$(get_evm_balance "$CAROL_ADDR")
  DAVE_BAL_PRE=$(get_evm_balance "$DAVE_ADDR")
  log "  EVM balances pre-stake: Alice=$ALICE_BAL_PRE Bob=$BOB_BAL_PRE Carol=$CAROL_BAL_PRE Dave=$DAVE_BAL_PRE"

  local v5_pre v6_pre
  v5_pre=$(val_field "$VAL5_OP" tokens)
  v6_pre=$(val_field "$VAL6_OP" tokens)
  log "  pre-stake val tokens: val-5=$v5_pre val-6=$v6_pre"

  local pub5 pub6
  pub5=$(meta_pubkey_hex "$UNLOCKED_VAL_MONIKER")
  pub6=$(meta_pubkey_hex "$LOCKED_VAL_MONIKER")

  ALICE_VAL5_ID=$(do_stake Alice "$ALICE_PK" "$pub5" flexible)
  BOB_VAL5_ID=$(do_stake   Bob   "$BOB_PK"   "$pub5" short)
  CAROL_VAL5_ID=$(do_stake Carol "$CAROL_PK" "$pub5" medium)
  DAVE_VAL5_ID=$(do_stake  Dave  "$DAVE_PK"  "$pub5" long)
  DAVE_STAKE_TS=$(date +%s)
  log "  Dave stake timestamp=$DAVE_STAKE_TS (lock expires at ~$((DAVE_STAKE_TS + DAVE_LOCK_SEC)))"
  ALICE_VAL6_ID=$(do_stake Alice "$ALICE_PK" "$pub6" flexible)

  log "  delegation_ids captured: Alice(val5)=$ALICE_VAL5_ID Bob(val5)=$BOB_VAL5_ID Carol(val5)=$CAROL_VAL5_ID Dave(val5)=$DAVE_VAL5_ID Alice(val6)=$ALICE_VAL6_ID"
  for id_var in ALICE_VAL5_ID BOB_VAL5_ID CAROL_VAL5_ID DAVE_VAL5_ID ALICE_VAL6_ID; do
    local v=${!id_var}
    [[ -n "$v" && "$v" =~ ^[0-9]+$ ]] || fail "$id_var not a number: '$v'"
  done

  sleep 8
  local t5 t6 sh5 sh6
  t5=$(val_field "$VAL5_OP" tokens);  sh5=$(val_field "$VAL5_OP" delegator_shares)
  t6=$(val_field "$VAL6_OP" tokens);  sh6=$(val_field "$VAL6_OP" delegator_shares)
  log "  val-5 post-stake: tokens=$t5 shares=$sh5 (expected 4-del shape: Alice/Bob/Carol/Dave)"
  log "  val-6 post-stake: tokens=$t6 shares=$sh6 (expected 1-del shape: Alice flex)"

  # Token-delta assertion: catches silent stake failure
  local expected_v5_delta=$((4 * STAKE_IP * 1000000000))   # 4 * 1024 IP * 1e9 = 4096e9 stake
  local expected_v6_delta=$((1 * STAKE_IP * 1000000000))   # 1 * 1024 IP * 1e9 = 1024e9 stake
  local v5_delta=$((t5 - v5_pre))
  local v6_delta=$((t6 - v6_pre))
  [[ "$v5_delta" == "$expected_v5_delta" ]] || fail "val-5 token delta=$v5_delta, expected $expected_v5_delta (4 stakes × 1024 IP). Some stake calls silently failed."
  [[ "$v6_delta" == "$expected_v6_delta" ]] || fail "val-6 token delta=$v6_delta, expected $expected_v6_delta (1 stake × 1024 IP)."
  pass "5 stakes committed (val-5 +$v5_delta, val-6 +$v6_delta), 4+1 multi-del shape verified, all 5 delegation_ids captured"
  capture_evidence "02-stakes"
}

# ---------------- Phase 3 — V170 prune ----------------
phase_3_prune() {
  log "Phase 3 — wait past V170=$UPGRADE_HEIGHT to h=$POST_UPGRADE_BLOCK"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  local s5 s6
  s5=$(val_field "$VAL5_OP" status); s6=$(val_field "$VAL6_OP" status)
  log "  val-5 post-upgrade status=$s5"
  log "  val-6 post-upgrade status=$s6"
  # Both vals are rank 5/6 of 8 → bottom 4 → cap-pruned. Post-V170 they
  # transition BONDED → UNBONDING; with localnet 10s unbonding_time they
  # reach UNBONDED (status=1) by POST_UPGRADE_BLOCK.
  [[ "$s5" == "1" ]] || fail "expected val-5 UNBONDED (status=1) post-upgrade, got $s5"
  [[ "$s6" == "1" ]] || fail "expected val-6 UNBONDED (status=1) post-upgrade, got $s6"
  pass "both vals pruned to UNBONDED carrying multi-del shape"
  capture_evidence "03-post-prune"
}

# ---------------- Phase 4 — operator self-unstake on both vals ----------------
phase_4_self_unstake() {
  log "Phase 4 — operator on val-5 + val-6 each 100% self-unstake (→ jailed)"
  for moniker_var in "$UNLOCKED_VAL_MONIKER" "$LOCKED_VAL_MONIKER"; do
    local op_addr op_pk pub tokens
    op_addr=$(meta_op_evm "$moniker_var")
    op_pk=$(meta_privkey "$moniker_var")
    pub=$(meta_pubkey_hex "$moniker_var")
    tokens=$(val_field "$op_addr" tokens)

    # fund operator gas
    cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$op_addr" \
      --value 10ether --legacy --gas-price 50gwei >/dev/null 2>&1

    # operator self-del stake = total tokens - external dels (each 1024 IP * 1e9 = 1024e9 stake)
    # Convert stake → wei: × 1e9
    local self_stake_amount  # in wei
    if [[ "$moniker_var" == "$UNLOCKED_VAL_MONIKER" ]]; then
      local ext=$((4 * STAKE_IP * 1000000000))
      self_stake_amount=$(python3 -c "print(($tokens - $ext) * 1000000000)")
    else
      local ext=$((1 * STAKE_IP * 1000000000))
      self_stake_amount=$(python3 -c "print(($tokens - $ext) * 1000000000)")
    fi

    # Operator's own self-delegation always has id=0 (first delegation on the val).
    do_unstake "${moniker_var}-op" "$op_pk" "$pub" "$self_stake_amount" 0
    sleep 5
    local s j t
    s=$(val_field "$op_addr" status); j=$(val_field "$op_addr" jailed); t=$(val_field "$op_addr" tokens)
    log "  $moniker_var post-self-unstake: status=$s jailed=$j tokens=$t"
    [[ "$s" == "1" ]]      || fail "$moniker_var expected UNBONDED, got $s"
    [[ "$j" == "true" ]]   || fail "$moniker_var expected jailed=true, got $j"
  done
  pass "both operators self-unstaked, both vals jailed + UNBONDED with ext dels retained"
  capture_evidence "04-post-self-unstake"
}

# ---------------- Phase 5 — Alice/Bob/Carol unstake from val-5 (real ids) ----------------
phase_5_short_locks_unstake() {
  log "Phase 5 — Alice/Bob/Carol unstake from val-5 with REAL delegation_ids (locks already expired: short 60s + medium 120s long-passed by ~h=80+)"
  local pub5; pub5=$(meta_pubkey_hex "$UNLOCKED_VAL_MONIKER")
  do_unstake Alice "$ALICE_PK" "$pub5" "$STAKE_WEI" "$ALICE_VAL5_ID"
  sleep 3
  do_unstake Bob   "$BOB_PK"   "$pub5" "$STAKE_WEI" "$BOB_VAL5_ID"
  sleep 3
  do_unstake Carol "$CAROL_PK" "$pub5" "$STAKE_WEI" "$CAROL_VAL5_ID"
  sleep 3
  pass "Alice/Bob/Carol unstake calls submitted with real ids ($ALICE_VAL5_ID/$BOB_VAL5_ID/$CAROL_VAL5_ID)"
  capture_evidence "05-short-locks-unstake"
}

# ---------------- Phase 6 — Alice unstake from val-6 ----------------
phase_6_alice_locked_val_unstake() {
  log "Phase 6 — Alice unstake from val-6 (LOCKED val, flexible delegation, id=$ALICE_VAL6_ID)"
  local pub6; pub6=$(meta_pubkey_hex "$LOCKED_VAL_MONIKER")
  do_unstake Alice "$ALICE_PK" "$pub6" "$STAKE_WEI" "$ALICE_VAL6_ID"
  sleep 3
  pass "Alice val-6 unstake call submitted"
  capture_evidence "06-alice-locked-val"
}

# ---------------- Phase 7 — wait Dave's lock + unstake ----------------
phase_7_dave_unstake() {
  log "Phase 7 — wait Dave's $DAVE_LOCK_SEC s lock to expire then unstake from val-5 (id=$DAVE_VAL5_ID)"
  local now; now=$(date +%s)
  local target=$((DAVE_STAKE_TS + DAVE_LOCK_SEC + 5))
  local wait_sec=$((target - now))
  if [[ $wait_sec -gt 0 ]]; then
    log "  sleeping ${wait_sec}s for Dave's lock to expire"
    sleep "$wait_sec"
  fi
  local pub5; pub5=$(meta_pubkey_hex "$UNLOCKED_VAL_MONIKER")
  do_unstake Dave "$DAVE_PK" "$pub5" "$STAKE_WEI" "$DAVE_VAL5_ID"
  sleep 5
  pass "Dave unstake call submitted post lock-expiry"
  capture_evidence "07-dave-post-lock"
}

# ---------------- Phase 8 — verify EVM balance recovery ----------------
phase_8_verify_recovery() {
  log "Phase 8 — wait unbonding mature (15s), verify all 4 EVM balances credited (= #681 fix verification)"
  sleep 15

  local alice_post bob_post carol_post dave_post
  alice_post=$(get_evm_balance "$ALICE_ADDR")
  bob_post=$(get_evm_balance "$BOB_ADDR")
  carol_post=$(get_evm_balance "$CAROL_ADDR")
  dave_post=$(get_evm_balance "$DAVE_ADDR")

  log "  Alice: pre=$ALICE_BAL_PRE post=$alice_post (staked 2× val-5+val-6 = 2048 IP)"
  log "  Bob:   pre=$BOB_BAL_PRE post=$bob_post (staked 1× val-5 short = 1024 IP)"
  log "  Carol: pre=$CAROL_BAL_PRE post=$carol_post (staked 1× val-5 medium = 1024 IP)"
  log "  Dave:  pre=$DAVE_BAL_PRE post=$dave_post (staked 1× val-5 long = 1024 IP)"

  # PASS criterion: post >= pre - 50 IP slack (gas only; full stake recovered)
  # FAIL = same as #681 original — stake still locked in val, EVM never credited
  # Note: avoid bash 4+ `${who^^}` uppercase expansion — macOS default bash 3.2
  # silently fails with "bad substitution" and exits the loop, leaving FAILS=0
  # (false PASS). Use explicit name list instead.
  for tuple in "Alice:$ALICE_ADDR:$ALICE_BAL_PRE" "Bob:$BOB_ADDR:$BOB_BAL_PRE" "Carol:$CAROL_ADDR:$CAROL_BAL_PRE" "Dave:$DAVE_ADDR:$DAVE_BAL_PRE"; do
    local who=${tuple%%:*}
    local rest=${tuple#*:}
    local addr=${rest%%:*}
    local pre=${rest#*:}
    local post; post=$(get_evm_balance "$addr")
    local lower_bound; lower_bound=$(python3 -c "print($pre - 50000000000000000000)")
    if python3 -c "import sys; sys.exit(0 if $post > $lower_bound else 1)"; then
      pass "$who EVM balance recovered: pre=$pre post=$post (delta within 50 IP gas slack)"
    else
      FAILS=$((FAILS+1))
      printf "${C_RED}[multidel-8val]${C_RESET} FAIL %s\n" "$who EVM balance NOT recovered: pre=$pre post=$post (#681 reproduces)"
    fi
  done

  capture_evidence "08-final-balances"
}

# ---------------- Phase 9 — final on-chain snapshots ----------------
phase_9_final_snapshots() {
  log "Phase 9 — final on-chain val state snapshots"
  for moniker_op in "$UNLOCKED_VAL_MONIKER:$VAL5_OP" "$LOCKED_VAL_MONIKER:$VAL6_OP"; do
    local moniker=${moniker_op%%:*} op=${moniker_op##*:}
    local s j t sh
    s=$(val_field "$op" status); j=$(val_field "$op" jailed)
    t=$(val_field "$op" tokens); sh=$(val_field "$op" delegator_shares)
    log "  $moniker final: status=$s jailed=$j tokens=$t shares=$sh"
    echo "{\"moniker\":\"$moniker\",\"operator\":\"$op\",\"status\":\"$s\",\"jailed\":\"$j\",\"tokens\":\"$t\",\"shares\":\"$sh\"}" \
      > "$EV_DIR/final-${moniker}.json"
  done
  log "  chain height $(get_height)"
  log "  bonded count $(curl -fsS 'http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100' 2>/dev/null | jq '.msg.validators | length')"

  # Persist probe metadata for evidence reproducibility
  cat > "$EV_DIR/probe-metadata.json" <<EOF
{
  "probe": "probe_multidel_locked_unlocked_8val.sh",
  "run_ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "N_VALS": $N_VALS,
  "MAX_VALIDATORS_INIT": $MAX_VALIDATORS_INIT,
  "NEW_MAX": $NEW_MAX,
  "UPGRADE_HEIGHT": $UPGRADE_HEIGHT,
  "POST_UPGRADE_BLOCK": $POST_UPGRADE_BLOCK,
  "UNLOCKED_VAL": "$UNLOCKED_VAL_MONIKER",
  "LOCKED_VAL": "$LOCKED_VAL_MONIKER",
  "delegation_ids": {
    "alice_val5": $ALICE_VAL5_ID,
    "bob_val5": $BOB_VAL5_ID,
    "carol_val5": $CAROL_VAL5_ID,
    "dave_val5": $DAVE_VAL5_ID,
    "alice_val6": $ALICE_VAL6_ID
  },
  "balances_pre": {
    "alice": "$ALICE_BAL_PRE",
    "bob": "$BOB_BAL_PRE",
    "carol": "$CAROL_BAL_PRE",
    "dave": "$DAVE_BAL_PRE"
  }
}
EOF
  log "  probe-metadata.json written"
}

# ---------------- Phase 10 — summary ----------------
phase_10_summary() {
  printf "\n========== MULTIDEL LOCKED+UNLOCKED 8-VAL PROBE CONCLUSIONS ==========\n"
  printf "  val-5 (UNLOCKED, 4-del) final: $(cat "$EV_DIR/final-${UNLOCKED_VAL_MONIKER}.json")\n"
  printf "  val-6 (LOCKED, 1-del)   final: $(cat "$EV_DIR/final-${LOCKED_VAL_MONIKER}.json")\n"
  printf "  Final chain height: $(get_height)\n"
  printf "  Total FAILs: %d\n" "$FAILS"
  printf "  Evidence: $EV_DIR/\n"
  printf "  Outcome: %s\n" "$( [[ $FAILS -eq 0 ]] && echo 'PASS (all 4 EVM balances credited — #681 fixed)' || echo "FAIL (#681 reproduces — $FAILS delegator(s) stranded)" )"
  printf "======================================================================\n"
}

phase_11_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 11 — SKIP_TEARDOWN"; return; fi
  log "Phase 11 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1)
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline
phase_2_stakes
phase_3_prune
phase_4_self_unstake
phase_5_short_locks_unstake
phase_6_alice_locked_val_unstake
phase_7_dave_unstake
phase_8_verify_recovery
phase_9_final_snapshots
phase_10_summary
phase_11_teardown

[[ $FAILS -eq 0 ]] || exit 1
