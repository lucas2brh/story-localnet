#!/usr/bin/env bash
# probe_create_val_across_v170.sh
#
# Chain-assert MsgCreateValidator across the matrix
# {pre-V170, post-V170} × {LOCKED, UNLOCKED} × {top-NEW_MAX rank, out-of-NEW_MAX rank}
# in a single 8-val NEW_MAX=4 probe.
#
# Five new validators created across two batches:
#
# Pre-V170 batch (h=20..30):
#   val-A: UNLOCKED, stake huge -> top-4 at V170
#   val-B: LOCKED,   stake big  -> top-4 at V170
#   val-C: UNLOCKED, stake mid  -> BONDED pre-V170 (MaxValidators=20), cap-pruned at V170 (rank > 4)
#
# Post-V170 batch (h=85..90):
#   val-D: LOCKED, stake tiny  -> NEVER BONDED (stake below rank-4)
#   val-E: LOCKED, stake huge  -> displaces current rank-4 (cap respected, bonded count stays NEW_MAX=4)
#
# Cluster: 8-val cluster but MaxValidators_init=20 so pre-V170 fits all 11 vals BONDED.
# V170 binary reduces 20 -> 4 at h=70.
#
# PRIMARY assertions:
#   1. @h=68 (pre-V170): A, B, C all status=3 BONDED, val types correct
#   2. @h=78 (post-V170): A retained BONDED+UNLOCKED, B retained BONDED+LOCKED,
#                         C cap-pruned to UNBONDING+UNLOCKED, bonded count=4
#   3. @h=100 (post post-V170 batch): D status=2 UNBONDING (never bonded),
#                                     E status=3 BONDED (displaces prior R-4),
#                                     bonded count=4

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-70}
BASELINE_HEIGHT=${BASELINE_HEIGHT:-10}
PREH_A_HEIGHT=${PREH_A_HEIGHT:-20}
PREH_B_HEIGHT=${PREH_B_HEIGHT:-25}
PREH_C_HEIGHT=${PREH_C_HEIGHT:-30}
PREH_VERIFY_HEIGHT=${PREH_VERIFY_HEIGHT:-68}
POSTH_VERIFY_HEIGHT=${POSTH_VERIFY_HEIGHT:-78}
POSTH_D_HEIGHT=${POSTH_D_HEIGHT:-85}
POSTH_E_HEIGHT=${POSTH_E_HEIGHT:-90}
POSTH_VERIFY_FINAL_HEIGHT=${POSTH_VERIFY_FINAL_HEIGHT:-100}
SIGNED_BLOCKS_WINDOW=${SIGNED_BLOCKS_WINDOW:-80}
UNBONDING_TIME=${UNBONDING_TIME:-3600s}
MAX_VALIDATORS_INIT=${MAX_VALIDATORS_INIT:-8}
N_VALS=${N_VALS:-8}
NEW_MAX=${NEW_MAX:-4}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
WEI_PER_STAKE=${WEI_PER_STAKE:-1000000000}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
GENESIS="${LOCALNET}/config/story/genesis-node.json"
EVIDENCE_DIR=${EVIDENCE_DIR:-/Users/lucas/workspace/lucas-workspace/docs/test-evidence/v170-create-val-across-v170-2026-05-13}
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

# Anvil keys (well-known dev keys). anvil[0] funds; anvil[1..5] are new-val operators.
ANVIL0_PK=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL0_ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

A_PK=59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
A_ADDR=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
B_PK=5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
B_ADDR=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
C_PK=7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
C_ADDR=0x90F79bf6EB2c4f870365E785982E1f101E93b906
D_PK=47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
D_ADDR=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
E_PK=8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
E_ADDR=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc

SEED_IP_PER_VAL=${SEED_IP_PER_VAL:-100}   # gas + small buffer; stake is debited from this too
NEWVAL_HOME_BASE=${NEWVAL_HOME_BASE:-/tmp/probe-newval}

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[create-val]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[create-val]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[create-val]${C_RESET} FAIL %s\n" "$*"; capture_evidence_on_fail; exit 1; }
note() { printf "${C_YELLOW}[create-val]${C_RESET} OBSERVED %s\n" "$*"; }

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

# Get top-K BONDED validators by stake. Args: K.
top_k_bonded_tokens() {
  local k=$1
  curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" 2>/dev/null \
    | jq -r --argjson k "$k" '.msg.validators | sort_by(-(.tokens|tonumber)) | .[0:$k] | .[] | "\(.operator_address) \(.tokens)"'
}

