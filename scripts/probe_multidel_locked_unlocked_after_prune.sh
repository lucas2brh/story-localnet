#!/usr/bin/env bash
# probe_multidel_locked_unlocked_after_prune.sh
#
# Tests v1.7.0 prune handler for multi-delegator scenarios across both
# LOCKED and UNLOCKED validator types, with CL+EL log evidence capture.
#
# Genesis pre-conditions (set up by phase 0):
#   - val-17 = UNLOCKED (support_token_type=1) — allows all 4 staking periods
#   - val-18 = LOCKED   (support_token_type=0) — only flexible delegations
#   - Both rank 17/18 are pruned at V170 (h=50)
#   - staking.params.periods[3].duration = 180s (committed in genesis-node.json,
#     shortened from default 900s for tractable probe wallclock)
#
# Delegators (Anvil[0..3]): Alice / Bob / Carol / Dave
#
# Stake matrix:
#   Alice → val-17 flexible (period=0)        1024 IP
#   Bob   → val-17 locked-1 60s  (period=1)   1024 IP
#   Carol → val-17 locked-2 120s (period=2)   1024 IP
#   Dave  → val-17 locked-3 180s (period=3)   1024 IP
#   Alice → val-18 flexible (period=0)        1024 IP   (only allowed period for LOCKED val)
#
# Phases:
#   0  boot fresh 20-val with UNLOCKED_VALS=17
#   1  pre-upgrade baseline + fund Bob/Carol/Dave EVM wallets
#   2  5 stake calls (4 to val-17 + 1 to val-18)
#   3  wait past V170 → both vals pruned to UNBONDED
#   4  operator on val-17 + operator on val-18 each fund + 100% self-unstake → both jailed
#   5  Alice/Bob/Carol unstake from val-17 (their locks already expired by ~h=70+)
#   6  Alice unstake from val-18 (flexible)
#   7  wait Dave's 180s lock to expire, Dave unstake from val-17
#   8  wait unbonding mature, verify all 5 EVM balances credited
#   9  CL+EL log capture (codified): bootnode + val-17/18 node + geth logs to evidence dir
#  10  summary
#  11  optional teardown
#
# Usage:
#   ./scripts/probe_multidel_locked_unlocked_after_prune.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_multidel_locked_unlocked_after_prune.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
PRE_STAKE_BLOCK=${PRE_STAKE_BLOCK:-10}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-65}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
EV_DIR="${LOCALNET}/tmp/probe-multidel-evidence"
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

UNLOCKED_VAL_MONIKER=${UNLOCKED_VAL_MONIKER:-localnet-val-17}
LOCKED_VAL_MONIKER=${LOCKED_VAL_MONIKER:-localnet-val-18}
STAKE_IP=${STAKE_IP:-1024}
STAKE_WEI="${STAKE_IP}000000000000000000"
DAVE_LOCK_SEC=${DAVE_LOCK_SEC:-180}

# Wallet seed: how much IP Alice transfers to Bob/Carol/Dave at start (for stake + gas)
SEED_IP=${SEED_IP:-2000}
SEED_WEI="${SEED_IP}000000000000000000"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[multidel]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[multidel]${C_RESET} PASS %s\n" "$*"; }
# fail-fast: any assertion failure aborts probe. Fail-fast prevents downstream
# phases from running on top of broken chain state and producing meaningless
# evidence (e.g., "Bob recovered tokens" PASS when his stake never happened).
fail() { printf "${C_RED}[multidel]${C_RESET} FAIL %s\n" "$*"; exit 1; }
FAILS=0

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

# do_unstake who pk pubkey amount_wei delegation_id — fail-fast on CLI rc
# Captures full output, prints last 10 lines, aborts probe if non-zero exit.
do_unstake() {
  local who=$1 pk=$2 pubkey=$3 amt=$4 del_id=${5:-0}
  log "  $who unstake $amt wei (delegation-id=$del_id)"
  local out rc
  out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pubkey" --unstake "$amt" --delegation-id "$del_id" \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -10
  [[ $rc -eq 0 ]] || fail "$who unstake rc=$rc — fatal CLI error, full output above"
}

