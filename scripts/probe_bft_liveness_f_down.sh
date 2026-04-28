#!/usr/bin/env bash
# probe_bft_liveness_f_down.sh — verify BFT fault-tolerance boundary at the
# v1.7.0 16-validator cap by pausing validator consensus containers until
# cumulative paused voting power crosses 1/3 of total bonded power.
#
# Mainnet realism: at the 16-val cap each remaining val carries 5x more
# voting power than under the 80-val cap. Operators want empirical evidence
# that the chain still tolerates up to f = floor((N-1)/3) faulty vals (with
# N=16 → f=5 by count; the strict criterion is voting-power-based) and
# that the chain halts cleanly past that threshold rather than producing
# bad state.
#
# Setup:
#   Fresh 20-val localnet, default slashing params (signed_blocks_window=200,
#   downtime_jail_duration=60s) so paused vals do NOT get jailed during the
#   test (jailing would trigger cap-fill from rank-17 and contaminate the
#   bonded set we're stress-testing). Past V170 the bonded set is top-16 by
#   tokens.
#
# Procedure:
#   Phase A — pause smallest BONDED vals one by one, accumulating paused
#     voting power, while paused_VP / total_VP stays strictly below 1/3.
#     After each pause, verify the chain still progresses (height advances
#     by at least 5 blocks within ~30s).
#   Phase B — pause the next val so paused_VP crosses 1/3. Verify the chain
#     halts (height advances by no more than 3 blocks in 60s, accounting
#     for in-flight commits).
#   Phase C — docker unpause all. Verify the chain resumes (advances 10+
#     blocks within 60s).
#
# Assertions:
#   - Phase A: while paused_VP < V_total / 3, chain must progress
#   - Phase B: when paused_VP >= V_total / 3, chain must halt
#   - Phase C: after unpause, chain must resume
#
# Usage:
#   ./scripts/probe_bft_liveness_f_down.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_bft_liveness_f_down.sh

set -u

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
POST_UPGRADE_BLOCK=${POST_UPGRADE_BLOCK:-65}
STORY_BIN=${STORY_BIN:-/tmp/story}
NEW_MAX=${NEW_MAX:-16}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

LIVE_BLOCKS=${LIVE_BLOCKS:-5}        # Phase A: blocks chain must advance after each pause
HALT_OBSERVE_SEC=${HALT_OBSERVE_SEC:-60}  # Phase B: seconds to observe halt
HALT_MAX_BLOCKS=${HALT_MAX_BLOCKS:-3}     # Phase B: at most this many blocks may finalize after halt boundary
RESUME_BLOCKS=${RESUME_BLOCKS:-10}        # Phase C: blocks chain must advance after unpause

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[bft]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[bft]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[bft]${C_RESET} FAIL %s\n" "$*"; exit 1; }
note() { printf "${C_YELLOW}[bft]${C_RESET} OBSERVED %s\n" "$*"; }

get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}
wait_height() { local target=$1 h; while :; do h=$(get_height); [[ $h -ge $target ]] && { echo "$h"; return; }; sleep 2; done; }
wait_height_with_timeout() {
  local target=$1 deadline=$(( $(date +%s) + ${2:-30} )) h
  while :; do
    h=$(get_height); [[ $h -ge $target ]] && { echo "$h"; return 0; }
    [[ $(date +%s) -ge $deadline ]] && { echo "$h"; return 1; }
    sleep 2
  done
}
bonded_set_json() {
  curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" 2>/dev/null
}
moniker_for_op() {
  local op=$1
  jq -r --arg op "$op" '.[] | select((.evm_address | ascii_downcase) == ($op | ascii_downcase)) | .moniker' "$META"
}
container_for_moniker() {
  local m=$1
  local n; n=$(echo "$m" | sed -E 's/^localnet-val-//')
  echo "validator${n}-node"
}

# State
declare -a PAUSED_CONTAINERS=()
declare -a PAUSED_MONIKERS=()
PAUSED_TOKENS=0
TOTAL_TOKENS=0
THRESHOLD=0   # floor(TOTAL_TOKENS / 3)