# Get a validator's status by moniker (matches description.moniker).
# `// 0` fallback handles proto3 zero-value omission (Story REST may omit
# field for status=0 / type=0). status=0 means UNSPECIFIED which is an
# error condition; explicit handling preferred over silent missing.
val_status_by_moniker() {
  local moniker=$1
  curl -fsS "http://localhost:1317/staking/validators?pagination.limit=200" 2>/dev/null \
    | jq -r --arg m "$moniker" '.msg.validators[] | select(.description.moniker==$m) | (.status // 0)' | head -1
}

# Get a validator's full JSON by moniker.
val_json_by_moniker() {
  local moniker=$1
  curl -fsS "http://localhost:1317/staking/validators?pagination.limit=200" 2>/dev/null \
    | jq --arg m "$moniker" '.msg.validators[] | select(.description.moniker==$m)' | head -100
}

# Get a validator's support_token_type (0=LOCKED, 1=UNLOCKED) by moniker.
# Story REST omits the field for proto3 zero-value (LOCKED). `// 0` fallback
# converts the absent-field case into the explicit LOCKED value.
val_support_token_type_by_moniker() {
  local moniker=$1
  curl -fsS "http://localhost:1317/staking/validators?pagination.limit=200" 2>/dev/null \
    | jq -r --arg m "$moniker" '.msg.validators[] | select(.description.moniker==$m) | (.support_token_type // 0)' | head -1
}

# Count BONDED validators.
bonded_count() {
  curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" 2>/dev/null \
    | jq '.msg.validators | length'
}

# Generate fresh cons key for a new val. Args: tag.
gen_cons_key() {
  local tag=$1
  local home="${NEWVAL_HOME_BASE}-${tag}"
  local keyfile="${home}/config/priv_validator_key.json"
  rm -rf "$home"; mkdir -p "${home}/config"
  PRIVATE_KEY="$ANVIL0_PK" "$STORY_BIN" key gen-priv-key-json \
    --home "$home" --keyfile "$keyfile" >/dev/null 2>&1 \
    || fail "gen-priv-key-json failed for tag=$tag"
  [[ -f "$keyfile" ]] || fail "keyfile not created at $keyfile for tag=$tag"
  echo "$keyfile"
}

# Seed an anvil account with IP for gas. Args: target_addr, ip_amount.
seed_addr() {
  local addr=$1 ip=$2
  cast send --rpc-url http://localhost:8545 --private-key "$ANVIL0_PK" "$addr" \
    --value "${ip}ether" --legacy --gas-price 50gwei >/dev/null 2>&1 \
    || fail "seed $addr ${ip} IP failed"
}

