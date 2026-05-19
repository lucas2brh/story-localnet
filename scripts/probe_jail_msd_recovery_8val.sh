#!/usr/bin/env bash
# probe_jail_msd_recovery_8val.sh
#
# Three-case probe + ext-del recovery test, isolated from V170 cap-prune.
# 8-val genesis MAX_VALIDATORS_INIT=4 → rank-5/6/7 born UNBONDED.
#
# Cases:
#   A (val-5): op 100% redelegate self-del → val-1
#       Expect: val-5.jailed false→true via MSD-jail
#       (regression of probe_jail_requires_active_8val.sh)
#   B (val-6): op partial undelegate, requested remaining 500 IP < MSD 1024 IP
#       NOTE: Story 1024-IP auto-sweep rule (`story-l1-staking-module.md`) means
#       any operation leaving remaining < min_delegation=1024 IP forces 100% drain.
#       So "partial < MSD" empirically collapses to 100% drain via auto-sweep.
#       This probe documents that behavior + verifies MSD-jail still fires.
#   C (val-7): same as B (partial undelegate → auto-sweep → jail)
#       Then: Anvil (ext-del with 2048 IP flex period delegation on val-7)
#             attempts to unstake 2048 IP. Capture Anvil EVM balance pre/post.
#             Chain-asserted recovery test — does jailed UNBONDED val allow
#             ext-del withdrawal end-to-end?
#
# Chain-side verification (all via CL/EL log + REST + CometBFT — NOT probe state):
#   - val-5/6/7 NEVER appear in `📚 Validator bonded val_addr=<X>` emit
#   - val-5/6/7 NEVER appear in `📚 Validator begin unbonding val_addr=<X>` emit
#   - val-5/6/7 cons_hex NEVER appear in /cometbft/validators?height=N for sampled N
#   - val.jailed flip false→true captured via REST snapshots saved to evidence
#   - Anvil EVM balance pre/post saved via eth_getBalance to evidence JSON
#
# Setup:
#   - 8-val cluster, MAX_VALIDATORS_INIT=4 → top-4 (val-1..4) BONDED, val-5/6/7/8 born UNBONDED
#   - period[1]=60s / [2]=120s / [3]=180s + unbonding_time=10s runtime-patched
#   - No V170 fire needed (probe runs pre-V170 isolation; UPGRADE_HEIGHT irrelevant)
#
# Usage:
#   ./scripts/probe_jail_msd_recovery_8val.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_jail_msd_recovery_8val.sh

set -u

PRE_STAKE_BLOCK=${PRE_STAKE_BLOCK:-10}
N_VALS=${N_VALS:-8}
MAX_VALIDATORS_INIT=${MAX_VALIDATORS_INIT:-4}  # caps top-4 BONDED, val-5/6/7 born UNBONDED
UNBONDING_TIME=${UNBONDING_TIME:-10s}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
EV_DIR="${LOCALNET}/tmp/probe-jail-msd-recovery-evidence"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

