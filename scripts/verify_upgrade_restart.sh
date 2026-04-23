#!/usr/bin/env bash
# verify_upgrade_restart.sh — L6 test: v1.7.0 upgrade state persistence
# across a full-cluster restart. Validates that LastValidatorPowerKey
# pruning done by the handler at UPGRADE_HEIGHT is written to IAVL disk
# state, not just in-memory, and survives docker stop + docker start.
#
# Uses `docker stop` (preserves containers + volumes), NOT terminate.sh
# (which does `down -v` and wipes state).
#
# Usage:
#   ./scripts/verify_upgrade_restart.sh                  # full run
#   SKIP_START=1 ./scripts/verify_upgrade_restart.sh     # localnet already up past upgrade
#   SKIP_TEARDOWN=1 ./scripts/verify_upgrade_restart.sh  # keep containers
#
# Env:
#   NEW_MAX          post-upgrade max    default 16
#   UPGRADE_HEIGHT   block               default 50
#   POST_UPGRADE     blocks past upgrade default 20 (stabilize before restart)
#   RESTART_PAUSE    seconds             default 5 (FS flush between stop/start)
#   RESUME_DELTA     blocks              default 5 (must advance past this after start)
#   STORY_BIN        host story binary   default /tmp/story
#
# Exits 0 if state is byte-identical across restart (except new block height).

set -euo pipefail

NEW_MAX=${NEW_MAX:-16}
UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
POST_UPGRADE=${POST_UPGRADE:-20}
RESTART_PAUSE=${RESTART_PAUSE:-5}
RESUME_DELTA=${RESUME_DELTA:-5}
STORY_BIN=${STORY_BIN:-/tmp/story}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[restart]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[restart]${C_RESET} PASS %s\n" "$*"; }
die()  { printf "${C_RED}[restart]${C_RESET} FAIL %s\n" "$*"; exit 1; }

SKIP_START=${SKIP_START:-0}
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

# ---------------- helpers ----------------
get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}

wait_height() {
  local target=$1 prev=0 stuck=0 h
  while :; do
    h=$(get_height)
    if [[ $h -ge $target ]]; then echo "$h"; return; fi
    if [[ $h -eq $prev ]]; then stuck=$((stuck + 1)); else stuck=0; fi
    prev=$h
    [[ $stuck -ge 8 ]] && die "chain not advancing past $h (target $target)"
    log "  at block $h, waiting for $target"
    sleep 5
  done
}

sample_bonded_ops() {
  curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" \
    | jq -r '.msg.validators | map(.operator_address) | sort | join(",")'
}

sample_max() {
  curl -fsS "http://localhost:1317/staking/params" | jq -r '.msg.params.max_validators'
}

sample_ubd_count() {
  curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_UNBONDING&pagination.limit=100" \
    | jq '.msg.validators | length'
}

all_containers() {
  docker ps --format '{{.Names}}' | grep -E '^(validator[0-9]+-(node|geth)|rpc1-(node|geth)|bootnode1-(node|geth))$' || true
}

# ---------------- Phase 1 — start localnet ----------------
phase_1_start() {
  if [[ $SKIP_START -eq 1 ]]; then
    log "Phase 1 — SKIP_START (assume localnet up past upgrade)"
    return
  fi
  log "Phase 1 — start localnet"
  docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-' \
    && die "validators already running — run ./terminate.sh first"
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -3)
}

# ---------------- Phase 2 — wait for stable post-upgrade state ----------------
phase_2_wait() {
  local target=$((UPGRADE_HEIGHT + POST_UPGRADE))
  log "Phase 2 — wait block $target (upgrade done, UBD drained)"
  local h
  h=$(wait_height "$target")
  ok "chain advanced to $h pre-restart"
}

# ---------------- Phase 3 — sample baseline ----------------
H_PRE=""; BONDED_PRE=""; MAX_PRE=""; UBD_PRE=""; INVARIANT_COUNTS_PRE=""
phase_3_baseline() {
  log "Phase 3 — sample pre-restart state"
  H_PRE=$(get_height)
  BONDED_PRE=$(sample_bonded_ops)
  MAX_PRE=$(sample_max)
  UBD_PRE=$(sample_ubd_count)
  local bonded_count
  bonded_count=$(awk -F, '{print NF}' <<<"$BONDED_PRE")
  [[ "$bonded_count" == "$NEW_MAX" ]] || die "pre-restart bonded count=$bonded_count (expected $NEW_MAX)"
  log "  H_PRE=$H_PRE bonded=$bonded_count max=$MAX_PRE UBD=$UBD_PRE"
  # Record invariant log counts per validator-node (should be exactly 1 each pre-restart)
  local c n
  INVARIANT_COUNTS_PRE=""
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$' | sort -V); do
    n=$(docker logs "$c" 2>&1 | grep -c 'All upgrade invariants verified' || true)
    INVARIANT_COUNTS_PRE+="$c=$n;"
    [[ $n -eq 1 ]] || die "pre-restart $c invariant log count=$n (expected 1)"
  done
  ok "pre-restart: all 20 validators each logged invariant exactly once"
}