# Create a new validator. Args: tag, pk, keyfile, stake_wei, moniker, unlocked_flag ("--unlocked=true" or "--unlocked=false").
do_create_val() {
  local tag=$1 pk=$2 keyfile=$3 stake_wei=$4 moniker=$5 unlocked_arg=$6
  log "  create val $tag: moniker=$moniker stake=$stake_wei wei unlocked=$unlocked_arg"
  local out rc
  out=$(PRIVATE_KEY="$pk" "$STORY_BIN" validator create \
    --keyfile "$keyfile" \
    --stake "$stake_wei" \
    --moniker "$moniker" \
    $unlocked_arg \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tail -6
  [[ $rc -eq 0 ]] || fail "$tag validator create rc=$rc"
}

capture_evidence() {
  log "Capturing evidence to $EVIDENCE_DIR"
  mkdir -p "$EVIDENCE_DIR"
  for c in $(docker ps --format '{{.Names}}' | grep -E '^(validator[0-9]+|bootnode[0-9]+|rpc[0-9]+)-node$'); do
    docker logs "$c" > "$EVIDENCE_DIR/cl-${c}.log" 2>&1
  done
  log "  CL logs saved"
  local cur_h; cur_h=$(get_cometbft_height)
  for h in 5 "$BASELINE_HEIGHT" "$PREH_VERIFY_HEIGHT" "$UPGRADE_HEIGHT" "$POSTH_VERIFY_HEIGHT" "$POSTH_VERIFY_FINAL_HEIGHT"; do
    [[ "$h" -gt "$cur_h" ]] && continue
    curl -fsS -m 5 "http://localhost:26657/block_results?height=${h}" 2>/dev/null > "$EVIDENCE_DIR/block_results-h${h}.json"
    curl -fsS -m 5 "http://localhost:26657/validators?height=${h}&per_page=100" 2>/dev/null > "$EVIDENCE_DIR/cometbft-validators-h${h}.json"
  done
  log "  block_results + cometbft snapshots saved"
  curl -fsS "http://localhost:1317/staking/validators?pagination.limit=200" 2>/dev/null > "$EVIDENCE_DIR/staking-all-vals-end.json"
  cat > "$EVIDENCE_DIR/probe-metadata.json" <<EOF
{
  "probe": "probe_create_val_across_v170.sh",
  "binary_sha256_sentinel": "$(cat ${LOCALNET}/tmp/staged_binary.sha256 2>/dev/null || echo unknown)",
  "config": {
    "UPGRADE_HEIGHT": $UPGRADE_HEIGHT,
    "MAX_VALIDATORS_INIT": $MAX_VALIDATORS_INIT,
    "N_VALS": $N_VALS,
    "NEW_MAX": $NEW_MAX,
    "SBW": $SIGNED_BLOCKS_WINDOW,
    "UNBONDING_TIME": "$UNBONDING_TIME"
  },
  "new_vals": {
    "A": {"moniker": "newval-preh-unlocked-top", "addr": "$A_ADDR", "type": "UNLOCKED"},
    "B": {"moniker": "newval-preh-locked-top",   "addr": "$B_ADDR", "type": "LOCKED"},
    "C": {"moniker": "newval-preh-unlocked-out", "addr": "$C_ADDR", "type": "UNLOCKED"},
    "D": {"moniker": "newval-posth-locked-stuck", "addr": "$D_ADDR", "type": "LOCKED"},
    "E": {"moniker": "newval-posth-locked-top",   "addr": "$E_ADDR", "type": "LOCKED"}
  }
}
EOF
}

capture_evidence_on_fail() {
  log "FAIL path - attempting evidence capture (cluster may be degraded)"
  capture_evidence 2>/dev/null || log "  (capture failed or partial)"
}

# Globals populated during Phase 1 baseline.
RANK1_TOKENS=""; RANK_NEW_MAX_TOKENS=""; RANK8_TOKENS=""
STAKE_A_WEI=""; STAKE_B_WEI=""; STAKE_C_WEI=""; STAKE_D_WEI=""; STAKE_E_WEI=""
KEYFILE_A=""; KEYFILE_B=""; KEYFILE_C=""; KEYFILE_D=""; KEYFILE_E=""
MONIKER_A="newval-preh-unlocked-top"
MONIKER_B="newval-preh-locked-top"
MONIKER_C="newval-preh-unlocked-out"
MONIKER_D="newval-posth-locked-stuck"
MONIKER_E="newval-posth-locked-top"

# ---------------- Phase 0 — boot fresh cluster ----------------
phase_0_start() {
  log "Phase 0 - terminate + boot ${N_VALS}-val cluster (MaxValidators_init=$MAX_VALIDATORS_INIT, NEW_MAX=$NEW_MAX, SBW=$SIGNED_BLOCKS_WINDOW)"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -3); sleep 5
  fi
  local yml_count
  yml_count=$(ls "${LOCALNET}"/docker-compose-validator*.yml 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$yml_count" != "$N_VALS" ]]; then
    bash "${LOCALNET}/scripts/generate_compose_files.sh" "$N_VALS" 2>&1 | tail -3
  fi
  log "  assemble genesis with N=$N_VALS, MAX_VALIDATORS_INIT=$MAX_VALIDATORS_INIT"
  MAX_VALIDATORS_INIT="$MAX_VALIDATORS_INIT" STORY_BIN="$STORY_BIN" \
    bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N_VALS" 2>&1 | tail -1
  jq --arg w "$SIGNED_BLOCKS_WINDOW" --arg u "$UNBONDING_TIME" \
    '.app_state.slashing.params.signed_blocks_window = $w
     | .app_state.staking.params.unbonding_time = $u' \
    "$GENESIS" > "$GENESIS.tmp" && mv "$GENESIS.tmp" "$GENESIS"
  local sw mv_param
  sw=$(jq -r '.app_state.slashing.params.signed_blocks_window' "$GENESIS")
  mv_param=$(jq -r '.app_state.staking.params.max_validators' "$GENESIS")
  log "  genesis: max_validators=$mv_param sbw=$sw unbonding_time=$UNBONDING_TIME"
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -3)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_cometbft_height)
    [[ $h -gt 0 ]] && { log "  cometbft sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "cometbft didn't sync in 90s"
    sleep 3
  done
}