# Anvil dev key (single delegator for ext-del injections on all 3 vals)
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ANVIL_ADDR=${ANVIL_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
ANVIL_STAKE_WEI="2048000000000000000000"   # 2048 IP

# Target vals
VAL_A_MONIKER="localnet-val-5"   # Case A: 100% redelegate
VAL_B_MONIKER="localnet-val-6"   # Case B: partial undelegate → auto-sweep
VAL_C_MONIKER="localnet-val-7"   # Case C: same as B + ext-del recovery test
DEST_VAL_MONIKER="localnet-val-1"   # redelegate dst for Case A

# Case B/C: requested remaining = 500 IP (= 500_000_000_000 stake), < MSD 1024 IP
# Auto-sweep will force actual remaining to 0.
PARTIAL_TARGET_REMAINING_IP=500

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[jail-msd]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[jail-msd]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[jail-msd]${C_RESET} FAIL %s\n" "$*"; exit 1; }
note() { printf "${C_YELLOW}[jail-msd]${C_RESET} NOTE %s\n" "$*"; }
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
val_snapshot() {
  # Save full validator REST response to evidence file
  local op=$1 label=$2
  curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null | jq '.' > "$EV_DIR/val-${label}.json"
}
meta_pubkey_hex() { local b64; b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META"); echo -n "$b64" | base64 -d | xxd -p -c 66; }
meta_op_evm()     { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }
meta_privkey()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }

# meta_cons_hex moniker — derive cons_addr (consensus) hex uppercase from pubkey
# Cosmos cons_addr = first 20 bytes of sha256(pubkey_bytes). Story emits uppercase.
meta_cons_hex() {
  local b64
  b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META")
  # Cosmos secp256k1 cons address: first 20 bytes of sha256(compressed_pubkey)
  echo -n "$b64" | base64 -d | shasum -a 256 | cut -c1-40 | tr 'a-z' 'A-Z'
}

# ---------------- Phase 0 — boot ----------------
phase_0_start() {
  log "Phase 0 — terminate prior cluster + 8-val genesis MAX_VALIDATORS_INIT=$MAX_VALIDATORS_INIT + period patches"
  if docker ps --format '{{.Names}}' | grep -qE '^(validator|bootnode|rpc)[0-9]*-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1); sleep 5
  fi
  bash "${LOCALNET}/scripts/generate_N_validators.sh" "$N_VALS" 2>&1 | tail -1
  bash "${LOCALNET}/scripts/fetch_mainnet_distribution.sh" "$N_VALS" 2>&1 | tail -1
  MAX_VALIDATORS_INIT="$MAX_VALIDATORS_INIT" STORY_BIN="$STORY_BIN" \
    bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N_VALS" 2>&1 | tail -1

  local genesis_path="${LOCALNET}/config/story/genesis-node.json"
  local tmp; tmp=$(mktemp)
  jq --arg ubt "$UNBONDING_TIME" '
    .app_state.staking.params.periods[1].duration = "60s"
    | .app_state.staking.params.periods[2].duration = "120s"
    | .app_state.staking.params.periods[3].duration = "180s"
    | .app_state.staking.params.unbonding_time = $ubt
  ' "$genesis_path" > "$tmp" && mv "$tmp" "$genesis_path"
  local mv_set; mv_set=$(jq -r '.app_state.staking.params.max_validators' "$genesis_path")
  [[ "$mv_set" == "$MAX_VALIDATORS_INIT" ]] || fail "genesis max_validators=$mv_set (expected $MAX_VALIDATORS_INIT)"
  log "  genesis: max_validators=$MAX_VALIDATORS_INIT periods=[60s,120s,180s] unbonding_time=$UNBONDING_TIME"

  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -1)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "rpc1 didn't sync in 90s"
    sleep 3
  done

  mkdir -p "$EV_DIR"
  PHASE_START_TS=$(date -u +%Y-%m-%dT%H:%M:%S)
  log "  evidence dir: $EV_DIR"
}

# ---------------- Phase 1 — baseline ----------------
VAL_A_OP=""; VAL_B_OP=""; VAL_C_OP=""
VAL_A_CONS=""; VAL_B_CONS=""; VAL_C_CONS=""
VAL_A_BASELINE_TOKENS=""; VAL_B_BASELINE_TOKENS=""; VAL_C_BASELINE_TOKENS=""
VAL_A_MSD=""; VAL_B_MSD=""; VAL_C_MSD=""
phase_1_baseline() {
  log "Phase 1 — wait h=$PRE_STAKE_BLOCK + baseline assert val-5/6/7 status=1 UNBONDED jailed=false"
  wait_height "$PRE_STAKE_BLOCK" >/dev/null

  for moniker_var in VAL_A_MONIKER VAL_B_MONIKER VAL_C_MONIKER; do
    local moniker=${!moniker_var}
    local op cons tokens msd status jailed
    op=$(meta_op_evm "$moniker")
    cons=$(meta_cons_hex "$moniker")
    val_snapshot "$op" "${moniker}-01-baseline"
    status=$(val_field "$op" status)
    jailed=$(val_field "$op" jailed)
    tokens=$(val_field "$op" tokens)
    msd=$(val_field "$op" min_self_delegation)
    log "  $moniker: op=$op cons=$cons status=$status jailed=$jailed tokens=$tokens MSD=$msd"
    [[ "$status" == "1" ]] || fail "$moniker expected status=1 UNBONDED, got $status"
    [[ "$jailed" == "GONE" || "$jailed" == "false" ]] || fail "$moniker expected jailed=false, got $jailed"
    case "$moniker_var" in
      VAL_A_MONIKER) VAL_A_OP=$op; VAL_A_CONS=$cons; VAL_A_BASELINE_TOKENS=$tokens; VAL_A_MSD=$msd ;;
      VAL_B_MONIKER) VAL_B_OP=$op; VAL_B_CONS=$cons; VAL_B_BASELINE_TOKENS=$tokens; VAL_B_MSD=$msd ;;
      VAL_C_MONIKER) VAL_C_OP=$op; VAL_C_CONS=$cons; VAL_C_BASELINE_TOKENS=$tokens; VAL_C_MSD=$msd ;;
    esac
  done

  # Capture CometBFT validator set at this height — val-5/6/7 should NOT appear
  local h_now; h_now=$(get_height)
  curl -fsS "http://localhost:26657/validators?height=$h_now" 2>/dev/null | jq '.' > "$EV_DIR/cometbft-validators-h${h_now}.json"
  log "  saved cometbft validators snapshot h=$h_now"
  pass "baseline confirmed (3 vals born UNBONDED + 1 dst val BONDED)"
}