# ---------------- Phase 4 — docker stop everything ----------------
phase_4_stop() {
  log "Phase 4 — docker stop all cluster containers"
  local names
  names=$(all_containers)
  [[ -n "$names" ]] || die "no containers to stop"
  local count
  count=$(wc -l <<<"$names" | tr -d ' ')
  log "  stopping $count containers"
  # shellcheck disable=SC2086
  docker stop -t 5 $names >/dev/null
  # Verify all stopped
  local still_running
  still_running=$(all_containers || true)
  [[ -z "$still_running" ]] || die "containers still running after stop: $still_running"
  ok "all $count containers stopped"
}

# ---------------- Phase 5 — pause ----------------
phase_5_pause() {
  log "Phase 5 — pause ${RESTART_PAUSE}s for FS sync"
  sleep "$RESTART_PAUSE"
}

# ---------------- Phase 6 — docker start ----------------
phase_6_start() {
  log "Phase 6 — docker start all stopped containers"
  local names
  # Get containers in Exited state
  names=$(docker ps -a --format '{{.Names}}\t{{.Status}}' \
    | awk -F'\t' '$2 ~ /^Exited/ {print $1}' \
    | grep -E '^(validator[0-9]+-(node|geth)|rpc1-(node|geth)|bootnode1-(node|geth))$' || true)
  [[ -n "$names" ]] || die "no stopped containers found"
  local count
  count=$(wc -l <<<"$names" | tr -d ' ')
  log "  starting $count containers"
  # shellcheck disable=SC2086
  docker start $names >/dev/null
  ok "issued docker start for $count containers"
}

# ---------------- Phase 7 — wait for chain to resume ----------------
phase_7_resume() {
  local target=$((H_PRE + RESUME_DELTA))
  log "Phase 7 — wait for chain to resume: height > $H_PRE + $RESUME_DELTA = $target"
  local h
  h=$(wait_height "$target")
  ok "chain resumed, advanced to $h"
}

# ---------------- Phase 8 — re-sample + assert equality ----------------
phase_8_verify() {
  log "Phase 8 — verify post-restart state matches pre-restart"
  local H_POST BONDED_POST MAX_POST UBD_POST
  H_POST=$(get_height)
  BONDED_POST=$(sample_bonded_ops)
  MAX_POST=$(sample_max)
  UBD_POST=$(sample_ubd_count)
  log "  H_POST=$H_POST bonded_count=$(awk -F, '{print NF}' <<<"$BONDED_POST") max=$MAX_POST UBD=$UBD_POST"

  [[ "$H_POST" -gt "$H_PRE" ]] \
    && ok "height advanced $H_PRE -> $H_POST" \
    || die "height did not advance: $H_PRE -> $H_POST"

  [[ "$BONDED_POST" == "$BONDED_PRE" ]] \
    && ok "bonded operator set unchanged" \
    || die "bonded set differs across restart:\n  PRE:  $BONDED_PRE\n  POST: $BONDED_POST"

  [[ "$MAX_POST" == "$MAX_PRE" ]] \
    && ok "max_validators unchanged ($MAX_POST)" \
    || die "max_validators differs: PRE=$MAX_PRE POST=$MAX_POST"

  [[ "$UBD_POST" == "$UBD_PRE" ]] \
    && ok "UBD count unchanged ($UBD_POST) — handler did not replay" \
    || die "UBD count differs: PRE=$UBD_PRE POST=$UBD_POST (handler may have replayed)"

  # Invariant log count must still be exactly 1 per validator (not 2)
  local c n
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$' | sort -V); do
    n=$(docker logs "$c" 2>&1 | grep -c 'All upgrade invariants verified' || true)
    [[ $n -eq 1 ]] || die "post-restart $c invariant log count=$n (expected 1 — count=2 would mean handler replayed)"
  done
  ok "invariant log count still exactly 1 on all 20 validators"

  # Scan for panics in logs produced AFTER restart
  local since restart_ts
  restart_ts=$(docker inspect -f '{{.State.StartedAt}}' rpc1-node 2>/dev/null | head -1)
  [[ -n "$restart_ts" ]] || die "could not read restart timestamp"
  log "  scanning logs --since $restart_ts for panic"
  local panics=0 p
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$' | sort -V); do
    p=$(docker logs --since "$restart_ts" "$c" 2>&1 | grep -cE 'panic|CONSENSUS FAILURE' || true)
    panics=$((panics + p))
  done
  [[ $panics -eq 0 ]] \
    && ok "no panic / CONSENSUS FAILURE in post-restart logs" \
    || die "$panics panic/CONSENSUS FAILURE lines post-restart"
}

# ---------------- Phase 9 — teardown ----------------
phase_9_teardown() {
  if [[ $SKIP_TEARDOWN -eq 1 ]]; then
    log "Phase 9 — SKIP_TEARDOWN (containers left running)"
    return
  fi
  log "Phase 9 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

main() {
  local start_ts end_ts
  start_ts=$(date +%s)
  phase_1_start
  phase_2_wait
  phase_3_baseline
  phase_4_stop
  phase_5_pause
  phase_6_start
  phase_7_resume
  phase_8_verify
  phase_9_teardown
  end_ts=$(date +%s)
  ok "L6 RESTART TEST PASS (elapsed $((end_ts - start_ts))s)"
}

main "$@"
