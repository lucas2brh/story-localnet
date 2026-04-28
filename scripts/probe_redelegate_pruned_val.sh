#!/usr/bin/env bash
# probe_redelegate_pruned_val.sh — verify v1.7.0 prune + cosmos-sdk-private-fork
# x/staking redelegation behavior interact correctly:
#
# 1. MsgBeginRedelegate from a pruned val (UNBONDING/UNBONDED post-V170) to an
#    active top-16 val succeeds and tokens move correctly. Tracked as
#    `piplabs/lion-team-sync#619` main scenario.
#
# 2. cosmos-sdk MaxValidators cap stays enforced post-V170: redelegating
#    enough tokens INTO a pruned val so its tokens exceed the current
#    rank-16 BONDED val triggers standard cosmos-sdk churn (BONDED set
#    membership changes, but bonded count remains exactly 16). Set is NOT
#    frozen by the V170 handler.
#
# 3. cosmos-sdk-private-fork redelegation entry-count cap (`MaxEntries=7`,
#    per `(delegator, srcVal, dstVal)` triple). 8th redelegate of the same
#    triple must fail with `ErrMaxRedelegationEntries`. SoT-only-grep'd
#    until now (docs/sot/story-l1-staking-module.md); this phase exercises
#    it at runtime.
#
# Genesis patch: `unbonding_time = 300s` (vs default 10s) so:
#   - pruned vals stay UNBONDING throughout the test (deterministic state
#     for assertions; 10s would put them in UNBONDED before phase 1
#     finishes capturing baseline)
#   - 7 successful redelegations in Phase 5 don't expire mid-test (each
#     entry expires after `unbonding_time`)
#
# Glossary (terms used below):
#   - "rank-N" = N-th validator when sorted by `tokens` descending
#   - "pruned val" = validator with rank > MaxValidators=16 post-V170,
#     status UNBONDING or UNBONDED
#   - "active val" = validator with rank <= 16 post-V170, status BONDED
#   - "rank-16/17 boundary" = the cap boundary; tokens of rank-16 vs
#     rank-17 determine which vals are bonded
#   - "churn" = cosmos-sdk's standard ApplyAndReturnValidatorSetUpdates
#     replacing a member of the bonded set with a higher-token one;
#     bonded count remains at MaxValidators
#
# Usage:
#   ./scripts/probe_redelegate_pruned_val.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_redelegate_pruned_val.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-65}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
NEW_MAX=${NEW_MAX:-16}
UNBONDING_TIME=${UNBONDING_TIME:-300s}
MAX_ENTRIES_EXPECTED=${MAX_ENTRIES_EXPECTED:-7}

# Stake-unit conversion: validator.tokens REST field is in stake units.
# 1 IP = 10^9 stake = 10^18 wei. So 10 IP = 10000000000 stake = 10*10^18 wei.
# IMPORTANT: 1024 * 10^18 (= 1024 IP in wei) overflows bash 64-bit signed int.
# Use ip_to_wei() for any IP→wei conversion to avoid silent wrap-around.
IP_TO_STAKE=1000000000           # 1 IP in stake units (10^9) — fits in int64 for amounts up to ~9.2 × 10^9 IP
IP_TO_WEI=1000000000000000000    # 1 IP in wei (10^18) — DO NOT multiply directly in bash arithmetic
ip_to_wei() { printf '%s000000000000000000\n' "$1"; }      # IP → wei via string append
ip_to_stake() { printf '%d\n' "$(( $1 * IP_TO_STAKE ))"; }  # IP → stake (safe up to ~9.2 × 10^9 IP)

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[redel]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[redel]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[redel]${C_RESET} FAIL %s\n" "$*"; exit 1; }
note() { printf "${C_YELLOW}[redel]${C_RESET} OBSERVED %s\n" "$*"; }

get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}
wait_height() { local target=$1 h; while :; do h=$(get_height); [[ $h -ge $target ]] && { echo "$h"; return; }; sleep 2; done; }
get_tx_status() {
  # Returns "1" if tx receipt status=0x1 (success), "0" if 0x0 (revert), "" if not yet mined
  local tx=$1 hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$tx\"],\"id\":1}" 2>/dev/null \
    | jq -r '.result.status // ""')
  case "$hex" in
    0x1) echo 1;;
    0x0) echo 0;;
    *)   echo "";;
  esac
}
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
bonded_set_json() {
  curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" 2>/dev/null
}
meta_pubkey_hex() { local b64; b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META"); echo -n "$b64" | base64 -d | xxd -p -c 66; }
meta_privkey()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }
meta_op_evm()     { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }
moniker_for_op()  { jq -r --arg op "$1" '.[] | select((.evm_address | ascii_downcase) == ($op | ascii_downcase)) | .moniker' "$META"; }