unpause_all() {
  local c
  for c in "${PAUSED_CONTAINERS[@]:-}"; do
    [[ -z "$c" ]] && continue
    docker unpause "$c" >/dev/null 2>&1 || true
  done
}
trap 'unpause_all' EXIT

# ---------------- Phase 0 — fresh localnet ----------------
phase_0_start() {
  log "Phase 0 — start fresh 20-val localnet (default slashing params)"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2); sleep 5
  fi
  MAX_VALIDATORS_INIT=20 STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" 20 2>&1 | tail -1

  local genesis="${LOCALNET}/config/story/genesis-node.json"
  local sbw djd
  sbw=$(jq -r '.app_state.slashing.params.signed_blocks_window' "$genesis")
  djd=$(jq -r '.app_state.slashing.params.downtime_jail_duration' "$genesis")
  log "  default slashing: signed_blocks_window=$sbw downtime_jail_duration=$djd"
  [[ "$sbw" == "200" ]] || log "  WARN: expected default signed_blocks_window=200, got $sbw"

  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)
  local deadline=$(( $(date +%s) + 90 )) h=0
  while :; do
    h=$(get_height); [[ $h -gt 0 ]] && { log "  rpc1 sync ok h=$h"; break; }
    [[ $(date +%s) -ge $deadline ]] && fail "rpc1 didn't sync in 90s"
    sleep 3
  done
}

# ---------------- Phase 1 — capture post-V170 bonded set sorted ascending by tokens ----------------
declare -a SORTED_OPS=()    # ascending by tokens (smallest first)
declare -a SORTED_TOKENS=()
declare -a SORTED_MONIKERS=()
phase_1_capture_baseline() {
  log "Phase 1 — wait past V170=$UPGRADE_HEIGHT to block $POST_UPGRADE_BLOCK and capture bonded set"
  wait_height "$POST_UPGRADE_BLOCK" >/dev/null
  log "  chain at $(get_height)"
  local vals; vals=$(bonded_set_json)
  local cnt; cnt=$(jq '.msg.validators | length' <<<"$vals")
  log "  bonded count: $cnt (expected $NEW_MAX)"
  [[ "$cnt" == "$NEW_MAX" ]] || fail "bonded count $cnt != $NEW_MAX (post-upgrade prune broken?)"

  # Extract sorted ascending by tokens
  local sorted; sorted=$(jq -c '.msg.validators | sort_by(.tokens|tonumber) | .[] | {op:.operator_address, tokens:.tokens}' <<<"$vals")
  TOTAL_TOKENS=$(jq -r '.msg.validators | map(.tokens|tonumber) | add' <<<"$vals")
  THRESHOLD=$(( TOTAL_TOKENS / 3 ))
  log "  V_total=$TOTAL_TOKENS  threshold(1/3)=$THRESHOLD"

  local i=0 op tokens mon
  while IFS= read -r row; do
    op=$(jq -r .op <<<"$row")
    tokens=$(jq -r .tokens <<<"$row")
    mon=$(moniker_for_op "$op")
    [[ -z "$mon" ]] && fail "could not resolve moniker for op=$op"
    SORTED_OPS+=("$op"); SORTED_TOKENS+=("$tokens"); SORTED_MONIKERS+=("$mon")
    local pct=$(awk -v t="$tokens" -v T="$TOTAL_TOKENS" 'BEGIN{printf "%.2f", (t/T)*100}')
    log "  rank-$((NEW_MAX-i)): $mon tokens=$tokens (${pct}% of V_total)"
    i=$((i+1))
  done <<<"$sorted"
  pass "baseline captured (16 BONDED, sorted ascending)"
}