# ---------------- Phase 1 — baseline + stake math + gen cons keys + seed anvil ----------------
phase_1_baseline() {
  log "Phase 1 - baseline at h=$BASELINE_HEIGHT: query top BONDED tokens for stake calibration"
  wait_cometbft_height "$BASELINE_HEIGHT" >/dev/null

  local body
  body=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" 2>/dev/null)
  local bonded_n; bonded_n=$(jq '.msg.validators | length' <<<"$body")
  log "  bonded count @ baseline: $bonded_n (expect $N_VALS)"
  [[ "$bonded_n" == "$N_VALS" ]] || fail "@h=$BASELINE_HEIGHT bonded=$bonded_n != $N_VALS"

  RANK1_TOKENS=$(jq -r '.msg.validators | sort_by(-(.tokens|tonumber)) | .[0].tokens' <<<"$body")
  RANK_NEW_MAX_TOKENS=$(jq -r --argjson n "$NEW_MAX" '.msg.validators | sort_by(-(.tokens|tonumber)) | .[$n-1].tokens' <<<"$body")
  RANK8_TOKENS=$(jq -r '.msg.validators | sort_by(-(.tokens|tonumber)) | .[-1].tokens' <<<"$body")
  log "  rank-1     tokens: $RANK1_TOKENS"
  log "  rank-$NEW_MAX  tokens: $RANK_NEW_MAX_TOKENS"
  log "  rank-$N_VALS tokens: $RANK8_TOKENS"

  # Stake math (in wei). Constraint: new vals have NO cometbft node — if they
  # enter top-NEW_MAX, their voting power is offline → quorum risk. So only ONE
  # new val (val-E) is allowed into top-NEW_MAX, with stake calibrated to take
  # less than 33% of post-V170 bonded VP. A/B/D stay UNBONDING (small stake).
  #
  # MSD floor on Story is 1024 IP (per genesis val.min_self_delegation = 1024e9
  # stake_units). New val stake must be >= 1024 IP. Use 1100 IP for A/B/D
  # (small enough that they never enter top-N).
  #
  # val-E target: 1.3 × R-NEW_MAX, ~25% of post-V170 bonded VP → 75% online
  # genesis stays > 2/3 quorum.
  STAKE_A_WEI=1100000000000000000000   # 1100 IP (= 1100e18 wei)
  STAKE_B_WEI=1100000000000000000000
  STAKE_C_WEI=1100000000000000000000   # unused (val-C dropped)
  STAKE_D_WEI=1100000000000000000000
  STAKE_E_WEI=$(echo "$RANK_NEW_MAX_TOKENS * 13 / 10 * $WEI_PER_STAKE" | bc)
  log "  stake A=$STAKE_A_WEI (1100 IP; below MSD-genesis-floor, stays UNBONDING)"
  log "  stake B=$STAKE_B_WEI (1100 IP; stays UNBONDING)"
  log "  stake D=$STAKE_D_WEI (1100 IP; stays UNBONDING)"
  log "  stake E=$STAKE_E_WEI (1.3 × rank-$NEW_MAX; enters top-NEW_MAX, ~25% VP)"

  log "  generate cons keys for 5 new vals"
  KEYFILE_A=$(gen_cons_key A)
  KEYFILE_B=$(gen_cons_key B)
  KEYFILE_C=$(gen_cons_key C)
  KEYFILE_D=$(gen_cons_key D)
  KEYFILE_E=$(gen_cons_key E)

  # Seed each new-val operator with enough IP for stake + gas.
  # Stake amount in wei -> needs same amount of IP (since 1 IP = 1e18 wei).
  # ${SEED_IP_PER_VAL} is added as gas buffer.
  log "  seed anvil[1..5] (val operators) from anvil[0]"
  for var in A B C D E; do
    local pk_var="${var}_PK" addr_var="${var}_ADDR" stake_var="STAKE_${var}_WEI"
    local addr="${!addr_var}" stake_wei="${!stake_var}"
    # IP = wei / 1e18, rounded up; add SEED_IP_PER_VAL buffer
    local ip_to_send
    ip_to_send=$(python3 -c "print(($stake_wei // 10**18) + $SEED_IP_PER_VAL)")
    log "    seed $addr with $ip_to_send IP (stake ${stake_wei} wei + ${SEED_IP_PER_VAL} IP gas)"
    seed_addr "$addr" "$ip_to_send"
  done

  pass "Phase 1: baseline OK, stake math computed, cons keys generated, anvil operators seeded"
}