# ---------------- evidence capture (CL/EL logs) ----------------
capture_evidence() {
  local label=$1
  local since="${PHASE_START_TS:-1m}"
  mkdir -p "$EV_DIR"

  # CL: bootnode + target val-nodes — full block events at recent height window
  for c in bootnode1-node validator17-node validator18-node; do
    docker logs --since "$since" "$c" 2>&1 \
      | grep -E 'ABCI call: (PrepareProposal|ProcessProposal|FinalizeBlock|Commit)|MaxValidators reduction|MsgUndelegate|MsgDelegate|module=evmstaking|module=x/staking|RemoveValidator|jail|panic|CONSENSUS FAILURE' \
      > "$EV_DIR/cl-${c}-${label}.log" 2>/dev/null || true
  done

  # EL: target val-geth + rpc-geth — block import + chain head
  for c in validator17-geth validator18-geth rpc1-geth; do
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

# ---------------- Phase 0 — fresh localnet ----------------
phase_0_start() {
  log "Phase 0 — start fresh 20-val localnet, val-17 UNLOCKED, val-18 LOCKED, period[3]=180s"
  if docker ps --format '{{.Names}}' | grep -qE '^(validator|bootnode|rpc)[0-9]*-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1); sleep 5
  fi
  bash "${LOCALNET}/scripts/generate_N_validators.sh" 20 2>&1 | tail -1
  bash "${LOCALNET}/scripts/fetch_mainnet_distribution.sh" 20 2>&1 | tail -1
  UNLOCKED_VALS=17 MAX_VALIDATORS_INIT=20 bash "${LOCALNET}/scripts/assemble_genesis.sh" 20 2>&1 | tail -1

  # Shorten period[3] from default 900s → 180s for tractable probe wallclock.
  # Done at runtime (not committed in genesis-node.json) to keep upstream genesis pristine.
  local genesis_path="${LOCALNET}/config/story/genesis-node.json"
  local tmp; tmp=$(mktemp)
  jq '.app_state.staking.params.periods[3].duration = "180s"' "$genesis_path" > "$tmp" && mv "$tmp" "$genesis_path"
  local p3; p3=$(jq -r '.app_state.staking.params.periods[3].duration' "$genesis_path")
  [[ "$p3" == "180s" ]] || fail "failed to set period[3]=180s, got $p3"
  log "  period[3].duration set to 180s (runtime tweak, not committed)"

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
VAL17_OP=""; VAL18_OP=""
phase_1_baseline() {
  log "Phase 1 — wait h=$PRE_STAKE_BLOCK + capture baseline + seed Bob/Carol/Dave"
  wait_height "$PRE_STAKE_BLOCK" >/dev/null
  VAL17_OP=$(meta_op_evm "$UNLOCKED_VAL_MONIKER")
  VAL18_OP=$(meta_op_evm "$LOCKED_VAL_MONIKER")
  local s17 s18 t17 t18
  s17=$(val_field "$VAL17_OP" status); t17=$(val_field "$VAL17_OP" tokens)
  s18=$(val_field "$VAL18_OP" status); t18=$(val_field "$VAL18_OP" tokens)
  log "  val-17 (UNLOCKED): op=$VAL17_OP status=$s17 tokens=$t17"
  log "  val-18 (LOCKED):   op=$VAL18_OP status=$s18 tokens=$t18"
  [[ "$s17" == "3" && "$s18" == "3" ]] || fail "expected both BONDED pre-upgrade, got val17=$s17 val18=$s18"

  # Seed Bob/Carol/Dave from Alice (~$SEED_IP IP each for stake + gas)
  for who_addr in "Bob:$BOB_ADDR" "Carol:$CAROL_ADDR" "Dave:$DAVE_ADDR"; do
    local who=${who_addr%%:*} addr=${who_addr##*:}
    cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$addr" \
      --value "${SEED_IP}ether" --legacy --gas-price 50gwei >/dev/null 2>&1
    local bal; bal=$(get_evm_balance "$addr")
    log "  seeded $who $addr balance=$bal wei"
  done
  pass "baseline + seed complete"
  capture_evidence "01-baseline"
}

# ---------------- Phase 2 — 5 stake calls ----------------
ALICE_BAL_PRE=""; BOB_BAL_PRE=""; CAROL_BAL_PRE=""; DAVE_BAL_PRE=""
phase_2_stakes() {
  log "Phase 2 — 5 stakes pre-upgrade"
  ALICE_BAL_PRE=$(get_evm_balance "$ALICE_ADDR")
  BOB_BAL_PRE=$(get_evm_balance "$BOB_ADDR")
  CAROL_BAL_PRE=$(get_evm_balance "$CAROL_ADDR")
  DAVE_BAL_PRE=$(get_evm_balance "$DAVE_ADDR")
  log "  EVM balances pre-stake: Alice=$ALICE_BAL_PRE Bob=$BOB_BAL_PRE Carol=$CAROL_BAL_PRE Dave=$DAVE_BAL_PRE"

  # Capture pre-stake val tokens for delta assertion at end of phase
  local v17_pre v18_pre
  v17_pre=$(val_field "$VAL17_OP" tokens)
  v18_pre=$(val_field "$VAL18_OP" tokens)
  log "  pre-stake val tokens: val-17=$v17_pre val-18=$v18_pre"

  local pub17 pub18
  pub17=$(meta_pubkey_hex "$UNLOCKED_VAL_MONIKER")
  pub18=$(meta_pubkey_hex "$LOCKED_VAL_MONIKER")

  do_stake() {
    local who=$1 pk=$2 pubkey=$3 period=$4
    log "  $who → $pubkey period=$period (${STAKE_IP} IP)"
    local out rc
    out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator stake \
      --validator-pubkey "$pubkey" --stake "$STAKE_WEI" --staking-period "$period" \
      --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
    rc=$?
    printf '%s\n' "$out" | sed 's/^/      /' | tail -10
    [[ $rc -eq 0 ]] || fail "$who stake rc=$rc — fatal CLI error, full output above"
  }

  do_stake Alice  "$ALICE_PK" "$pub17" flexible
  do_stake Bob    "$BOB_PK"   "$pub17" short
  do_stake Carol  "$CAROL_PK" "$pub17" medium
  do_stake Dave   "$DAVE_PK"  "$pub17" long
  DAVE_STAKE_TS=$(date +%s)
  log "  Dave stake timestamp=$DAVE_STAKE_TS (lock expires at ~$((DAVE_STAKE_TS + DAVE_LOCK_SEC)))"
  do_stake Alice  "$ALICE_PK" "$pub18" flexible

  sleep 8
  local t17 t18 sh17 sh18
  t17=$(val_field "$VAL17_OP" tokens);  sh17=$(val_field "$VAL17_OP" delegator_shares)
  t18=$(val_field "$VAL18_OP" tokens);  sh18=$(val_field "$VAL18_OP" delegator_shares)
  log "  val-17 post-stake: tokens=$t17 shares=$sh17 (expected 4-del shape: Alice/Bob/Carol/Dave)"
  log "  val-18 post-stake: tokens=$t18 shares=$sh18 (expected 1-del shape: Alice flex)"

  # Token-delta assertion: catches silent stake failure (CLI rc=0 but no on-chain delegation)
  local expected_v17_delta=$((4 * STAKE_IP * 1000000000))   # 4 * 1024 IP * 1e9 = 4096e9 stake
  local expected_v18_delta=$((1 * STAKE_IP * 1000000000))   # 1 * 1024 IP * 1e9 = 1024e9 stake
  local v17_delta=$((t17 - v17_pre))
  local v18_delta=$((t18 - v18_pre))
  [[ "$v17_delta" == "$expected_v17_delta" ]] || fail "val-17 token delta=$v17_delta, expected $expected_v17_delta (4 stakes × 1024 IP). Some stake calls silently failed."
  [[ "$v18_delta" == "$expected_v18_delta" ]] || fail "val-18 token delta=$v18_delta, expected $expected_v18_delta (1 stake × 1024 IP)."
  pass "5 stakes committed (val-17 +$v17_delta, val-18 +$v18_delta), multi-del shape verified"
  capture_evidence "02-stakes"
}

# ---------------- Phase 3 — V170 prune ----------------
phase_3_prune() {
  log "Phase 3 — wait past V170=$UPGRADE_HEIGHT to h=$POST_UPGRADE_BLOCK"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  local s17 s18
  s17=$(val_field "$VAL17_OP" status); s18=$(val_field "$VAL18_OP" status)
  log "  val-17 post-upgrade status=$s17"
  log "  val-18 post-upgrade status=$s18"
  [[ "$s17" == "1" ]] || fail "expected val-17 UNBONDED post-upgrade, got $s17"
  [[ "$s18" == "1" ]] || fail "expected val-18 UNBONDED post-upgrade, got $s18"
  pass "both vals pruned to UNBONDED carrying multi-del shape"
  capture_evidence "03-post-prune"
}

# ---------------- Phase 4 — operator self-unstake on both vals ----------------
phase_4_self_unstake() {
  log "Phase 4 — operator on val-17 + val-18 each 100% self-unstake (→ jailed)"
  for moniker_var in "$UNLOCKED_VAL_MONIKER" "$LOCKED_VAL_MONIKER"; do
    local op_addr op_pk pub tokens
    op_addr=$(meta_op_evm "$moniker_var")
    op_pk=$(meta_privkey "$moniker_var")
    pub=$(meta_pubkey_hex "$moniker_var")
    tokens=$(val_field "$op_addr" tokens)

    # fund operator gas
    cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$op_addr" \
      --value 10ether --legacy --gas-price 50gwei >/dev/null 2>&1

    # genesis self-del = total tokens / 1e9 (subtract any external dels)
    # simpler: just unstake the operator's *own* delegation by computing it from genesis_tokens
    # but we don't have genesis_tokens here — re-compute from chain:
    # operator self-del shares = total shares - external shares. external = Alice/Bob/Carol/Dave each 1024 IP = 1024e9 stake.
    local self_stake_amount  # in wei
    if [[ "$moniker_var" == "$UNLOCKED_VAL_MONIKER" ]]; then
      # val-17: 4 ext dels each 1024 IP. self = total_tokens - 4*1024
      local ext=$((4 * STAKE_IP * 1000000000))
      self_stake_amount=$(python3 -c "print(($tokens - $ext) * 1000000000)")
    else
      # val-18: 1 ext del 1024 IP
      local ext=$((1 * STAKE_IP * 1000000000))
      self_stake_amount=$(python3 -c "print(($tokens - $ext) * 1000000000)")
    fi

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

# ---------------- Phase 5 — Alice/Bob/Carol unstake from val-17 ----------------
phase_5_short_locks_unstake() {
  log "Phase 5 — Alice/Bob/Carol unstake from val-17 (locks already expired)"
  local pub17; pub17=$(meta_pubkey_hex "$UNLOCKED_VAL_MONIKER")
  for who_pk in "Alice:$ALICE_PK" "Bob:$BOB_PK" "Carol:$CAROL_PK"; do
    local who=${who_pk%%:*} pk=${who_pk##*:}
    do_unstake "$who" "$pk" "$pub17" "$STAKE_WEI" 0
    sleep 3
  done
  pass "Alice/Bob/Carol unstake calls submitted"
  capture_evidence "05-short-locks-unstake"
}

# ---------------- Phase 6 — Alice unstake from val-18 ----------------
phase_6_alice_locked_val_unstake() {
  log "Phase 6 — Alice unstake from val-18 (LOCKED val, flexible delegation)"
  local pub18; pub18=$(meta_pubkey_hex "$LOCKED_VAL_MONIKER")
  do_unstake Alice "$ALICE_PK" "$pub18" "$STAKE_WEI" 0
  sleep 3
  pass "Alice val-18 unstake call submitted"
  capture_evidence "06-alice-locked-val"
}

# ---------------- Phase 7 — wait Dave's lock + unstake ----------------
phase_7_dave_unstake() {
  log "Phase 7 — wait Dave's $DAVE_LOCK_SEC s lock to expire then unstake from val-17"
  local now; now=$(date +%s)
  local target=$((DAVE_STAKE_TS + DAVE_LOCK_SEC + 5))
  local wait_sec=$((target - now))
  if [[ $wait_sec -gt 0 ]]; then
    log "  sleeping ${wait_sec}s for Dave's lock to expire"
    sleep "$wait_sec"
  fi
  local pub17; pub17=$(meta_pubkey_hex "$UNLOCKED_VAL_MONIKER")
  do_unstake Dave "$DAVE_PK" "$pub17" "$STAKE_WEI" 0
  sleep 5
  pass "Dave unstake call submitted post lock-expiry"
  capture_evidence "07-dave-post-lock"
}

# ---------------- Phase 8 — verify EVM balance recovery ----------------
phase_8_verify_recovery() {
  log "Phase 8 — wait unbonding mature (10s + buffer), verify all 5 EVM balances credited"
  sleep 15

  local alice_post bob_post carol_post dave_post
  alice_post=$(get_evm_balance "$ALICE_ADDR")
  bob_post=$(get_evm_balance "$BOB_ADDR")
  carol_post=$(get_evm_balance "$CAROL_ADDR")
  dave_post=$(get_evm_balance "$DAVE_ADDR")

  log "  Alice: pre=$ALICE_BAL_PRE post=$alice_post"
  log "  Bob:   pre=$BOB_BAL_PRE post=$bob_post"
  log "  Carol: pre=$CAROL_BAL_PRE post=$carol_post"
  log "  Dave:  pre=$DAVE_BAL_PRE post=$dave_post"

  # Alice staked 2x (val-17 + val-18) totalling 2048 IP, recovered both → net delta ≈ -gas
  # Bob/Carol/Dave each staked 1x 1024 IP, recovered → net delta ≈ -gas

  local alice_recovered bob_recovered carol_recovered dave_recovered
  for who in alice bob carol dave; do
    local pre_var="${who^^}_BAL_PRE" post_var="${who}_post"
    local pre=${!pre_var} post=${!post_var}
    local recovered_back=$(python3 -c "print(($post - $pre + 100000000000000000000) / 1e18)" 2>/dev/null || echo "N/A")
    log "  $who recovered_back ≈ $recovered_back IP (net of gas; positive = funds came back)"
  done

  for who_addr_pre in "alice:$ALICE_ADDR" "bob:$BOB_ADDR" "carol:$CAROL_ADDR" "dave:$DAVE_ADDR"; do
    local who=${who_addr_pre%%:*} addr=${who_addr_pre##*:}
    local pre_var="${who^^}_BAL_PRE"
    local pre=${!pre_var}
    local post; post=$(get_evm_balance "$addr")
    local stake_wei_2x="${STAKE_WEI}"  # 1x stake worth — bob/carol/dave each 1x; alice 2x
    if [[ "$who" == "alice" ]]; then
      stake_wei_2x=$(python3 -c "print($STAKE_WEI * 2)")
    fi
    # Expected: post >= pre - stake_2x + (stake_2x - gas) ≈ pre - gas → post > pre - 50 IP
    local lower_bound=$(python3 -c "print($pre - 50000000000000000000)")  # pre - 50 IP slack for gas
    if python3 -c "import sys; sys.exit(0 if $post > $lower_bound else 1)"; then
      pass "$who EVM balance recovered: pre=$pre post=$post (delta within gas slack)"
    else
      fail "$who EVM balance NOT recovered: pre=$pre post=$post"
    fi
  done

  capture_evidence "08-final-balances"
}

# ---------------- Phase 9 — final on-chain state snapshots ----------------
phase_9_final_snapshots() {
  log "Phase 9 — final on-chain val state snapshots"
  for moniker_op in "$UNLOCKED_VAL_MONIKER:$VAL17_OP" "$LOCKED_VAL_MONIKER:$VAL18_OP"; do
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
}

# ---------------- Phase 10 — summary ----------------
phase_10_summary() {
  printf "\n========== MULTIDEL LOCKED+UNLOCKED PROBE CONCLUSIONS ==========\n"
  printf "  val-17 (UNLOCKED, 4-del) final: $(cat "$EV_DIR/final-${UNLOCKED_VAL_MONIKER}.json")\n"
  printf "  val-18 (LOCKED, 1-del)   final: $(cat "$EV_DIR/final-${LOCKED_VAL_MONIKER}.json")\n"
  printf "  Final chain height: $(get_height)\n"
  printf "  Total FAILs: %d\n" "$FAILS"
  printf "  Evidence: $EV_DIR/\n"
  printf "================================================================\n"
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