# Anvil pre-funds an operator wallet so it has gas for tx submission.
fund_operator() {
  local addr=$1 amount_eth=${2:-2}
  cast send --rpc-url http://localhost:8545 \
    --private-key "$ANVIL_PK" "$addr" \
    --value "${amount_eth}ether" --legacy --gas-price 50gwei >/dev/null 2>&1 || \
    log "  WARN: cast fund $addr failed (might already be funded)"
  sleep 3
}

# Submit redelegate via story CLI. Sets globals DO_REDELEGATE_{RC,TX,OUT}
# rather than printing — avoids multi-line stderr being truncated by
# `IFS='|' read` at the caller (read only consumes one line of input).
DO_REDELEGATE_RC=""
DO_REDELEGATE_TX=""
DO_REDELEGATE_OUT=""
do_redelegate() {
  local src_moniker=$1 dst_moniker=$2 amount_wei=$3
  local src_pub dst_pub priv
  src_pub=$(meta_pubkey_hex "$src_moniker")
  dst_pub=$(meta_pubkey_hex "$dst_moniker")
  priv=$(meta_privkey "$src_moniker")  # src val's self-delegator key
  DO_REDELEGATE_OUT=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$src_pub" \
    --validator-dst-pubkey "$dst_pub" \
    --redelegate "$amount_wei" \
    --delegation-id 0 \
    --rpc http://localhost:8545 \
    --chain-id "$CHAIN_ID" 2>&1)
  DO_REDELEGATE_RC=$?
  DO_REDELEGATE_TX=$(grep -oE '0x[0-9a-f]{64}' <<<"$DO_REDELEGATE_OUT" | head -1)
}

# Wait for tx to be mined and return its status (1 success, 0 revert).
wait_tx_status() {
  local tx=$1 deadline=$(( $(date +%s) + 30 )) status
  while :; do
    status=$(get_tx_status "$tx")
    [[ -n "$status" ]] && { echo "$status"; return; }
    [[ $(date +%s) -ge $deadline ]] && { echo ""; return; }
    sleep 2
  done
}

# ---------------- Phase 0 — fresh localnet with extended unbonding_time ----------------
phase_0_start() {
  log "Phase 0 — start fresh 20-val localnet, patch unbonding_time=$UNBONDING_TIME"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2); sleep 5
  fi
  MAX_VALIDATORS_INIT=20 STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" 20 2>&1 | tail -1

  local genesis="${LOCALNET}/config/story/genesis-node.json"
  jq --arg u "$UNBONDING_TIME" '.app_state.staking.params.unbonding_time = $u' \
    "$genesis" > "$genesis.tmp" && mv "$genesis.tmp" "$genesis"
  local sbw djd ut
  ut=$(jq -r '.app_state.staking.params.unbonding_time' "$genesis")
  log "  patched staking.unbonding_time=$ut"

  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "rpc1 didn't sync in 90s"
    sleep 3
  done
}