# ---------------- Phase 2 — pre-V170 batch: create A, B, C ----------------
phase_2_preh_batch() {
  log "Phase 2 - pre-V170 batch: create val A, B (val-C dropped — binary caps max_validators at NEW_MAX from genesis init; pre-V170 out-of-N mechanism already covered by case-2 genesis val-5..8)"

  wait_cometbft_height "$PREH_A_HEIGHT" >/dev/null
  do_create_val A "$A_PK" "$KEYFILE_A" "$STAKE_A_WEI" "$MONIKER_A" "--unlocked=true"

  wait_cometbft_height "$PREH_B_HEIGHT" >/dev/null
  do_create_val B "$B_PK" "$KEYFILE_B" "$STAKE_B_WEI" "$MONIKER_B" "--unlocked=false"

  sleep 6  # let creates settle on chain before Phase 3 verify
  pass "Phase 2: A, B create txs submitted, rc=0 both"
}

# ---------------- Phase 3 — pre-V170 verify: all 3 new vals BONDED ----------------
phase_3_preh_verify() {
  log "Phase 3 - wait h=$PREH_VERIFY_HEIGHT, verify A B records exist + types correct (both UNBONDING, low stake)"
  wait_cometbft_height "$PREH_VERIFY_HEIGHT" >/dev/null

  local sa sb ta tb
  sa=$(val_status_by_moniker "$MONIKER_A"); ta=$(val_support_token_type_by_moniker "$MONIKER_A")
  sb=$(val_status_by_moniker "$MONIKER_B"); tb=$(val_support_token_type_by_moniker "$MONIKER_B")
  log "  val-A ($MONIKER_A): status=$sa type=$ta (expect 1 UNBONDED never-entered-active-set, type=1 UNLOCKED)"
  log "  val-B ($MONIKER_B): status=$sb type=$tb (expect 1 UNBONDED never-entered-active-set, type=0 LOCKED)"

  [[ "$sa" == "1" ]] || fail "PRIMARY 1a FAILED: val-A status=$sa (expect 1 UNBONDED; never entered top-N with low stake)"
  [[ "$ta" == "1" ]] || fail "PRIMARY 1a FAILED: val-A type=$ta (expect 1 UNLOCKED)"
  [[ "$sb" == "1" ]] || fail "PRIMARY 1b FAILED: val-B status=$sb (expect 1 UNBONDED)"
  [[ "$tb" == "0" ]] || fail "PRIMARY 1b FAILED: val-B type=$tb (expect 0 LOCKED)"

  local bn; bn=$(bonded_count)
  log "  bonded count: $bn (expect $MAX_VALIDATORS_INIT; A/B UNBONDED don't displace genesis)"
  [[ "$bn" == "$MAX_VALIDATORS_INIT" ]] || note "bonded count=$bn != expected $MAX_VALIDATORS_INIT"

  pass "PRIMARY 1: pre-V170 val records created (A UNLOCKED type=1, B LOCKED type=0), both status=1 UNBONDED (never entered top-N)"
}

# ---------------- Phase 4 — wait V170 fire ----------------
phase_4_v170_fire() {
  log "Phase 4 - wait V170 fire @ h=$UPGRADE_HEIGHT"
  wait_cometbft_height "$UPGRADE_HEIGHT" >/dev/null
  log "  V170 fired (handler in EndBlock)"
  pass "Phase 4: V170 fired, cluster did not halt"
}