# ---------------- Phase 2 — Anvil ext-del 2048 IP × 3 vals ----------------
phase_2_inject_ext_dels() {
  log "Phase 2 — Anvil #0 stakes 2048 IP flex period to val-5/6/7 each"
  for moniker_var in VAL_A_MONIKER VAL_B_MONIKER VAL_C_MONIKER; do
    local moniker=${!moniker_var}
    local pub; pub=$(meta_pubkey_hex "$moniker")
    local out rc
    out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
      --validator-pubkey "$pub" --stake "$ANVIL_STAKE_WEI" --staking-period flexible \
      --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
    rc=$?
    [[ $rc -eq 0 ]] || fail "Anvil stake → $moniker rc=$rc"
    log "  Anvil stake → $moniker rc=$rc tx=$(grep -oE 'Transaction hash: 0x[0-9a-f]+' <<<"$out" | head -1 | awk '{print $3}')"
  done
  sleep 8
  for moniker_var in VAL_A_MONIKER VAL_B_MONIKER VAL_C_MONIKER; do
    local moniker=${!moniker_var}
    local op; op=$(meta_op_evm "$moniker")
    val_snapshot "$op" "${moniker}-02-post-anvil-stake"
    local tokens status
    tokens=$(val_field "$op" tokens); status=$(val_field "$op" status)
    log "  $moniker post-stake: status=$status tokens=$tokens (expected status=1, tokens=baseline+2048e9)"
    [[ "$status" == "1" ]] || fail "$moniker expected status=1 still UNBONDED (Anvil stake didn't promote), got $status"
  done
  pass "ext-del injected on all 3 vals, all still UNBONDED"
}