# ---------------- Phase 2 — pause smallest vals while paused_VP < V_total/3 ----------------
PHASE_A_PAUSED_COUNT=0
PHASE_A_PAUSED_VP=0
phase_2_pause_within_tolerance() {
  log "Phase 2 — Phase A: pause smallest vals while paused_VP < threshold($THRESHOLD)"
  local i=0
  for ((i=0; i<NEW_MAX; i++)); do
    local op="${SORTED_OPS[$i]}"
    local tokens="${SORTED_TOKENS[$i]}"
    local mon="${SORTED_MONIKERS[$i]}"
    local next_paused=$((PAUSED_TOKENS + tokens))

    # Stop just BEFORE crossing the threshold — last val that fits in Phase A
    if [[ $next_paused -ge $THRESHOLD ]]; then
      log "  next val ($mon, tokens=$tokens) would push paused_VP=$next_paused >= threshold=$THRESHOLD — stop Phase A"
      break
    fi

    local container; container=$(container_for_moniker "$mon")
    log "  pause $mon (op=$op tokens=$tokens) container=$container"
    docker pause "$container" >/dev/null 2>&1 || fail "docker pause $container failed"
    local state; state=$(docker inspect "$container" --format '{{.State.Status}}')
    [[ "$state" == "paused" ]] || fail "expected paused, got $state for $container"
    PAUSED_CONTAINERS+=("$container"); PAUSED_MONIKERS+=("$mon")
    PAUSED_TOKENS=$next_paused

    # Verify chain still progresses
    local h_before=$(get_height)
    local target=$((h_before + LIVE_BLOCKS))
    local h_after
    if h_after=$(wait_height_with_timeout "$target" 30); then
      local pct=$(awk -v t="$PAUSED_TOKENS" -v T="$TOTAL_TOKENS" 'BEGIN{printf "%.2f", (t/T)*100}')
      log "  paused so far: $((${#PAUSED_CONTAINERS[@]})) vals, paused_VP=$PAUSED_TOKENS (${pct}%); chain advanced $h_before -> $h_after"
    else
      fail "chain did NOT advance $LIVE_BLOCKS blocks after pausing $mon (paused_VP=$PAUSED_TOKENS, threshold=$THRESHOLD) — within-tolerance liveness broken; got $h_before -> $h_after"
    fi
  done
  PHASE_A_PAUSED_COUNT=${#PAUSED_CONTAINERS[@]}
  PHASE_A_PAUSED_VP=$PAUSED_TOKENS
  local pct=$(awk -v t="$PAUSED_TOKENS" -v T="$TOTAL_TOKENS" 'BEGIN{printf "%.4f", (t/T)*100}')
  pass "Phase A: $PHASE_A_PAUSED_COUNT vals paused, paused_VP=$PAUSED_TOKENS (${pct}%); chain still live"
  # The next index in SORTED_* is the boundary-crosser for Phase B
  PHASE_B_INDEX=$i
}

# ---------------- Phase 3 — cross threshold, expect halt ----------------
PHASE_B_INDEX=0
PHASE_B_PAUSED_VP=0
phase_3_pause_crossing_threshold() {
  if [[ $PHASE_B_INDEX -ge $NEW_MAX ]]; then
    fail "Phase A consumed all 16 vals without crossing 1/3 threshold — design violated (every BONDED val < 1/3? impossible if N>=4)"
  fi
  local op="${SORTED_OPS[$PHASE_B_INDEX]}"
  local tokens="${SORTED_TOKENS[$PHASE_B_INDEX]}"
  local mon="${SORTED_MONIKERS[$PHASE_B_INDEX]}"
  local container; container=$(container_for_moniker "$mon")

  log "Phase 3 — Phase B: pause $mon (tokens=$tokens) to cross threshold"
  docker pause "$container" >/dev/null 2>&1 || fail "docker pause $container failed"
  local state; state=$(docker inspect "$container" --format '{{.State.Status}}')
  [[ "$state" == "paused" ]] || fail "expected paused, got $state for $container"
  PAUSED_CONTAINERS+=("$container"); PAUSED_MONIKERS+=("$mon")
  PAUSED_TOKENS=$((PAUSED_TOKENS + tokens))
  PHASE_B_PAUSED_VP=$PAUSED_TOKENS
  local pct=$(awk -v t="$PAUSED_TOKENS" -v T="$TOTAL_TOKENS" 'BEGIN{printf "%.4f", (t/T)*100}')
  log "  now ${#PAUSED_CONTAINERS[@]} vals paused, paused_VP=$PAUSED_TOKENS (${pct}%); threshold=$THRESHOLD"
  [[ $PAUSED_TOKENS -ge $THRESHOLD ]] || fail "expected paused_VP >= threshold after Phase B pause; got $PAUSED_TOKENS < $THRESHOLD (off-by-one in pause loop?)"

  log "  observe chain for ${HALT_OBSERVE_SEC}s — must NOT advance more than $HALT_MAX_BLOCKS blocks"
  local h_start=$(get_height)
  sleep "$HALT_OBSERVE_SEC"
  local h_end=$(get_height)
  local delta=$((h_end - h_start))
  log "  chain $h_start -> $h_end (delta=$delta) over ${HALT_OBSERVE_SEC}s"
  if [[ $delta -le $HALT_MAX_BLOCKS ]]; then
    pass "Phase B: chain halted as expected (delta=$delta <= $HALT_MAX_BLOCKS in ${HALT_OBSERVE_SEC}s)"
  else
    fail "Phase B: chain advanced $delta blocks despite paused_VP=$PAUSED_TOKENS >= threshold=$THRESHOLD — BFT halt boundary violated"
  fi
}

# ---------------- Phase 4 — unpause, verify recovery ----------------
phase_4_unpause_and_recover() {
  log "Phase 4 — Phase C: docker unpause all (${#PAUSED_CONTAINERS[@]} vals)"
  local c
  for c in "${PAUSED_CONTAINERS[@]}"; do
    docker unpause "$c" >/dev/null 2>&1 || log "  WARN: unpause $c failed"
    log "  unpaused $c"
  done
  PAUSED_CONTAINERS=()
  PAUSED_TOKENS=0

  local h_start=$(get_height)
  local target=$((h_start + RESUME_BLOCKS))
  log "  expect chain to advance $RESUME_BLOCKS blocks within 60s; start h=$h_start target=$target"
  local h_after
  if h_after=$(wait_height_with_timeout "$target" 60); then
    pass "Phase C: chain resumed (h=$h_start -> $h_after, advanced $((h_after - h_start)) blocks)"
  else
    fail "Phase C: chain did NOT resume (h=$h_start -> $h_after) within 60s after unpause"
  fi
}

# ---------------- Phase 5 — summary ----------------
phase_5_summary() {
  printf "\n========== BFT-LIVENESS-F-DOWN PROBE CONCLUSIONS ==========\n"
  printf "  Bonded set: 16 vals; V_total=%s; threshold(1/3)=%s\n" "$TOTAL_TOKENS" "$THRESHOLD"
  printf "  Phase A:    paused %d vals, paused_VP=%s (%.4f%% of V_total) — chain progressed\n" \
    "$PHASE_A_PAUSED_COUNT" "$PHASE_A_PAUSED_VP" \
    "$(awk -v t=$PHASE_A_PAUSED_VP -v T=$TOTAL_TOKENS 'BEGIN{printf "%.4f", (t/T)*100}')"
  printf "  Phase B:    paused %d vals, paused_VP=%s (%.4f%% of V_total) — chain halted\n" \
    "$((PHASE_A_PAUSED_COUNT + 1))" "$PHASE_B_PAUSED_VP" \
    "$(awk -v t=$PHASE_B_PAUSED_VP -v T=$TOTAL_TOKENS 'BEGIN{printf "%.4f", (t/T)*100}')"
  printf "  Phase C:    all unpaused — chain resumed\n"
  printf "  Final chain height: %s\n" "$(get_height)"
  printf "===========================================================\n"
}

phase_6_teardown() {
  if [[ "$SKIP_TEARDOWN" == "1" ]]; then log "Phase 6 — SKIP_TEARDOWN"; return; fi
  log "Phase 6 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

# ---------------- main ----------------
phase_0_start
phase_1_capture_baseline
phase_2_pause_within_tolerance
phase_3_pause_crossing_threshold
phase_4_unpause_and_recover
phase_5_summary
phase_6_teardown
