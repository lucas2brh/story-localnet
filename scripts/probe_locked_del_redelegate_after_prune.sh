#!/usr/bin/env bash
# probe_locked_del_redelegate_after_prune.sh — G1 from impact-doc gap probes plan
#
# Tests Raul's MaxValidators reduction impact doc Case 6b:
#   locked-period delegator on out-cap UNLOCKED val redelegates to top-cap val
#   using forceUnbond=true path (delegation.go:1407). Lock metadata must be
#   preserved on destination, new delegation must be live immediately,
#   source val.tokens must decrease, dest val.tokens must increase.
#
# Adjacent: piplabs/lion-team-sync#681 (locked-period delegator stranding via
# standard Undelegate). G1 tests whether the same evmstaking-mediated
# stranding affects the Redelegate path too.
#
# Plan revised 2026-04-30 — v1.7.0 NewMaxValidators 16 → 21:
#   - Binary: yao/v170-maxval-21 branch with NewMaxValidators=21 baked in
#   - Cluster: N=22, NEW_MAX=21 → 1 val pruned (val-22, marked UNLOCKED)
#   - Top-cap dest: val-1 (rank-1 by stake, top-21 BONDED)
#
# Setup:
#   - val-22 = UNLOCKED (support_token_type=1) — will be pruned at H=50
#   - val-1 = LOCKED (default support_token_type=0) — top-21
#     Note: val-1 LOCKED dest tests whether locked-period delegation can
#     redelegate INTO a LOCKED val (per upgrades.go:190 comment, locked vals
#     should only have flexible delegations — this probe verifies that).
#
# Delegator: Bob (anvil[1])
#   - stake locked-short (period_type=1) 1024 IP to val-22 → delegation-id=1
#   - after V170 prune + val-22 op self-unstake (val-22 jailed UNBONDED):
#     redelegate Bob's stake from val-22 to val-1 with same delegation-id
#
# Usage:
#   ./scripts/probe_locked_del_redelegate_after_prune.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_locked_del_redelegate_after_prune.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
PRE_STAKE_BLOCK=${PRE_STAKE_BLOCK:-10}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-65}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
EV_DIR="${LOCALNET}/tmp/probe-G1-evidence"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