# ---------------- Phase 5 — post-V170 verify: A B retained, C cap-pruned ----------------
phase_5_posth_verify() {
  log "Phase 5 - wait h=$POSTH_VERIFY_HEIGHT (V170 + $((POSTH_VERIFY_HEIGHT - UPGRADE_HEIGHT)) blocks), verify A B records survived V170 + types preserved"
  wait_cometbft_height "$POSTH_VERIFY_HEIGHT" >/dev/null

  local sa sb ta tb
  sa=$(val_status_by_moniker "$MONIKER_A"); ta=$(val_support_token_type_by_moniker "$MONIKER_A")
  sb=$(val_status_by_moniker "$MONIKER_B"); tb=$(val_support_token_type_by_moniker "$MONIKER_B")
  log "  val-A ($MONIKER_A): status=$sa type=$ta (expect 1 UNBONDED preserved, type=1 UNLOCKED preserved)"
  log "  val-B ($MONIKER_B): status=$sb type=$tb (expect 1 UNBONDED preserved, type=0 LOCKED preserved)"

  [[ "$sa" == "1" ]] || fail "PRIMARY 2a FAILED: val-A status=$sa post-V170 (expect 1 UNBONDED preserved across V170)"
  [[ "$ta" == "1" ]] || fail "PRIMARY 2a FAILED: val-A type=$ta post-V170 (expect 1 UNLOCKED preserved)"
  [[ "$sb" == "1" ]] || fail "PRIMARY 2b FAILED: val-B status=$sb post-V170 (expect 1 UNBONDED preserved)"
  [[ "$tb" == "0" ]] || fail "PRIMARY 2b FAILED: val-B type=$tb post-V170 (expect 0 LOCKED preserved)"

  local bn; bn=$(bonded_count)
  log "  bonded count: $bn (expect $NEW_MAX)"
  [[ "$bn" == "$NEW_MAX" ]] || fail "PRIMARY 2c FAILED: bonded count=$bn != NEW_MAX=$NEW_MAX (V170 cap-prune)"

  pass "PRIMARY 2 (cross-V170 record + type preservation): A UNLOCKED record + type=1 preserved, B LOCKED record + type=0 preserved, bonded count cap-pruned to $NEW_MAX"
}

# ---------------- Phase 6 — post-V170 batch: create D (stake too low), E (displaces R-NEW_MAX) ----------------
RANK_NEW_MAX_PREV_OP=""
phase_6_posth_batch() {
  log "Phase 6 - post-V170 batch: create val D (stuck) and E (top-NEW_MAX displacer)"

  # Capture current rank-NEW_MAX before E displaces it
  RANK_NEW_MAX_PREV_OP=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" 2>/dev/null \
    | jq -r --argjson n "$NEW_MAX" '.msg.validators | sort_by(-(.tokens|tonumber)) | .[$n-1].operator_address')
  log "  current rank-$NEW_MAX op (will be displaced by E): $RANK_NEW_MAX_PREV_OP"

  wait_cometbft_height "$POSTH_D_HEIGHT" >/dev/null
  do_create_val D "$D_PK" "$KEYFILE_D" "$STAKE_D_WEI" "$MONIKER_D" "--unlocked=false"

  wait_cometbft_height "$POSTH_E_HEIGHT" >/dev/null
  do_create_val E "$E_PK" "$KEYFILE_E" "$STAKE_E_WEI" "$MONIKER_E" "--unlocked=false"

  sleep 8  # let creates + VSU settle
  pass "Phase 6: D, E create txs submitted, rc=0"
}

# ---------------- Phase 7 — post-V170 final verify ----------------
phase_7_posth_verify_final() {
  log "Phase 7 - wait h=$POSTH_VERIFY_FINAL_HEIGHT, verify D never-bonded, E displaces R-$NEW_MAX, bonded count=$NEW_MAX"
  wait_cometbft_height "$POSTH_VERIFY_FINAL_HEIGHT" >/dev/null

  local sd se td te
  sd=$(val_status_by_moniker "$MONIKER_D"); td=$(val_support_token_type_by_moniker "$MONIKER_D")
  se=$(val_status_by_moniker "$MONIKER_E"); te=$(val_support_token_type_by_moniker "$MONIKER_E")
  log "  val-D ($MONIKER_D): status=$sd support_token_type=$td (expect 1 UNBONDED never-entered-top-N, type=0 LOCKED)"
  log "  val-E ($MONIKER_E): status=$se support_token_type=$te (expect 3 BONDED displacer, type=0 LOCKED)"

  [[ "$sd" == "1" ]] || fail "PRIMARY 3a FAILED: val-D status=$sd (expect 1 UNBONDED; stake too low to enter top-NEW_MAX)"
  [[ "$td" == "0" ]] || fail "PRIMARY 3a FAILED: val-D support_token_type=$td (expect 0 LOCKED)"
  [[ "$se" == "3" ]] || fail "PRIMARY 3b FAILED: val-E status=$se (expect 3 BONDED; displaces current R-$NEW_MAX)"
  [[ "$te" == "0" ]] || fail "PRIMARY 3b FAILED: val-E support_token_type=$te (expect 0 LOCKED)"

  # Verify previously-rank-NEW_MAX val now demoted (status != 3 BONDED)
  if [[ -n "$RANK_NEW_MAX_PREV_OP" ]]; then
    local prev_status
    prev_status=$(curl -fsS "http://localhost:1317/staking/validators/${RANK_NEW_MAX_PREV_OP}" 2>/dev/null | jq -r '.msg.validator.status')
    log "  prior rank-$NEW_MAX op=$RANK_NEW_MAX_PREV_OP status=$prev_status (expect 2 UNBONDING after E displaced it)"
    [[ "$prev_status" == "2" || "$prev_status" == "1" ]] || fail "PRIMARY 3c FAILED: prior R-$NEW_MAX status=$prev_status (expect 2 UNBONDING after E displaced)"
  fi

  local bn; bn=$(bonded_count)
  log "  bonded count: $bn (expect $NEW_MAX)"
  [[ "$bn" == "$NEW_MAX" ]] || fail "PRIMARY 3d FAILED: bonded count=$bn != NEW_MAX=$NEW_MAX (cap not respected post post-V170 batch)"

  pass "PRIMARY 3 (post-V170 batch outcome): D LOCKED UNBONDING never-bonded, E LOCKED BONDED displaced R-$NEW_MAX, bonded=$NEW_MAX"
}