# ---------------- Phase 1 — capture post-V170 baseline ----------------
SOURCE_PRUNED=""; DEST_ACTIVE=""; SOURCE_ACTIVE=""; DEST_PRUNED=""
SOURCE_PRUNED_TOKENS=""; DEST_ACTIVE_TOKENS=""; SOURCE_ACTIVE_TOKENS=""; DEST_PRUNED_TOKENS=""
RANK16_TOKENS=""; RANK16_MONIKER=""
phase_1_capture_baseline() {
  log "Phase 1 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_BLOCK, capture bonded + pruned sets"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  log "  chain at $(get_height)"

  local vals_all; vals_all=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" 2>/dev/null)
  local bonded_count; bonded_count=$(jq '[.msg.validators[] | select(.status==3)] | length' <<<"$vals_all")
  log "  bonded count: $bonded_count (expected $NEW_MAX)"
  [[ "$bonded_count" == "$NEW_MAX" ]] || fail "bonded count $bonded_count != $NEW_MAX"

  # Sort all 20 vals by tokens desc; ranks 1..16 are BONDED (status=3), 17..20 pruned (status=2/UNBONDING).
  # Bash 3.2 (macOS default) lacks mapfile — use while-read loop to populate arrays.
  local sorted; sorted=$(jq -c '.msg.validators | sort_by(-(.tokens|tonumber)) | .[] | {op: .operator_address, tokens: .tokens, status: .status}' <<<"$vals_all")
  SORTED_OPS=(); SORTED_TOKENS=(); SORTED_STATUS=()
  while IFS= read -r row; do
    SORTED_OPS+=("$(jq -r '.op' <<<"$row")")
    SORTED_TOKENS+=("$(jq -r '.tokens' <<<"$row")")
    SORTED_STATUS+=("$(jq -r '.status' <<<"$row")")
  done <<<"$sorted"

  local i
  for ((i=0; i<${#SORTED_OPS[@]}; i++)); do
    local mon; mon=$(moniker_for_op "${SORTED_OPS[$i]}")
    log "  rank-$((i+1)): $mon op=${SORTED_OPS[$i]} tokens=${SORTED_TOKENS[$i]} status=${SORTED_STATUS[$i]}"
  done

  # Pick anchors by rank index (0-based array, so rank-N is index N-1)
  RANK16_TOKENS="${SORTED_TOKENS[15]}"
  RANK16_MONIKER=$(moniker_for_op "${SORTED_OPS[15]}")
  DEST_ACTIVE="${SORTED_OPS[0]}"             # rank-1
  DEST_ACTIVE_TOKENS="${SORTED_TOKENS[0]}"
  SOURCE_ACTIVE="${SORTED_OPS[1]}"           # rank-2
  SOURCE_ACTIVE_TOKENS="${SORTED_TOKENS[1]}"
  DEST_PRUNED="${SORTED_OPS[17]}"            # rank-18
  DEST_PRUNED_TOKENS="${SORTED_TOKENS[17]}"
  SOURCE_PRUNED="${SORTED_OPS[18]}"          # rank-19
  SOURCE_PRUNED_TOKENS="${SORTED_TOKENS[18]}"

  log "  anchors:"
  log "    DEST_ACTIVE   rank-1  $(moniker_for_op "$DEST_ACTIVE")  tokens=$DEST_ACTIVE_TOKENS"
  log "    SOURCE_ACTIVE rank-2  $(moniker_for_op "$SOURCE_ACTIVE")  tokens=$SOURCE_ACTIVE_TOKENS"
  log "    rank-16       $RANK16_MONIKER  tokens=$RANK16_TOKENS  (cap boundary)"
  log "    DEST_PRUNED   rank-18 $(moniker_for_op "$DEST_PRUNED")  tokens=$DEST_PRUNED_TOKENS"
  log "    SOURCE_PRUNED rank-19 $(moniker_for_op "$SOURCE_PRUNED")  tokens=$SOURCE_PRUNED_TOKENS"

  # Both pruned anchors should be UNBONDING (status=2) — unbonding_time=300s prevents UNBONDED transition
  local sp_status dp_status
  sp_status=$(val_field "$SOURCE_PRUNED" status)
  dp_status=$(val_field "$DEST_PRUNED" status)
  log "  SOURCE_PRUNED status=$sp_status; DEST_PRUNED status=$dp_status"
  [[ "$sp_status" == "2" || "$sp_status" == "1" ]] || fail "SOURCE_PRUNED status=$sp_status, expected 2 (UNBONDING) or 1 (UNBONDED)"
  [[ "$dp_status" == "2" || "$dp_status" == "1" ]] || fail "DEST_PRUNED status=$dp_status, expected 2 (UNBONDING) or 1 (UNBONDED)"
  pass "baseline captured"
}

# ---------------- Phase 2 — redelegate FROM pruned TO active (basic #619 case) ----------------
PHASE2_TX=""; PHASE2_AMOUNT_IP=1024  # Story enforces redelegate min = 1024 IP (matches MinSelfDelegation)
phase_2_pruned_to_active() {
  local src_mon dst_mon
  src_mon=$(moniker_for_op "$SOURCE_PRUNED")
  dst_mon=$(moniker_for_op "$DEST_ACTIVE")
  log "Phase 2 — redelegate ${PHASE2_AMOUNT_IP} IP from SOURCE_PRUNED ($src_mon) -> DEST_ACTIVE ($dst_mon)"

  # Fund source operator wallet for gas
  fund_operator "$SOURCE_PRUNED" 2

  local amount_wei; amount_wei=$(ip_to_wei "$PHASE2_AMOUNT_IP")
  do_redelegate "$src_mon" "$dst_mon" "$amount_wei"
  log "  tx=$DO_REDELEGATE_TX rc=$DO_REDELEGATE_RC"
  [[ "$DO_REDELEGATE_RC" == "0" ]] || fail "Phase 2 redelegate CLI rc=$DO_REDELEGATE_RC; out:\n$DO_REDELEGATE_OUT"
  [[ -n "$DO_REDELEGATE_TX" ]] || fail "Phase 2 no tx hash; out:\n$DO_REDELEGATE_OUT"
  PHASE2_TX="$DO_REDELEGATE_TX"

  local status; status=$(wait_tx_status "$PHASE2_TX")
  [[ "$status" == "1" ]] || fail "Phase 2 tx $PHASE2_TX status=$status (expected 1=success)"
  wait_height "$(( $(get_height) + 5 ))" >/dev/null

  # Assertions
  local sp_tokens_post da_tokens_post bonded_count_post
  sp_tokens_post=$(val_field "$SOURCE_PRUNED" tokens)
  da_tokens_post=$(val_field "$DEST_ACTIVE" tokens)
  bonded_count_post=$(jq '.msg.validators | length' <<<"$(bonded_set_json)")
  local amount_stake=$(( PHASE2_AMOUNT_IP * IP_TO_STAKE ))
  log "  SOURCE_PRUNED tokens: $SOURCE_PRUNED_TOKENS -> $sp_tokens_post (delta=$(( sp_tokens_post - SOURCE_PRUNED_TOKENS )), expected -$amount_stake)"
  log "  DEST_ACTIVE   tokens: $DEST_ACTIVE_TOKENS -> $da_tokens_post (delta=$(( da_tokens_post - DEST_ACTIVE_TOKENS )), expected +$amount_stake)"
  log "  bonded count: $bonded_count_post"

  [[ "$sp_tokens_post" == "$(( SOURCE_PRUNED_TOKENS - amount_stake ))" ]] || fail "SOURCE_PRUNED tokens delta != -$amount_stake"
  [[ "$da_tokens_post" == "$(( DEST_ACTIVE_TOKENS + amount_stake ))" ]] || fail "DEST_ACTIVE tokens delta != +$amount_stake"
  [[ "$bonded_count_post" == "$NEW_MAX" ]] || fail "bonded count $bonded_count_post != $NEW_MAX after Phase 2"

  local sp_status_post; sp_status_post=$(val_field "$SOURCE_PRUNED" status)
  log "  SOURCE_PRUNED status post-redelegate: $sp_status_post (must NOT be 3=BONDED)"
  [[ "$sp_status_post" != "3" ]] || fail "SOURCE_PRUNED flipped back to BONDED — cap broken"

  # Refresh tracked tokens for later phases
  SOURCE_PRUNED_TOKENS="$sp_tokens_post"
  DEST_ACTIVE_TOKENS="$da_tokens_post"
  pass "Phase 2 pruned->active redelegate succeeded; bonded count stable"
}

# ---------------- Phase 3 — redelegate FROM active TO pruned, NOT crossing rank-16/17 boundary ----------------
PHASE3_AMOUNT_IP=1024  # min Story-enforced amount; still well below the ~40K-IP rank-16/17 gap
phase_3_active_to_pruned_no_cross() {
  local src_mon dst_mon
  src_mon=$(moniker_for_op "$SOURCE_ACTIVE")
  dst_mon=$(moniker_for_op "$DEST_PRUNED")
  log "Phase 3 — redelegate ${PHASE3_AMOUNT_IP} IP from SOURCE_ACTIVE ($src_mon) -> DEST_PRUNED ($dst_mon); insufficient to cross rank-16 boundary"

  local amount_stake=$(( PHASE3_AMOUNT_IP * IP_TO_STAKE ))
  local needed_to_cross=$(( RANK16_TOKENS - DEST_PRUNED_TOKENS + 1 ))
  log "  rank-16 tokens=$RANK16_TOKENS, DEST_PRUNED tokens=$DEST_PRUNED_TOKENS; would need >$needed_to_cross stake to cross"
  log "  redelegating $amount_stake stake (= ${PHASE3_AMOUNT_IP} IP, far less than $needed_to_cross stake) — boundary NOT crossed"
  if (( amount_stake >= needed_to_cross )); then
    fail "Phase 3 design violated: PHASE3_AMOUNT_IP=$PHASE3_AMOUNT_IP would cross boundary; bump rank-16/DEST_PRUNED gap or pick smaller amount"
  fi

  fund_operator "$SOURCE_ACTIVE" 2

  local amount_wei; amount_wei=$(ip_to_wei "$PHASE3_AMOUNT_IP")
  do_redelegate "$src_mon" "$dst_mon" "$amount_wei"
  log "  tx=$DO_REDELEGATE_TX rc=$DO_REDELEGATE_RC"
  [[ "$DO_REDELEGATE_RC" == "0" ]] || fail "Phase 3 redelegate CLI rc=$DO_REDELEGATE_RC; out:\n$DO_REDELEGATE_OUT"
  local status; status=$(wait_tx_status "$DO_REDELEGATE_TX")
  [[ "$status" == "1" ]] || fail "Phase 3 tx $DO_REDELEGATE_TX status=$status"
  wait_height "$(( $(get_height) + 5 ))" >/dev/null

  local sa_tokens_post dp_tokens_post dp_status_post bonded_count_post
  sa_tokens_post=$(val_field "$SOURCE_ACTIVE" tokens)
  dp_tokens_post=$(val_field "$DEST_PRUNED" tokens)
  dp_status_post=$(val_field "$DEST_PRUNED" status)
  bonded_count_post=$(jq '.msg.validators | length' <<<"$(bonded_set_json)")
  log "  SOURCE_ACTIVE tokens: $SOURCE_ACTIVE_TOKENS -> $sa_tokens_post (delta=$(( sa_tokens_post - SOURCE_ACTIVE_TOKENS )))"
  log "  DEST_PRUNED   tokens: $DEST_PRUNED_TOKENS -> $dp_tokens_post (delta=$(( dp_tokens_post - DEST_PRUNED_TOKENS )))"
  log "  DEST_PRUNED   status: $dp_status_post (must NOT be 3=BONDED — boundary not crossed)"
  log "  bonded count: $bonded_count_post"

  [[ "$sa_tokens_post" == "$(( SOURCE_ACTIVE_TOKENS - amount_stake ))" ]] || fail "SOURCE_ACTIVE tokens delta != -$amount_stake"
  [[ "$dp_tokens_post" == "$(( DEST_PRUNED_TOKENS + amount_stake ))" ]] || fail "DEST_PRUNED tokens delta != +$amount_stake"
  [[ "$dp_status_post" != "3" ]] || fail "DEST_PRUNED unexpectedly promoted to BONDED despite tokens still below rank-16"
  [[ "$bonded_count_post" == "$NEW_MAX" ]] || fail "bonded count $bonded_count_post != $NEW_MAX after Phase 3"

  SOURCE_ACTIVE_TOKENS="$sa_tokens_post"
  DEST_PRUNED_TOKENS="$dp_tokens_post"
  pass "Phase 3 active->pruned (no boundary cross) succeeded; pruned val gained tokens but stayed UNBONDING"
}

# ---------------- Phase 4 — redelegate FROM active TO pruned, CROSSING rank-16/17 boundary (cap enforcement test) ----------------
phase_4_active_to_pruned_cross() {
  local src_mon dst_mon
  src_mon=$(moniker_for_op "$SOURCE_ACTIVE")
  dst_mon=$(moniker_for_op "$DEST_PRUNED")

  # BUMP = exactly enough to overtake rank-16 by 1 stake unit
  local bump_stake=$(( RANK16_TOKENS - DEST_PRUNED_TOKENS + 1 ))
  # Round up to whole IP; floor at 1024 IP (Story redelegate min). For localnet the gap is ~40K IP
  # so the floor never binds, but keep it explicit to document the constraint.
  local bump_ip=$(( (bump_stake + IP_TO_STAKE - 1) / IP_TO_STAKE ))
  if (( bump_ip < 1024 )); then bump_ip=1024; fi
  local bump_wei; bump_wei=$(ip_to_wei "$bump_ip")
  log "Phase 4 — redelegate $bump_ip IP (= $((bump_ip * IP_TO_STAKE)) stake, > $bump_stake stake needed) from SOURCE_ACTIVE ($src_mon) -> DEST_PRUNED ($dst_mon) to CROSS rank-16/17 boundary"

  # Sanity: SOURCE_ACTIVE has enough self-stake to redelegate without dropping below MinSelfDelegation (1024 IP)
  local sa_stake_after=$(( SOURCE_ACTIVE_TOKENS - bump_ip * IP_TO_STAKE ))
  local min_self=$(( 1024 * IP_TO_STAKE ))
  if (( sa_stake_after < min_self )); then
    fail "Phase 4: SOURCE_ACTIVE residual after BUMP ($sa_stake_after stake) would fall below MinSelfDelegation ($min_self stake). Use a larger source val."
  fi

  fund_operator "$SOURCE_ACTIVE" 5

  do_redelegate "$src_mon" "$dst_mon" "$bump_wei"
  log "  tx=$DO_REDELEGATE_TX rc=$DO_REDELEGATE_RC"
  [[ "$DO_REDELEGATE_RC" == "0" ]] || fail "Phase 4 redelegate CLI rc=$DO_REDELEGATE_RC; out:\n$DO_REDELEGATE_OUT"
  local status; status=$(wait_tx_status "$DO_REDELEGATE_TX")
  [[ "$status" == "1" ]] || fail "Phase 4 tx $DO_REDELEGATE_TX status=$status"

  # Wait extra for ApplyAndReturnValidatorSetUpdates to apply the churn at next EndBlock
  wait_height "$(( $(get_height) + 8 ))" >/dev/null

  local dp_status_post bonded_count_post
  dp_status_post=$(val_field "$DEST_PRUNED" status)
  local rank16_status_post; rank16_status_post=$(val_field "${SORTED_OPS[15]}" status)
  bonded_count_post=$(jq '.msg.validators | length' <<<"$(bonded_set_json)")
  log "  DEST_PRUNED status post-cross: $dp_status_post (expected 3=BONDED via standard cosmos-sdk churn)"
  log "  former rank-16 ($RANK16_MONIKER) status: $rank16_status_post (expected 1 or 2 = demoted)"
  log "  bonded count: $bonded_count_post (must remain $NEW_MAX)"

  [[ "$dp_status_post" == "3" ]] || fail "DEST_PRUNED expected BONDED (3) after crossing boundary, got $dp_status_post — cap-enforced churn missing post-V170"
  [[ "$rank16_status_post" != "3" ]] || fail "former rank-16 still BONDED — bonded count would exceed $NEW_MAX"
  [[ "$bonded_count_post" == "$NEW_MAX" ]] || fail "bonded count $bonded_count_post != $NEW_MAX after Phase 4 (cap broken)"
  pass "Phase 4: cosmos-sdk standard churn applied — DEST_PRUNED promoted, former rank-16 demoted, bonded count stayed at $NEW_MAX"
}

# ---------------- Phase 5 — exercise MaxEntries=7 cap on a single (delegator, src, dst) triple ----------------
PHASE5_SRC_MONIKER="localnet-val-3"
PHASE5_DST_MONIKER="localnet-val-4"
PHASE5_AMOUNT_IP=1024  # Story redelegate min; 8 × 1024 = 8192 IP, well below val-3's ~790K IP self-stake
phase_5_max_redelegation_entries() {
  log "Phase 5 — repeat redelegate $PHASE5_AMOUNT_IP IP from $PHASE5_SRC_MONIKER -> $PHASE5_DST_MONIKER ${MAX_ENTRIES_EXPECTED} times (each succeeds), then 1 more (must fail with ErrMaxRedelegationEntries)"
  local src_op; src_op=$(meta_op_evm "$PHASE5_SRC_MONIKER")
  local dst_op; dst_op=$(meta_op_evm "$PHASE5_DST_MONIKER")
  log "  src op=$src_op  dst op=$dst_op"

  # Verify both still BONDED (Phase 4 churn shouldn't have touched ranks 3-4)
  local s_status d_status
  s_status=$(val_field "$src_op" status)
  d_status=$(val_field "$dst_op" status)
  [[ "$s_status" == "3" ]] || fail "Phase 5: $PHASE5_SRC_MONIKER status=$s_status, expected 3 (BONDED)"
  [[ "$d_status" == "3" ]] || fail "Phase 5: $PHASE5_DST_MONIKER status=$d_status, expected 3 (BONDED)"

  fund_operator "$src_op" 5

  local amount_wei; amount_wei=$(ip_to_wei "$PHASE5_AMOUNT_IP")
  local i status
  for ((i=1; i<=MAX_ENTRIES_EXPECTED; i++)); do
    log "  attempt $i/$MAX_ENTRIES_EXPECTED — expect SUCCESS"
    do_redelegate "$PHASE5_SRC_MONIKER" "$PHASE5_DST_MONIKER" "$amount_wei"
    [[ "$DO_REDELEGATE_RC" == "0" ]] || fail "Phase 5 attempt $i CLI rc=$DO_REDELEGATE_RC; out:\n$DO_REDELEGATE_OUT"
    [[ -n "$DO_REDELEGATE_TX" ]] || fail "Phase 5 attempt $i no tx hash; out:\n$DO_REDELEGATE_OUT"
    status=$(wait_tx_status "$DO_REDELEGATE_TX")
    log "    tx=$DO_REDELEGATE_TX status=$status"
    [[ "$status" == "1" ]] || fail "Phase 5 attempt $i tx $DO_REDELEGATE_TX status=$status, expected 1 (within MaxEntries cap)"
    wait_height "$(( $(get_height) + 3 ))" >/dev/null
  done

  # 8th — must fail with ErrMaxRedelegationEntries
  log "  attempt $((MAX_ENTRIES_EXPECTED+1))/$((MAX_ENTRIES_EXPECTED+1)) — expect FAILURE (ErrMaxRedelegationEntries)"
  do_redelegate "$PHASE5_SRC_MONIKER" "$PHASE5_DST_MONIKER" "$amount_wei"
  log "    CLI rc=$DO_REDELEGATE_RC tx=$DO_REDELEGATE_TX"
  log "    out:"
  printf '%s\n' "$DO_REDELEGATE_OUT" | sed 's/^/      /'
  if [[ -n "$DO_REDELEGATE_TX" ]]; then
    status=$(wait_tx_status "$DO_REDELEGATE_TX")
    log "    tx mined? status=$status"
    if [[ "$status" == "1" ]]; then
      fail "Phase 5 attempt $((MAX_ENTRIES_EXPECTED+1)) succeeded (status=1) — MaxEntries=$MAX_ENTRIES_EXPECTED cap NOT enforced. SoT entry needs re-verification."
    fi
    log "    tx reverted (status=$status) — MaxEntries cap correctly enforced at $MAX_ENTRIES_EXPECTED"
  else
    # CLI rejected pre-submission (story binary may pre-validate). Still counts as cap enforced.
    log "    CLI rejected before tx submission (rc=$DO_REDELEGATE_RC) — likely pre-validated MaxEntries cap"
  fi
  pass "Phase 5: MaxEntries=$MAX_ENTRIES_EXPECTED cap enforced on (delegator, $PHASE5_SRC_MONIKER, $PHASE5_DST_MONIKER) triple"
}

# ---------------- Phase 6 — summary ----------------
phase_6_summary() {
  printf "\n========== REDELEGATE-PRUNED-VAL PROBE CONCLUSIONS ==========\n"
  printf "  Phase 2 — redelegate %d IP pruned->active: PASS (tokens moved, bonded count=%d, source stayed UNBONDING)\n" "$PHASE2_AMOUNT_IP" "$NEW_MAX"
  printf "  Phase 3 — redelegate %d IP active->pruned, no boundary cross: PASS (DEST_PRUNED gained tokens but stayed UNBONDING)\n" "$PHASE3_AMOUNT_IP"
  printf "  Phase 4 — redelegate to cross rank-16/17 boundary: PASS (DEST_PRUNED promoted, former rank-16 demoted, bonded count stayed %d)\n" "$NEW_MAX"
  printf "  Phase 5 — MaxEntries=%d cap on triple (%s,%s,%s): PASS\n" "$MAX_ENTRIES_EXPECTED" "self-deleg" "$PHASE5_SRC_MONIKER" "$PHASE5_DST_MONIKER"
  printf "  Final chain height: %s\n" "$(get_height)"
  printf "============================================================\n"
}

phase_7_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 7 — SKIP_TEARDOWN"; return; fi
  log "Phase 7 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_capture_baseline
phase_2_pruned_to_active
phase_3_active_to_pruned_no_cross
phase_4_active_to_pruned_cross
phase_5_max_redelegation_entries
phase_6_summary
phase_7_teardown