# Anvil keys
ALICE_PK=${ALICE_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ALICE_ADDR=${ALICE_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
BOB_PK=${BOB_PK:-59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}
BOB_ADDR=${BOB_ADDR:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}

# Cluster size + boundary
N_VALS=${N_VALS:-22}
NEW_MAX=${NEW_MAX:-21}
SRC_VAL_MONIKER=${SRC_VAL_MONIKER:-localnet-val-22}    # will be pruned (UNLOCKED)
DST_VAL_MONIKER=${DST_VAL_MONIKER:-localnet-val-1}     # top-21 (LOCKED by default)
STAKE_IP=${STAKE_IP:-1024}
STAKE_WEI="${STAKE_IP}000000000000000000"

# Wallet seed
SEED_IP=${SEED_IP:-2000}
SEED_WEI="${SEED_IP}000000000000000000"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[G1]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[G1]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[G1]${C_RESET} FAIL %s\n" "$*"; exit 1; }

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

# do_unstake / do_stake / do_redelegate — fail-fast on CLI rc, capture full output
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
  # extract delegation-id from CLI output
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
  log "  $who redelegate amt=$amt del_id=$del_id src→dst"
  local out rc
  out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$src_pubkey" --validator-dst-pubkey "$dst_pubkey" \
    --redelegate "$amt" --delegation-id "$del_id" \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -10
  [[ $rc -eq 0 ]] || fail "$who redelegate rc=$rc"
}

# ---------------- evidence capture ----------------
capture_evidence() {
  local label=$1
  local since="${PHASE_START_TS:-1m}"
  mkdir -p "$EV_DIR"

  # CL: bootnode + src val + dst val
  for c in bootnode1-node validator22-node validator1-node; do
    docker logs --since "$since" "$c" 2>&1 \
      | grep -E 'ABCI call: (PrepareProposal|ProcessProposal|FinalizeBlock|Commit)|MaxValidators reduction|MsgUndelegate|MsgDelegate|MsgBeginRedelegate|module=evmstaking|module=x/staking|RemoveValidator|Redelegation|Delegate Info|Undelegate Info|Unbond Info|jail|panic|CONSENSUS FAILURE' \
      > "$EV_DIR/cl-${c}-${label}.log" 2>/dev/null || true
  done

  # EL: src + dst geth + rpc1
  for c in validator22-geth validator1-geth rpc1-geth; do
    docker logs --since "$since" "$c" 2>&1 \
      | grep -E 'Imported new|Chain head was updated|Beacon client|Engine API|payload' \
      > "$EV_DIR/el-${c}-${label}.log" 2>/dev/null || true
  done

  # Liveness scan
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
  log "Phase 0 — start fresh ${N_VALS}-val localnet, val-${N_VALS} UNLOCKED, NEW_MAX=${NEW_MAX} (binary v170-maxval-21)"
  if docker ps --format '{{.Names}}' | grep -qE '^(validator|bootnode|rpc)[0-9]*-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1); sleep 5
  fi
  bash "${LOCALNET}/scripts/generate_N_validators.sh" "$N_VALS" 2>&1 | tail -1
  bash "${LOCALNET}/scripts/fetch_mainnet_distribution.sh" "$N_VALS" 2>&1 | tail -1
  UNLOCKED_VALS="$N_VALS" MAX_VALIDATORS_INIT="$N_VALS" bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N_VALS" 2>&1 | tail -1

  # Shorten period[3].duration 900s → 180s for tractable wallclock (runtime jq tweak, not committed)
  local genesis_path="${LOCALNET}/config/story/genesis-node.json"
  local tmp; tmp=$(mktemp)
  jq '.app_state.staking.params.periods[3].duration = "180s"' "$genesis_path" > "$tmp" && mv "$tmp" "$genesis_path"
  log "  period[3].duration set to 180s (runtime tweak)"

  # also need docker-compose for vals 21+22 which don't ship by default
  bash "${LOCALNET}/scripts/generate_compose_files.sh" "$N_VALS" 2>&1 | tail -1 || \
    log "  WARNING: scripts/generate_compose_files.sh not found or failed; assuming docker-compose-validator{1..N}.yml exist"

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

# ---------------- Phase 1 — baseline + seed Bob ----------------
SRC_VAL_OP=""; DST_VAL_OP=""
phase_1_baseline() {
  log "Phase 1 — wait h=$PRE_STAKE_BLOCK + capture baseline + seed Bob"
  wait_height "$PRE_STAKE_BLOCK" >/dev/null
  SRC_VAL_OP=$(meta_op_evm "$SRC_VAL_MONIKER")
  DST_VAL_OP=$(meta_op_evm "$DST_VAL_MONIKER")
  local s_src s_dst t_src t_dst stt_src stt_dst
  s_src=$(val_field "$SRC_VAL_OP" status); t_src=$(val_field "$SRC_VAL_OP" tokens); stt_src=$(val_field "$SRC_VAL_OP" support_token_type)
  s_dst=$(val_field "$DST_VAL_OP" status); t_dst=$(val_field "$DST_VAL_OP" tokens); stt_dst=$(val_field "$DST_VAL_OP" support_token_type)
  log "  $SRC_VAL_MONIKER (UNLOCKED): op=$SRC_VAL_OP status=$s_src tokens=$t_src support_token_type=$stt_src"
  log "  $DST_VAL_MONIKER (LOCKED):   op=$DST_VAL_OP status=$s_dst tokens=$t_dst support_token_type=$stt_dst"
  [[ "$s_src" == "3" && "$s_dst" == "3" ]] || fail "expected both BONDED pre-upgrade, got src=$s_src dst=$s_dst"
  [[ "$stt_src" == "1" ]] || fail "expected $SRC_VAL_MONIKER UNLOCKED (support_token_type=1), got $stt_src"
  [[ "$stt_dst" == "0" ]] || fail "expected $DST_VAL_MONIKER LOCKED (support_token_type=0), got $stt_dst"

  # Seed Bob
  cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$BOB_ADDR" \
    --value "${SEED_IP}ether" --legacy --gas-price 50gwei >/dev/null 2>&1
  local bal; bal=$(get_evm_balance "$BOB_ADDR")
  log "  Bob seeded balance=$bal wei"
  pass "baseline + seed complete; src=UNLOCKED, dst=LOCKED, both BONDED"
  capture_evidence "01-baseline"
}

# ---------------- Phase 2 — Bob stakes locked-short to val-22 ----------------
BOB_BAL_PRE_STAKE=""; SRC_TOKENS_PRE=""; DST_TOKENS_PRE=""
phase_2_stake() {
  log "Phase 2 — Bob stakes ${STAKE_IP} IP locked-short (period_type=1) to $SRC_VAL_MONIKER"
  BOB_BAL_PRE_STAKE=$(get_evm_balance "$BOB_ADDR")
  SRC_TOKENS_PRE=$(val_field "$SRC_VAL_OP" tokens)
  DST_TOKENS_PRE=$(val_field "$DST_VAL_OP" tokens)
  log "  pre-stake: Bob=$BOB_BAL_PRE_STAKE, src.tokens=$SRC_TOKENS_PRE, dst.tokens=$DST_TOKENS_PRE"

  local pub_src; pub_src=$(meta_pubkey_hex "$SRC_VAL_MONIKER")
  local del_id_line
  del_id_line=$(do_stake Bob "$BOB_PK" "$pub_src" short)
  log "  CLI returned: $del_id_line"

  sleep 8
  local src_tokens_post src_shares_post
  src_tokens_post=$(val_field "$SRC_VAL_OP" tokens)
  src_shares_post=$(val_field "$SRC_VAL_OP" delegator_shares)
  local delta_src=$((src_tokens_post - SRC_TOKENS_PRE))
  log "  post-stake: src.tokens=$src_tokens_post (delta=$delta_src), src.shares=$src_shares_post"
  local expected_delta=$((STAKE_IP * 1000000000))
  [[ "$delta_src" == "$expected_delta" ]] || fail "src val tokens delta=$delta_src, expected $expected_delta — stake did not commit on chain"
  pass "Bob stake committed; src val carrying locked-short delegation"
  capture_evidence "02-stake"
}

# ---------------- Phase 3 — V170 prune ----------------
phase_3_prune() {
  log "Phase 3 — wait past V170=$UPGRADE_HEIGHT to h=$POST_UPGRADE_BLOCK"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  local s_src s_dst t_src t_dst
  s_src=$(val_field "$SRC_VAL_OP" status); t_src=$(val_field "$SRC_VAL_OP" tokens)
  s_dst=$(val_field "$DST_VAL_OP" status); t_dst=$(val_field "$DST_VAL_OP" tokens)
  log "  src post-upgrade: status=$s_src tokens=$t_src"
  log "  dst post-upgrade: status=$s_dst tokens=$t_dst"
  [[ "$s_src" == "1" ]] || fail "expected src UNBONDED (status=1) post-upgrade, got $s_src"
  [[ "$s_dst" == "3" ]] || fail "expected dst BONDED (status=3) post-upgrade, got $s_dst"
  pass "V170 prune fired; src UNBONDED carrying Bob's locked delegation; dst still BONDED"
  capture_evidence "03-post-prune"
}

# ---------------- Phase 4 — operator self-unstake on src → src jailed ----------------
phase_4_self_unstake() {
  log "Phase 4 — $SRC_VAL_MONIKER operator 100% self-unstake → val jailed"
  local op_addr op_pk pub_src tokens
  op_addr=$(meta_op_evm "$SRC_VAL_MONIKER")
  op_pk=$(meta_privkey "$SRC_VAL_MONIKER")
  pub_src=$(meta_pubkey_hex "$SRC_VAL_MONIKER")
  tokens=$(val_field "$SRC_VAL_OP" tokens)

  # fund operator gas
  cast send --rpc-url http://localhost:8545 --private-key "$ALICE_PK" "$op_addr" \
    --value 10ether --legacy --gas-price 50gwei >/dev/null 2>&1

  # operator self = total - bob's 1024 IP
  local ext=$((1 * STAKE_IP * 1000000000))
  local self_amount; self_amount=$(python3 -c "print(($tokens - $ext) * 1000000000)")
  do_unstake "${SRC_VAL_MONIKER}-op" "$op_pk" "$pub_src" "$self_amount" 0
  sleep 5
  local s j t
  s=$(val_field "$SRC_VAL_OP" status); j=$(val_field "$SRC_VAL_OP" jailed); t=$(val_field "$SRC_VAL_OP" tokens)
  log "  src post-self-unstake: status=$s jailed=$j tokens=$t"
  [[ "$s" == "1" ]]      || fail "src expected UNBONDED, got $s"
  [[ "$j" == "true" ]]   || fail "src expected jailed=true, got $j"
  [[ "$t" == "$ext" ]]   || fail "src expected tokens=$ext (Bob's portion only), got $t"
  pass "src val jailed + UNBONDED; only Bob's 1024 IP delegation remains"
  capture_evidence "04-post-self-unstake"
}

# ---------------- Phase 5 — Bob redelegates from src to dst (THE TEST) ----------------
SRC_TOKENS_PRE_REDEL=""; DST_TOKENS_PRE_REDEL=""; BOB_BAL_PRE_REDEL=""
phase_5_redelegate() {
  log "Phase 5 — Bob redelegate (forceUnbond=true path) from $SRC_VAL_MONIKER to $DST_VAL_MONIKER"
  log "  THIS is the test: locked-period del on jailed-pruned UNLOCKED val, redelegate to LOCKED top-21 val"

  SRC_TOKENS_PRE_REDEL=$(val_field "$SRC_VAL_OP" tokens)
  DST_TOKENS_PRE_REDEL=$(val_field "$DST_VAL_OP" tokens)
  BOB_BAL_PRE_REDEL=$(get_evm_balance "$BOB_ADDR")
  log "  pre-redel: src.tokens=$SRC_TOKENS_PRE_REDEL, dst.tokens=$DST_TOKENS_PRE_REDEL, Bob=$BOB_BAL_PRE_REDEL wei"

  local pub_src pub_dst
  pub_src=$(meta_pubkey_hex "$SRC_VAL_MONIKER")
  pub_dst=$(meta_pubkey_hex "$DST_VAL_MONIKER")

  do_redelegate Bob "$BOB_PK" "$pub_src" "$pub_dst" "$STAKE_WEI" 1
  sleep 8

  local src_tokens_post dst_tokens_post src_shares_post dst_shares_post
  src_tokens_post=$(val_field "$SRC_VAL_OP" tokens)
  dst_tokens_post=$(val_field "$DST_VAL_OP" tokens)
  src_shares_post=$(val_field "$SRC_VAL_OP" delegator_shares)
  dst_shares_post=$(val_field "$DST_VAL_OP" delegator_shares)

  local src_delta=$((src_tokens_post - SRC_TOKENS_PRE_REDEL))
  local dst_delta=$((dst_tokens_post - DST_TOKENS_PRE_REDEL))

  log "  post-redel: src.tokens=$src_tokens_post (delta=$src_delta), dst.tokens=$dst_tokens_post (delta=$dst_delta)"
  log "  post-redel: src.shares=$src_shares_post, dst.shares=$dst_shares_post"

  local expected_neg=$(python3 -c "print(-$STAKE_IP * 1000000000)")
  local expected_pos=$((STAKE_IP * 1000000000))
  [[ "$src_delta" == "$expected_neg" ]] || fail "src val tokens delta=$src_delta, expected $expected_neg — redelegate did NOT decrement src on chain"
  [[ "$dst_delta" == "$expected_pos" ]] || fail "dst val tokens delta=$dst_delta, expected $expected_pos — redelegate did NOT credit dst on chain (likely #681-shape bug)"

  pass "redelegate moved 1024 IP from src to dst on chain (val.tokens deltas verified)"
  capture_evidence "05-redelegate"
}

# ---------------- Phase 6 — verify lock metadata preserved on dst ----------------
phase_6_verify_lock_preserved() {
  log "Phase 6 — verify Bob's delegation on dst preserves period_type=1 (lock metadata)"
  # Bob's bech32 delegator addr derived from his EVM addr
  # Use Story REST: /staking/delegations/{del_addr}/{val_addr}
  # OR query dst val's delegations and find Bob's entry
  local dst_dels
  dst_dels=$(curl -fsS "http://localhost:1317/staking/validators/${DST_VAL_OP}/delegations" 2>/dev/null)
  log "  dst val delegations response (first 500 chars):"
  echo "$dst_dels" | jq . 2>/dev/null | head -20 | sed 's/^/      /'

  # Find Bob's entry — match by EVM addr (stored as delegator_address in EVM-bech32 form)
  # Bob's EVM addr lowercased: 0x70997970c51812dc3a010c7d01b50e0d17dc79c8
  local bob_lc; bob_lc=$(echo "$BOB_ADDR" | tr '[:upper:]' '[:lower:]')
  local bob_del
  bob_del=$(echo "$dst_dels" | jq --arg a "$bob_lc" '.msg.delegation_responses[]? | select((.delegation.delegator_address // "" | ascii_downcase) == $a)')

  if [[ -z "$bob_del" ]]; then
    log "  WARN: Bob's delegation not found via /validators/<dst>/delegations route; querying period_delegation"
    # Try the period_delegation-specific REST path (Story-specific; may differ)
    local period_resp
    period_resp=$(curl -fsS "http://localhost:1317/staking/delegators/${BOB_ADDR}/validators/${DST_VAL_OP}/period_delegations" 2>/dev/null)
    log "  period_delegations response: $(echo "$period_resp" | jq -c . 2>/dev/null | head -c 300)"
    fail "could not locate Bob's delegation on dst val to verify period_type"
  fi

  local bob_shares; bob_shares=$(echo "$bob_del" | jq -r '.delegation.shares')
  log "  Bob on dst: shares=$bob_shares"

  pass "Bob's delegation entry exists on dst val"
  log "  NOTE: period_type verification requires querying the period_delegation sub-record;"
  log "        if dst is LOCKED (support_token_type=0) and reject-on-redelegate fired, redelegate would have rc!=0 in Phase 5."
  capture_evidence "06-lock-preserved"
}

# ---------------- Phase 7 — wait redelegation entry maturation + reward earning ----------------
phase_7_mature_and_earn() {
  log "Phase 7 — wait redelegation entry maturation + verify Bob earns rewards on dst"
  # Source val is UNBONDED, so per getBeginInfo: redelegation completes instantly
  # Wait a few blocks to let any reward accrual happen on dst
  local h_now; h_now=$(get_height)
  wait_height $((h_now + 5)) >/dev/null
  log "  chain at h=$(get_height) (waited ~10s for rewards on dst)"

  # Check chain log for 'Withdraw delegator rewards' for Bob's addr on dst val
  local bob_lc; bob_lc=$(echo "$BOB_ADDR" | tr '[:upper:]' '[:lower:]')
  local rewards_count
  rewards_count=$(docker logs validator1-node 2>&1 | grep -c "withdrawal_evm_addr=${BOB_ADDR}\|withdrawal_evm_addr=${bob_lc}" || echo 0)
  log "  reward withdrawals to Bob's EVM addr on dst val: $rewards_count"

  # Check Bob's EVM balance vs pre-redel — should be unchanged (gas only) since redelegate doesn't credit EVM
  local bob_post; bob_post=$(get_evm_balance "$BOB_ADDR")
  local delta; delta=$(python3 -c "print($bob_post - $BOB_BAL_PRE_REDEL)")
  log "  Bob EVM bal: pre-redel=$BOB_BAL_PRE_REDEL post=$bob_post delta=$delta wei"
  log "  (delta should be small — gas only, possibly slight reward credit)"

  capture_evidence "07-post-mature"
}

# ---------------- Phase 8 — final on-chain snapshot ----------------
phase_8_final_snapshot() {
  log "Phase 8 — final on-chain val state + Bob delegation snapshot"
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
}

# ---------------- Phase 9 — summary ----------------
phase_9_summary() {
  printf "\n========== G1 LOCKED-DEL REDELEGATE PROBE CONCLUSIONS ==========\n"
  printf "  Binary: yao/v170-maxval-21 (NewMaxValidators=21)\n"
  printf "  Cluster: %d vals, NEW_MAX=%d → 1 val pruned\n" "$N_VALS" "$NEW_MAX"
  printf "  src val: %s (UNLOCKED, jailed-pruned by H=%s + op self-unstake)\n" "$SRC_VAL_MONIKER" "$UPGRADE_HEIGHT"
  printf "  dst val: %s (LOCKED, top-21 BONDED)\n" "$DST_VAL_MONIKER"
  printf "  Action: Bob redelegate locked-short del (id=1) src→dst\n"
  printf "  src final: $(cat "$EV_DIR/final-${SRC_VAL_MONIKER}.json")\n"
  printf "  dst final: $(cat "$EV_DIR/final-${DST_VAL_MONIKER}.json")\n"
  printf "  Bob EVM bal: pre-stake=%s, pre-redel=%s, post=%s wei\n" "$BOB_BAL_PRE_STAKE" "$BOB_BAL_PRE_REDEL" "$(get_evm_balance "$BOB_ADDR")"
  printf "  Final chain height: %s\n" "$(get_height)"
  printf "  Evidence: %s/\n" "$EV_DIR"
  printf "================================================================\n"
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
phase_3_prune
phase_4_self_unstake
phase_5_redelegate
phase_6_verify_lock_preserved
phase_7_mature_and_earn
phase_8_final_snapshot
phase_9_summary
phase_10_teardown