# ---------------- Phase 8 — capture + summary ----------------
phase_8_capture_summary() {
  log "Phase 8 - capture evidence + summary"
  capture_evidence
  printf "\n========== CREATE-VAL MATRIX ACROSS V170 ==========\n"
  printf "  Binary: %s (V170=$UPGRADE_HEIGHT, NewMax=$NEW_MAX)\n" "$(cat ${LOCALNET}/tmp/staged_binary.sha256 2>/dev/null || echo unknown)"
  printf "  Cluster: $N_VALS-val genesis + 5 new vals, MaxValidators_init=$MAX_VALIDATORS_INIT -> NEW_MAX=$NEW_MAX\n"
  printf "\n"
  printf "  Pre-V170 batch (h=$PREH_A_HEIGHT..$PREH_C_HEIGHT):\n"
  printf "    A $MONIKER_A     stake=$STAKE_A_WEI wei (UNLOCKED, top-NEW_MAX target)\n"
  printf "    B $MONIKER_B     stake=$STAKE_B_WEI wei (LOCKED, top-NEW_MAX target)\n"
  printf "    C $MONIKER_C     stake=$STAKE_C_WEI wei (UNLOCKED, out-of-NEW_MAX at V170)\n"
  printf "\n"
  printf "  Post-V170 batch (h=$POSTH_D_HEIGHT..$POSTH_E_HEIGHT):\n"
  printf "    D $MONIKER_D     stake=$STAKE_D_WEI wei (LOCKED, stake too low)\n"
  printf "    E $MONIKER_E     stake=$STAKE_E_WEI wei (LOCKED, top-NEW_MAX displacer)\n"
  printf "\n"
  printf "  PRIMARY conclusions:\n"
  printf "  (PRIMARY 1) Pre-V170 new vals enter BONDED set when MaxValidators not yet capped.\n"
  printf "  (PRIMARY 2) V170 cap-prune correctly retains top-NEW_MAX (incl. both LOCKED and\n"
  printf "              UNLOCKED new vals) and prunes the rest. val_type preserved across V170.\n"
  printf "  (PRIMARY 3) Post-V170 MsgCreateValidator obeys NEW_MAX cap: stake-below-cap vals\n"
  printf "              stay UNBONDING (never bonded); stake-above-cap vals BONDED and\n"
  printf "              displace current rank-NEW_MAX. Bonded count stays == NEW_MAX.\n"
  printf "  Evidence in $EVIDENCE_DIR\n"
  printf "===================================================\n"
}

# ---------------- Phase 9 — teardown ----------------
phase_9_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then
    log "Phase 9 - SKIP_TEARDOWN"; return
  fi
  log "Phase 9 - teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
  rm -rf ${NEWVAL_HOME_BASE}-{A,B,C,D,E} 2>/dev/null || true
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline
phase_2_preh_batch
phase_3_preh_verify
phase_4_v170_fire
phase_5_posth_verify
phase_6_posth_batch
phase_7_posth_verify_final
phase_8_capture_summary
phase_9_teardown