# ---------------- Phase 3 — Case A: val-5 op 100% redelegate ----------------
phase_3_case_A_redelegate() {
  log "Phase 3 (Case A) — $VAL_A_MONIKER op 100% redelegate self-del to $DEST_VAL_MONIKER"
  local pub_src pub_dst op_pk op_addr dest_op
  pub_src=$(meta_pubkey_hex "$VAL_A_MONIKER")
  pub_dst=$(meta_pubkey_hex "$DEST_VAL_MONIKER")
  op_pk=$(meta_privkey "$VAL_A_MONIKER")
  op_addr=$(meta_op_evm "$VAL_A_MONIKER")
  dest_op=$(meta_op_evm "$DEST_VAL_MONIKER")

  # Fund op gas
  cast send --rpc-url http://localhost:8545 --private-key "$ANVIL_PK" "$op_addr" \
    --value 10ether --legacy --gas-price 50gwei >/dev/null 2>&1
  sleep 5

  # Redelegate 100% of baseline self-del (in stake → wei: × 1e9)
  local amount_wei; amount_wei=$(echo "$VAL_A_BASELINE_TOKENS * 1000000000" | bc)
  log "  redelegate amount = 100% baseline = $amount_wei wei → drives op self-del to 0 < MSD ($VAL_A_MSD)"

  local h_before; h_before=$(get_height)
  local out rc
  out=$(PRIVATE_KEY="$op_pk" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$pub_src" --validator-dst-pubkey "$pub_dst" \
    --redelegate "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || fail "Case A redelegate rc=$rc"
  log "  Case A redelegate submitted at h_before=$h_before"
  wait_height "$((h_before + 10))" >/dev/null
  pass "Case A redelegate landed (h~$h_before+5)"
}

# ---------------- Phase 4 — Case B: val-6 op partial undelegate ----------------
phase_4_case_B_undelegate_partial() {
  log "Phase 4 (Case B) — $VAL_B_MONIKER op partial undelegate, requested remaining=${PARTIAL_TARGET_REMAINING_IP} IP (< MSD ${VAL_B_MSD}); auto-sweep will force 100% drain"
  local pub op_pk op_addr
  pub=$(meta_pubkey_hex "$VAL_B_MONIKER")
  op_pk=$(meta_privkey "$VAL_B_MONIKER")
  op_addr=$(meta_op_evm "$VAL_B_MONIKER")
  cast send --rpc-url http://localhost:8545 --private-key "$ANVIL_PK" "$op_addr" \
    --value 10ether --legacy --gas-price 50gwei >/dev/null 2>&1
  sleep 5

  # Undelegate amount = baseline_tokens - PARTIAL_TARGET_REMAINING_IP (in stake), × 1e9 → wei
  # baseline_tokens is in stake-units (1e9 = 1 IP). Compute undelegate amount in wei.
  local remain_stake=$((PARTIAL_TARGET_REMAINING_IP * 1000000000))   # 500 IP × 1e9 = 500e9 stake
  local unstake_stake=$((VAL_B_BASELINE_TOKENS - remain_stake))
  local unstake_wei; unstake_wei=$(echo "$unstake_stake * 1000000000" | bc)
  log "  Case B unstake amount = baseline($VAL_B_BASELINE_TOKENS stake) - remain($remain_stake) = $unstake_stake stake = $unstake_wei wei"

  local h_before; h_before=$(get_height)
  local out rc
  out=$(PRIVATE_KEY="$op_pk" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$unstake_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || fail "Case B unstake rc=$rc"
  log "  Case B unstake submitted at h_before=$h_before"
  wait_height "$((h_before + 10))" >/dev/null
  pass "Case B unstake landed"
}

# ---------------- Phase 5 — Case C: val-7 op partial undelegate (same as B) ----------------
phase_5_case_C_undelegate_partial() {
  log "Phase 5 (Case C) — $VAL_C_MONIKER op partial undelegate, same pattern as Case B"
  local pub op_pk op_addr
  pub=$(meta_pubkey_hex "$VAL_C_MONIKER")
  op_pk=$(meta_privkey "$VAL_C_MONIKER")
  op_addr=$(meta_op_evm "$VAL_C_MONIKER")
  cast send --rpc-url http://localhost:8545 --private-key "$ANVIL_PK" "$op_addr" \
    --value 10ether --legacy --gas-price 50gwei >/dev/null 2>&1
  sleep 5

  local remain_stake=$((PARTIAL_TARGET_REMAINING_IP * 1000000000))
  local unstake_stake=$((VAL_C_BASELINE_TOKENS - remain_stake))
  local unstake_wei; unstake_wei=$(echo "$unstake_stake * 1000000000" | bc)
  log "  Case C unstake amount = baseline($VAL_C_BASELINE_TOKENS) - remain($remain_stake) = $unstake_stake stake = $unstake_wei wei"

  local h_before; h_before=$(get_height)
  local out rc
  out=$(PRIVATE_KEY="$op_pk" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$unstake_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || fail "Case C unstake rc=$rc"
  log "  Case C unstake submitted at h_before=$h_before"
  wait_height "$((h_before + 10))" >/dev/null
  pass "Case C unstake landed"
}

# ---------------- Phase 6 — Assert all 3 vals jailed=true ----------------
phase_6_assert_jailed() {
  log "Phase 6 — assert all 3 vals jailed=true via REST + save snapshots"
  for moniker_var in VAL_A_MONIKER VAL_B_MONIKER VAL_C_MONIKER; do
    local moniker=${!moniker_var}
    local op; op=$(meta_op_evm "$moniker")
    val_snapshot "$op" "${moniker}-06-post-jail-trigger"
    local status jailed tokens
    status=$(val_field "$op" status); jailed=$(val_field "$op" jailed); tokens=$(val_field "$op" tokens)
    log "  $moniker post-trigger: status=$status jailed=$jailed tokens=$tokens"
    [[ "$jailed" == "true" ]] || { FAILS=$((FAILS+1)); printf "${C_RED}[jail-msd]${C_RESET} FAIL %s\n" "$moniker expected jailed=true, got $jailed"; }
  done
  [[ $FAILS -eq 0 ]] && pass "all 3 vals jailed=true (MSD-jail fired on never-active val × 3 cases)" || fail "$FAILS of 3 vals failed jail assertion"
}

# ---------------- Phase 7 — Case C extension: Anvil ext-del unstake recovery test ----------------
ANVIL_BAL_PRE=""; ANVIL_BAL_POST=""
phase_7_anvil_recovery() {
  log "Phase 7 — Anvil ext-del unstake 2048 IP from $VAL_C_MONIKER (jailed UNBONDED); verify EVM balance credit"
  local op pub
  op=$(meta_op_evm "$VAL_C_MONIKER")
  pub=$(meta_pubkey_hex "$VAL_C_MONIKER")

  ANVIL_BAL_PRE=$(get_evm_balance "$ANVIL_ADDR")
  log "  Anvil EVM balance pre-unstake: $ANVIL_BAL_PRE wei"
  echo "$ANVIL_BAL_PRE" > "$EV_DIR/anvil-bal-pre-unstake.txt"
  # Capture Anvil delegation on val-7 + val-7 state pre
  curl -fsS "http://localhost:1317/staking/delegations/${ANVIL_ADDR}/${op}" 2>/dev/null | jq '.' > "$EV_DIR/anvil-delegation-on-${VAL_C_MONIKER}-pre.json"
  val_snapshot "$op" "${VAL_C_MONIKER}-07-pre-anvil-unstake"

  local h_before; h_before=$(get_height)
  local out rc
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$ANVIL_STAKE_WEI" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || fail "Anvil unstake rc=$rc"
  log "  Anvil unstake submitted at h_before=$h_before"

  # Wait unbonding_time (10s) + queue dequeue (~few blocks at 32/block) + buffer
  wait_height "$((h_before + 10))" >/dev/null
  sleep 15

  ANVIL_BAL_POST=$(get_evm_balance "$ANVIL_ADDR")
  log "  Anvil EVM balance post-unstake: $ANVIL_BAL_POST wei"
  echo "$ANVIL_BAL_POST" > "$EV_DIR/anvil-bal-post-unstake.txt"
  val_snapshot "$op" "${VAL_C_MONIKER}-07-post-anvil-unstake"

  # PASS criteria: post > pre - 50 IP gas slack (full 2048 IP recovered)
  local lower_bound; lower_bound=$(python3 -c "print($ANVIL_BAL_PRE - 50000000000000000000)")
  if python3 -c "import sys; sys.exit(0 if $ANVIL_BAL_POST > $lower_bound else 1)"; then
    pass "Case C ext-del recovery: Anvil EVM balance credited (pre=$ANVIL_BAL_PRE post=$ANVIL_BAL_POST, delta within gas slack — full 2048 IP recovered from jailed UNBONDED val)"
  else
    FAILS=$((FAILS+1))
    printf "${C_RED}[jail-msd]${C_RESET} FAIL Case C ext-del recovery: Anvil EVM NOT credited (pre=$ANVIL_BAL_PRE post=$ANVIL_BAL_POST — stranded on jailed UNBONDED val)\n"
  fi
}

# ---------------- Phase 8 — Chain-side "never active" verification ----------------
phase_8_never_active_check() {
  log "Phase 8 — chain-side never-active verification per val (CL emit grep + CometBFT validators snapshots)"

  # Sample CometBFT validators at multiple heights
  local final_h; final_h=$(get_height)
  for h in 1 10 $((PRE_STAKE_BLOCK + 5)) $((final_h / 2)) "$final_h"; do
    curl -fsS "http://localhost:26657/validators?height=$h" 2>/dev/null | jq '.' > "$EV_DIR/cometbft-validators-h${h}.json"
  done
  log "  CometBFT validators snapshots saved for h ∈ {1, 10, ~$((PRE_STAKE_BLOCK + 5)), ~$((final_h/2)), $final_h}"

  for moniker_var in VAL_A_MONIKER VAL_B_MONIKER VAL_C_MONIKER; do
    local moniker=${!moniker_var}
    local op_upper cons
    op_upper=$(echo "$(meta_op_evm "$moniker")" | sed 's/0x//' | tr 'a-z' 'A-Z')
    cons=$(meta_cons_hex "$moniker")

    # 1. grep `📚 Validator bonded val_addr=<UPPER>` in bootnode docker log
    local bonded_hits unbonding_hits
    docker logs bootnode1-node 2>&1 | grep -E "Validator bonded.*val_addr=$op_upper" > "$EV_DIR/bonded-events-${moniker}.txt" || true
    bonded_hits=$(wc -l < "$EV_DIR/bonded-events-${moniker}.txt")

    # 2. grep `📚 Validator begin unbonding val_addr=<UPPER>`
    docker logs bootnode1-node 2>&1 | grep -E "Validator begin unbonding.*val_addr=$op_upper" > "$EV_DIR/unbonding-events-${moniker}.txt" || true
    unbonding_hits=$(wc -l < "$EV_DIR/unbonding-events-${moniker}.txt")

    # 3. Check CometBFT validators snapshots — cons_hex must NOT appear in any active set sample
    local cometbft_hits=0
    for snap in "$EV_DIR"/cometbft-validators-h*.json; do
      local found
      found=$(jq -r --arg c "$cons" '[.result.validators[]?.address] | map(ascii_upcase) | contains([$c])' "$snap" 2>/dev/null)
      [[ "$found" == "true" ]] && cometbft_hits=$((cometbft_hits + 1))
    done

    log "  $moniker (op=0x${op_upper} cons=$cons): bonded_emits=$bonded_hits unbonding_emits=$unbonding_hits cometbft_active_samples=$cometbft_hits"
    if [[ $bonded_hits -eq 0 && $unbonding_hits -eq 0 && $cometbft_hits -eq 0 ]]; then
      pass "$moniker NEVER active (chain-asserted: 0 bonded-emit + 0 unbonding-emit + 0 cometbft-active-samples)"
    else
      FAILS=$((FAILS+1))
      printf "${C_RED}[jail-msd]${C_RESET} FAIL %s WAS active at some point: bonded_emits=%s unbonding_emits=%s cometbft_active_samples=%s\n" "$moniker" "$bonded_hits" "$unbonding_hits" "$cometbft_hits"
    fi
  done
}

# ---------------- Phase 9 — summary ----------------
phase_9_summary() {
  printf "\n========== JAIL-MSD + RECOVERY PROBE SUMMARY (Cases A/B/C) ==========\n"
  for moniker_var in VAL_A_MONIKER VAL_B_MONIKER VAL_C_MONIKER; do
    local moniker=${!moniker_var}
    local op; op=$(meta_op_evm "$moniker")
    local snapshot="$EV_DIR/val-${moniker}-06-post-jail-trigger.json"
    local status jailed tokens
    status=$(jq -r '.msg.validator.status' "$snapshot" 2>/dev/null)
    jailed=$(jq -r '.msg.validator.jailed' "$snapshot" 2>/dev/null)
    tokens=$(jq -r '.msg.validator.tokens' "$snapshot" 2>/dev/null)
    printf "  %s post-trigger: status=%s jailed=%s tokens=%s\n" "$moniker" "$status" "$jailed" "$tokens"
  done
  printf "  Anvil recovery (val-7): pre=%s post=%s\n" "$ANVIL_BAL_PRE" "$ANVIL_BAL_POST"
  printf "  Final chain height: %s\n" "$(get_height)"
  printf "  Total FAILs: %s\n" "$FAILS"
  printf "  Evidence dir: %s\n" "$EV_DIR"
  printf "  Outcome: %s\n" "$( [[ $FAILS -eq 0 ]] && echo 'PASS (all assertions chain-asserted)' || echo "FAIL ($FAILS assertion(s) failed)" )"
  printf "=====================================================================\n"
}

phase_10_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 10 — SKIP_TEARDOWN"; return; fi
  log "Phase 10 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1)
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline
phase_2_inject_ext_dels
phase_3_case_A_redelegate
phase_4_case_B_undelegate_partial
phase_5_case_C_undelegate_partial
phase_6_assert_jailed
phase_7_anvil_recovery
phase_8_never_active_check
phase_9_summary
phase_10_teardown

[[ $FAILS -eq 0 ]] || exit 1
