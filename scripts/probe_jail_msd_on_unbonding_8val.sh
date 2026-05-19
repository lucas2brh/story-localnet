#!/usr/bin/env bash
# probe_jail_msd_on_unbonding_8val.sh
#
# Single Case A: MSD-jail fire condition on val.Status=2 UNBONDING.
# Complements probe_jail_msd_recovery_8val.sh (which covered status=1 born-UNBONDED).
#
# Mechanism under test:
#   - cosmos-sdk x/staking/keeper/delegation.go:1120-1124 MSD-jail branch:
#       if isValidatorOperator && !validator.Jailed &&
#          validator.TokensFromShares(delegation.Shares).TruncateInt().LT(validator.MinSelfDelegation):
#               k.jailValidator(ctx, validator)
#   - Source has NO val.IsBonded()/IsActive() check
#   - jail-msd-recovery proved this for status=1 UNBONDED (born-UNBONDED)
#   - This probe proves it for status=2 UNBONDING (cap-prune transition window)
#
# Setup:
#   - 8-val cluster, MAX_VALIDATORS_INIT=8 (ALL 8 BONDED at genesis) — required to
#     get a val into the BONDED→UNBONDING transition via V170 cap-prune
#   - V170 NEW_MAX=4 (binary-forced) at h=70 → val-5/6/7/8 (bottom-4) cap-pruned
#   - unbonding_time=300s = ~120 blocks @ 2.5s/block — wide window for probe
#     to act on val-5 while still status=2 UNBONDING (mature at ~h=190)
#   - period[1]/[2]/[3] runtime-patched 60s/120s/180s (consistency with other 8val probes)
#
# Phases:
#   0  terminate prior + boot 8-val MAX_VAL_INIT=8 + period + unbonding_time patches
#   1  wait h=10; assert val-5 status=3 BONDED jailed=false (REST snapshot);
#      Anvil ext-del 2048 IP flex → val-5 (keeps val.DelegatorShares > 0
#      after op self-unstake to prevent inline RemoveValidator)
#   2  wait h=72 (V170 fired at h=70, 2 block margin); assert val-5
#      status=2 UNBONDING jailed=false (REST snapshot, the KEY pre-tx state)
#   3  op of val-5 100% self-unstake via MsgUndelegate within UNBONDING window
#      (h~75-80, unbonding mature ~h=190 — 115+ blocks of safety margin)
#   4  post-tx: assert val-5 status=2 UNBONDING jailed=true
#      (chain-asserted: MSD-jail fired while val was in UNBONDING state)
#   5  chain-side transition verification:
#        - grep `📚 Validator bonded val_addr=<val5_upper>` → expect ≥1 hits
#          (val-5 WAS BONDED at genesis init)
#        - grep `📚 Validator begin unbonding val_addr=<val5_upper>` → expect ≥1 hits
#          (cap-prune BONDED→UNBONDING transition at V170 fire block)
#        - CometBFT /validators?height samples: h=10 includes val-5 cons,
#          h=72/post_unstake/final exclude val-5 cons
#   6  summary
#   7  optional teardown
#
# Usage:
#   ./scripts/probe_jail_msd_on_unbonding_8val.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_jail_msd_on_unbonding_8val.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-70}
PRE_STAKE_BLOCK=${PRE_STAKE_BLOCK:-10}
POST_V170_BLOCK=${POST_V170_BLOCK:-72}    # just past V170, val should be status=2 UNBONDING
UNSTAKE_TARGET_BLOCK=${UNSTAKE_TARGET_BLOCK:-78}
N_VALS=${N_VALS:-8}
MAX_VALIDATORS_INIT=${MAX_VALIDATORS_INIT:-8}   # all 8 BONDED at genesis (V170 transitions bottom-4 → UNBONDING)
UNBONDING_TIME=${UNBONDING_TIME:-300s}   # = 120 blocks @ 2.5s/block (wide unbonding window)
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
EV_DIR="${LOCALNET}/tmp/probe-jail-msd-on-unbonding-evidence"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ANVIL_ADDR=${ANVIL_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
ANVIL_STAKE_WEI="2048000000000000000000"   # 2048 IP

TARGET_MONIKER="localnet-val-5"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[jail-unbonding]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[jail-unbonding]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[jail-unbonding]${C_RESET} FAIL %s\n" "$*"; exit 1; }
note() { printf "${C_YELLOW}[jail-unbonding]${C_RESET} NOTE %s\n" "$*"; }
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
val_field() {
  local body
  body=$(curl -fsS "http://localhost:1317/staking/validators/${1}" 2>/dev/null)
  [[ -z $body ]] && { echo "GONE"; return; }
  jq -r ".msg.validator.${2} // \"GONE\"" <<<"$body"
}
val_snapshot() {
  local op=$1 label=$2
  curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null | jq '.' > "$EV_DIR/val-${label}.json"
}
meta_pubkey_hex() { local b64; b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META"); echo -n "$b64" | base64 -d | xxd -p -c 66; }
meta_op_evm()     { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }
meta_privkey()    { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }
meta_cons_hex() {
  local b64
  b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META")
  echo -n "$b64" | base64 -d | shasum -a 256 | cut -c1-40 | tr 'a-z' 'A-Z'
}

# ---------------- Phase 0 — boot ----------------
phase_0_start() {
  log "Phase 0 — terminate prior + 8-val genesis MAX_VALIDATORS_INIT=$MAX_VALIDATORS_INIT + unbonding_time=$UNBONDING_TIME + periods=[60s,120s,180s]"
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
  local ubt mv_set
  ubt=$(jq -r '.app_state.staking.params.unbonding_time' "$genesis_path")
  mv_set=$(jq -r '.app_state.staking.params.max_validators' "$genesis_path")
  [[ "$ubt" == "$UNBONDING_TIME" ]] || fail "unbonding_time=$ubt (expected $UNBONDING_TIME)"
  [[ "$mv_set" == "$MAX_VALIDATORS_INIT" ]] || fail "max_validators=$mv_set (expected $MAX_VALIDATORS_INIT)"
  log "  genesis: max_validators=$MAX_VALIDATORS_INIT unbonding_time=$UNBONDING_TIME"

  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -1)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "rpc1 didn't sync in 90s"
    sleep 3
  done

  mkdir -p "$EV_DIR"
  log "  evidence dir: $EV_DIR"
}

# ---------------- Phase 1 — pre-V170 baseline + Anvil ext-del ----------------
TARGET_OP=""; TARGET_CONS=""; TARGET_BASELINE_TOKENS=""
phase_1_baseline_and_seed() {
  log "Phase 1 — wait h=$PRE_STAKE_BLOCK + baseline assert + Anvil ext-del → $TARGET_MONIKER"
  wait_height "$PRE_STAKE_BLOCK" >/dev/null

  TARGET_OP=$(meta_op_evm "$TARGET_MONIKER")
  TARGET_CONS=$(meta_cons_hex "$TARGET_MONIKER")
  val_snapshot "$TARGET_OP" "${TARGET_MONIKER}-01-baseline-BONDED"
  local status jailed tokens msd
  status=$(val_field "$TARGET_OP" status)
  jailed=$(val_field "$TARGET_OP" jailed)
  tokens=$(val_field "$TARGET_OP" tokens)
  msd=$(val_field "$TARGET_OP" min_self_delegation)
  TARGET_BASELINE_TOKENS=$tokens
  log "  $TARGET_MONIKER baseline: op=$TARGET_OP cons=$TARGET_CONS status=$status jailed=$jailed tokens=$tokens MSD=$msd"
  [[ "$status" == "3" ]] || fail "$TARGET_MONIKER baseline expected status=3 BONDED, got $status"
  [[ "$jailed" == "GONE" || "$jailed" == "false" ]] || fail "$TARGET_MONIKER baseline expected jailed=false, got $jailed"

  # Snapshot CometBFT validators at this height — val-5 cons SHOULD appear (BONDED)
  local h_now; h_now=$(get_height)
  curl -fsS "http://localhost:26657/validators?height=$h_now&per_page=100" 2>/dev/null | jq '.' > "$EV_DIR/cometbft-validators-h${h_now}-BASELINE.json"
  local in_set
  in_set=$(jq -r --arg c "$TARGET_CONS" '[.result.validators[]?.address] | map(ascii_upcase) | contains([$c])' "$EV_DIR/cometbft-validators-h${h_now}-BASELINE.json")
  [[ "$in_set" == "true" ]] || fail "$TARGET_MONIKER cons=$TARGET_CONS NOT in CometBFT active set at h=$h_now baseline (expected true since BONDED)"
  log "  CometBFT @h=$h_now: $TARGET_MONIKER cons IN active set (chain-asserted BONDED) ✓"

  # Anvil ext-del 2048 IP flex
  local pub; pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  local out rc
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
    --validator-pubkey "$pub" --stake "$ANVIL_STAKE_WEI" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || fail "Anvil stake → $TARGET_MONIKER rc=$rc"
  log "  Anvil 2048 IP flex stake → $TARGET_MONIKER rc=$rc"
  sleep 8
  pass "baseline confirmed (status=3 BONDED + CometBFT active set + Anvil ext-del injected)"
}

# ---------------- Phase 2 — wait past V170, assert UNBONDING ----------------
phase_2_assert_unbonding() {
  log "Phase 2 — wait past V170=$UPGRADE_HEIGHT to h=$POST_V170_BLOCK, assert $TARGET_MONIKER status=2 UNBONDING"
  wait_height "$POST_V170_BLOCK" >/dev/null
  val_snapshot "$TARGET_OP" "${TARGET_MONIKER}-02-post-V170-UNBONDING"
  local status jailed tokens
  status=$(val_field "$TARGET_OP" status)
  jailed=$(val_field "$TARGET_OP" jailed)
  tokens=$(val_field "$TARGET_OP" tokens)
  log "  $TARGET_MONIKER post-V170 @h=$(get_height): status=$status jailed=$jailed tokens=$tokens"
  # KEY chain-asserted assertion: val MUST be status=2 UNBONDING (NOT yet status=1)
  # with unbonding_time=300s and tx in unstaking_window, ~118 blocks (295s) until mature
  [[ "$status" == "2" ]] || fail "$TARGET_MONIKER expected status=2 UNBONDING post-V170 (before mature), got $status"
  [[ "$jailed" == "GONE" || "$jailed" == "false" ]] || fail "$TARGET_MONIKER expected jailed=false at this point (cap-prune doesn't jail), got $jailed"

  # CometBFT snapshot — val-5 cons should NOT be in active set anymore (cap-pruned out)
  local h_now; h_now=$(get_height)
  curl -fsS "http://localhost:26657/validators?height=$h_now&per_page=100" 2>/dev/null | jq '.' > "$EV_DIR/cometbft-validators-h${h_now}-POST-V170.json"
  local in_set
  in_set=$(jq -r --arg c "$TARGET_CONS" '[.result.validators[]?.address] | map(ascii_upcase) | contains([$c])' "$EV_DIR/cometbft-validators-h${h_now}-POST-V170.json")
  [[ "$in_set" == "false" ]] || fail "$TARGET_MONIKER cons=$TARGET_CONS still in CometBFT active set at h=$h_now post-V170 (expected false since cap-pruned)"
  log "  CometBFT @h=$h_now: $TARGET_MONIKER cons NOT in active set (chain-asserted cap-pruned out) ✓"

  pass "$TARGET_MONIKER chain-asserted status=2 UNBONDING + jailed=false + out of CometBFT active set (BONDED→UNBONDING transition complete)"
}

# ---------------- Phase 3 — op self-unstake within UNBONDING window ----------------
phase_3_op_unstake() {
  log "Phase 3 — wait h=$UNSTAKE_TARGET_BLOCK + op of $TARGET_MONIKER 100% self-unstake via MsgUndelegate (within UNBONDING window)"
  wait_height "$UNSTAKE_TARGET_BLOCK" >/dev/null

  # Pre-tx snapshot — capture exact pre-state for evidence
  val_snapshot "$TARGET_OP" "${TARGET_MONIKER}-03a-pre-op-unstake-UNBONDING"
  local pre_status pre_jailed
  pre_status=$(val_field "$TARGET_OP" status); pre_jailed=$(val_field "$TARGET_OP" jailed)
  log "  pre-unstake (h=$(get_height)): status=$pre_status jailed=$pre_jailed (expect status=2 jailed=false)"
  [[ "$pre_status" == "2" ]] || fail "pre-unstake status=$pre_status (expected 2 UNBONDING — outside window, increase UNBONDING_TIME)"

  local pub op_pk op_addr
  pub=$(meta_pubkey_hex "$TARGET_MONIKER")
  op_pk=$(meta_privkey "$TARGET_MONIKER")
  op_addr=$(meta_op_evm "$TARGET_MONIKER")

  cast send --rpc-url http://localhost:8545 --private-key "$ANVIL_PK" "$op_addr" \
    --value 10ether --legacy --gas-price 50gwei >/dev/null 2>&1
  sleep 5

  # 100% of baseline self-del (in stake-units, × 1e9 → wei)
  local amount_wei; amount_wei=$(echo "$TARGET_BASELINE_TOKENS * 1000000000" | bc)
  log "  unstake amount = 100% of baseline ($TARGET_BASELINE_TOKENS) = $amount_wei wei → drives op self-del to 0 < MSD 1024 IP"

  local h_before; h_before=$(get_height)
  local out rc
  out=$(PRIVATE_KEY="$op_pk" "$STORY_BIN" validator unstake \
    --validator-pubkey "$pub" --unstake "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  [[ $rc -eq 0 ]] || fail "op self-unstake rc=$rc"
  log "  op self-unstake submitted at h_before=$h_before"
  wait_height "$((h_before + 5))" >/dev/null
  pass "op self-unstake landed (still within UNBONDING window: h~$((h_before + 5)) << mature h~$((UPGRADE_HEIGHT + 120)))"
}

# ---------------- Phase 4 — assert MSD-jail fired on status=2 UNBONDING val ----------------
phase_4_assert_jailed_unbonding() {
  log "Phase 4 — assert $TARGET_MONIKER post-tx status=2 UNBONDING + jailed=true (KEY chain assertion)"
  val_snapshot "$TARGET_OP" "${TARGET_MONIKER}-04-post-op-unstake-UNBONDING-jailed"
  local status jailed tokens delegator_shares
  status=$(val_field "$TARGET_OP" status)
  jailed=$(val_field "$TARGET_OP" jailed)
  tokens=$(val_field "$TARGET_OP" tokens)
  delegator_shares=$(val_field "$TARGET_OP" delegator_shares)
  log "  $TARGET_MONIKER post-unstake @h=$(get_height): status=$status jailed=$jailed tokens=$tokens delegator_shares=$delegator_shares"

  # The critical assertion: val MUST still be status=2 UNBONDING (op self-unstake doesn't change Status)
  # AND jailed MUST have flipped to true (MSD-jail fired during the Unbond call)
  if [[ "$status" != "2" ]]; then
    FAILS=$((FAILS+1))
    printf "${C_RED}[jail-unbonding]${C_RESET} FAIL status=$status (expected 2 UNBONDING — if 1, ran past unbonding mature; if 3, never cap-pruned)\n"
  fi
  if [[ "$jailed" != "true" ]]; then
    FAILS=$((FAILS+1))
    printf "${C_RED}[jail-unbonding]${C_RESET} FAIL jailed=$jailed (expected true — MSD-jail should fire on status=2 UNBONDING per source delegation.go:1120 no IsBonded check)\n"
  fi
  if [[ "$status" == "2" && "$jailed" == "true" ]]; then
    pass "MSD-jail fired on val.Status=2 UNBONDING (jailed flipped false→true while status stayed 2)"
  fi
}

# ---------------- Phase 5 — chain-side transition verification ----------------
phase_5_transition_verification() {
  log "Phase 5 — chain-side transition verification via CL emit grep + CometBFT validators snapshots"

  local final_h; final_h=$(get_height)
  # Capture additional CometBFT snapshots
  for h in 1 "$PRE_STAKE_BLOCK" "$UPGRADE_HEIGHT" "$POST_V170_BLOCK" "$final_h"; do
    curl -fsS "http://localhost:26657/validators?height=$h&per_page=100" 2>/dev/null | jq '.' > "$EV_DIR/cometbft-validators-h${h}.json"
  done

  local op_upper; op_upper=$(echo "$TARGET_OP" | sed 's/0x//' | tr 'a-z' 'A-Z')

  # Save grep results to evidence files
  docker logs bootnode1-node 2>&1 | grep -E "Validator bonded.*val_addr=$op_upper" > "$EV_DIR/bonded-events-${TARGET_MONIKER}.txt" || true
  docker logs bootnode1-node 2>&1 | grep -E "Validator begin unbonding.*val_addr=$op_upper" > "$EV_DIR/begin-unbonding-events-${TARGET_MONIKER}.txt" || true
  docker logs bootnode1-node 2>&1 | grep -E "Applied deferred MaxValidators reduction" > "$EV_DIR/v170-fire-event.txt" || true

  local bonded_hits unbonding_hits v170_hits
  bonded_hits=$(wc -l < "$EV_DIR/bonded-events-${TARGET_MONIKER}.txt")
  unbonding_hits=$(wc -l < "$EV_DIR/begin-unbonding-events-${TARGET_MONIKER}.txt")
  v170_hits=$(wc -l < "$EV_DIR/v170-fire-event.txt")

  log "  CL log events for $TARGET_MONIKER (val_addr=$op_upper):"
  log "    📚 Validator bonded emits: $bonded_hits (expected >=1 from genesis init)"
  log "    📚 Validator begin unbonding emits: $unbonding_hits (expected >=1 from V170 cap-prune at h=$UPGRADE_HEIGHT)"
  log "    V170 fire emits: $v170_hits"

  [[ "$bonded_hits" -ge 1 ]] || { FAILS=$((FAILS+1)); printf "${C_RED}[jail-unbonding]${C_RESET} FAIL bonded_hits=$bonded_hits (expected >=1, val was BONDED at genesis)\n"; }
  [[ "$unbonding_hits" -ge 1 ]] || { FAILS=$((FAILS+1)); printf "${C_RED}[jail-unbonding]${C_RESET} FAIL unbonding_hits=$unbonding_hits (expected >=1, V170 cap-prune)\n"; }

  # Verify val-5 cons in CometBFT set at baseline h=10 but NOT at h>=70
  local in_at_baseline in_at_post_v170
  in_at_baseline=$(jq -r --arg c "$TARGET_CONS" '[.result.validators[]?.address] | map(ascii_upcase) | contains([$c])' "$EV_DIR/cometbft-validators-h${PRE_STAKE_BLOCK}.json")
  in_at_post_v170=$(jq -r --arg c "$TARGET_CONS" '[.result.validators[]?.address] | map(ascii_upcase) | contains([$c])' "$EV_DIR/cometbft-validators-h${POST_V170_BLOCK}.json")
  log "  CometBFT validator set membership of $TARGET_MONIKER cons=$TARGET_CONS:"
  log "    h=$PRE_STAKE_BLOCK (pre-V170 BONDED): in_set=$in_at_baseline (expected true)"
  log "    h=$POST_V170_BLOCK (post-V170 UNBONDING): in_set=$in_at_post_v170 (expected false)"
  [[ "$in_at_baseline" == "true" ]] || { FAILS=$((FAILS+1)); printf "${C_RED}[jail-unbonding]${C_RESET} FAIL val-5 missing from CometBFT active set at h=$PRE_STAKE_BLOCK\n"; }
  [[ "$in_at_post_v170" == "false" ]] || { FAILS=$((FAILS+1)); printf "${C_RED}[jail-unbonding]${C_RESET} FAIL val-5 still in CometBFT active set at h=$POST_V170_BLOCK (cap-prune didn't propagate)\n"; }

  [[ $FAILS -eq 0 ]] && pass "chain-side BONDED→UNBONDING transition verified (CL emits + CometBFT snapshots all consistent)"
}

# ---------------- Phase 6 — summary ----------------
phase_6_summary() {
  printf "\n========== MSD-JAIL ON UNBONDING (status=2) PROBE SUMMARY ==========\n"
  local final_snap="$EV_DIR/val-${TARGET_MONIKER}-04-post-op-unstake-UNBONDING-jailed.json"
  local status jailed tokens
  status=$(jq -r '.msg.validator.status' "$final_snap" 2>/dev/null)
  jailed=$(jq -r '.msg.validator.jailed' "$final_snap" 2>/dev/null)
  tokens=$(jq -r '.msg.validator.tokens' "$final_snap" 2>/dev/null)
  printf "  Target: %s (cons=%s)\n" "$TARGET_MONIKER" "$TARGET_CONS"
  printf "  Setup: MAX_VAL_INIT=$MAX_VALIDATORS_INIT, V170=$UPGRADE_HEIGHT, unbonding_time=$UNBONDING_TIME (~120 blocks)\n"
  printf "  Phase 1 (h=$PRE_STAKE_BLOCK): val-5 status=3 BONDED + in CometBFT active set\n"
  printf "  Phase 2 (h=$POST_V170_BLOCK): val-5 status=2 UNBONDING + out of CometBFT active set\n"
  printf "  Phase 3 (h~$UNSTAKE_TARGET_BLOCK): op 100%% self-unstake (MsgUndelegate)\n"
  printf "  Phase 4 post-tx: status=%s jailed=%s tokens=%s\n" "$status" "$jailed" "$tokens"
  printf "  Final chain height: %s\n" "$(get_height)"
  printf "  Total FAILs: %s\n" "$FAILS"
  printf "  Evidence dir: $EV_DIR\n"
  if [[ "$status" == "2" && "$jailed" == "true" && $FAILS -eq 0 ]]; then
    printf "  CONCLUSION: MSD-jail FIRES on val.Status=2 UNBONDING — NO active precondition, no Status precondition.\n"
  else
    printf "  CONCLUSION: assertions failed — see above for details.\n"
  fi
  printf "====================================================================\n"
}

phase_7_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 7 — SKIP_TEARDOWN"; return; fi
  log "Phase 7 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -1)
}

# ---------------- main ----------------
phase_0_start
phase_1_baseline_and_seed
phase_2_assert_unbonding
phase_3_op_unstake
phase_4_assert_jailed_unbonding
phase_5_transition_verification
phase_6_summary
phase_7_teardown

[[ $FAILS -eq 0 ]] || exit 1
