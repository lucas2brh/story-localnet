#!/usr/bin/env bash
# verify_upgrade_idempotent.sh — L4 test: v1.7.0 handler as no-op when
# chain already runs with MaxValidators=NEW_MAX (simulates mainnet where
# gov prop had already lowered the cap before upgrade fires).
#
# Setup: regenerate genesis with MAX_VALIDATORS_INIT=NEW_MAX (16). 20 val
# gen_txs present but only top-16 get bonded at genesis InitChain. Wait
# past upgrade height, assert handler added ZERO new UBD entries.
#
# Usage:
#   ./scripts/verify_upgrade_idempotent.sh                 # full run
#   SKIP_START=1 ./scripts/verify_upgrade_idempotent.sh    # localnet already up
#   SKIP_TEARDOWN=1 ./scripts/verify_upgrade_idempotent.sh # keep containers
#
# Env:
#   N                validators            default 20
#   NEW_MAX          handler target        default 16
#   UPGRADE_HEIGHT   block                 default 50
#   PRE_UPGRADE_GAP  blocks before upgrade default 5 (sample at UPGRADE_HEIGHT-GAP)
#   POST_UPGRADE     blocks past upgrade   default 15 (final check)
#   STORY_BIN        host story binary     default /tmp/story
#
# Exits 0 if handler is proven no-op (bonded/max unchanged, no new UBDs, invariant log clean).

set -euo pipefail

N=${N:-20}
NEW_MAX=${NEW_MAX:-16}
UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
PRE_UPGRADE_GAP=${PRE_UPGRADE_GAP:-5}
POST_UPGRADE=${POST_UPGRADE:-15}
STORY_BIN=${STORY_BIN:-/tmp/story}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENESIS="${LOCALNET}/config/story/genesis-node.json"
GENESIS_BAK="${LOCALNET}/config/story/genesis-node.json.idempotent.bak"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[idem]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[idem]${C_RESET} PASS %s\n" "$*"; }
die()  { printf "${C_RED}[idem]${C_RESET} FAIL %s\n" "$*"; exit 1; }

restore_genesis() {
  if [[ -f "$GENESIS_BAK" ]]; then
    mv "$GENESIS_BAK" "$GENESIS"
    log "  genesis-node.json restored from backup"
  fi
}
trap restore_genesis EXIT

SKIP_START=${SKIP_START:-0}
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

# ---------------- Phase 0 — regen genesis with max=NEW_MAX ----------------
phase_0_genesis() {
  log "Phase 0 — regen genesis with MAX_VALIDATORS_INIT=$NEW_MAX"
  [[ -f "$GENESIS" ]] || die "genesis-node.json not found at $GENESIS"
  cp "$GENESIS" "$GENESIS_BAK"
  MAX_VALIDATORS_INIT="$NEW_MAX" STORY_BIN="$STORY_BIN" \
    bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N" 2>&1 | tail -1
  local cur_max
  cur_max=$(jq -r '.app_state.staking.params.max_validators' "$GENESIS")
  [[ "$cur_max" == "$NEW_MAX" ]] || die "genesis max_validators=$cur_max (expected $NEW_MAX)"
  ok "genesis assembled with max_validators=$cur_max"
}

# ---------------- Phase 1 — start localnet ----------------
phase_1_start() {
  if [[ $SKIP_START -eq 1 ]]; then
    log "Phase 1 — SKIP_START (assume localnet up)"
    return
  fi
  log "Phase 1 — start localnet"
  docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-' \
    && die "validators already running — run ./terminate.sh first"
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -3)
}

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
    [[ $stuck -ge 5 ]] && die "chain HALTED at block $h"
    log "  at block $h, waiting for $target"
    sleep 5
  done
}

count_ubd() {
  curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_UNBONDING&pagination.limit=100" \
    | jq '.msg.validators | length'
}

count_bonded() {
  curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" \
    | jq '.msg.validators | length'
}

get_max() {
  curl -fsS "http://localhost:1317/staking/params" | jq -r '.msg.params.max_validators'
}

# ---------------- Phase 2 — pre-upgrade baseline ----------------
PRE_UBD=""
phase_2_pre() {
  local sample_height=$((UPGRADE_HEIGHT - PRE_UPGRADE_GAP))
  log "Phase 2 — pre-upgrade sample at block $sample_height (= upgrade - $PRE_UPGRADE_GAP)"
  wait_height "$sample_height" >/dev/null
  local bonded max
  bonded=$(count_bonded)
  max=$(get_max)
  PRE_UBD=$(count_ubd)
  [[ "$bonded" == "$NEW_MAX" ]] && ok "bonded=$bonded (already at target)" \
    || die "bonded=$bonded (expected $NEW_MAX — genesis prune should settle by now)"
  [[ "$max" == "$NEW_MAX" ]] && ok "max_validators=$max (already at target)" \
    || die "max_validators=$max (expected $NEW_MAX from genesis)"
  ok "pre-upgrade UBD count=$PRE_UBD (baseline for delta check)"
}

# ---------------- Phase 3 — post-upgrade idempotency ----------------
phase_3_post() {
  local sample_height=$((UPGRADE_HEIGHT + POST_UPGRADE))
  log "Phase 3 — post-upgrade sample at block $sample_height (= upgrade + $POST_UPGRADE)"
  wait_height "$sample_height" >/dev/null
  local bonded max post_ubd
  bonded=$(count_bonded)
  max=$(get_max)
  post_ubd=$(count_ubd)
  [[ "$bonded" == "$NEW_MAX" ]] && ok "bonded=$bonded (unchanged)" \
    || die "bonded=$bonded (expected $NEW_MAX unchanged — handler should be no-op)"
  [[ "$max" == "$NEW_MAX" ]] && ok "max_validators=$max (unchanged)" \
    || die "max_validators=$max (expected $NEW_MAX unchanged)"
  [[ "$post_ubd" == "$PRE_UBD" ]] && ok "UBD count=$post_ubd unchanged (no new UBDs added by handler)" \
    || die "UBD count changed $PRE_UBD -> $post_ubd (handler added UBDs — NOT idempotent)"
}

# ---------------- Phase 4 — invariant log + panic scan ----------------
phase_4_log_scan() {
  log "Phase 4 — invariant log + panic scan"
  local total misses=0 panics=0 c n p
  total=$(docker ps --format '{{.Names}}' | grep -cE '^validator[0-9]+-node$' || true)
  [[ $total -gt 0 ]] || die "no validator-node containers"
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$' | sort -V); do
    n=$(docker logs "$c" 2>&1 | grep -c 'All upgrade invariants verified' || true)
    [[ $n -eq 0 ]] && { misses=$((misses + 1)); log "    MISS $c"; }
    p=$(docker logs "$c" 2>&1 | grep -cE 'panic|CONSENSUS FAILURE' || true)
    panics=$((panics + p))
  done
  [[ $misses -eq 0 ]] && ok "invariant log on all $total validators" \
    || die "invariant log missing on $misses validators"
  [[ $panics -eq 0 ]] && ok "no panic / CONSENSUS FAILURE" \
    || die "$panics panic/CONSENSUS FAILURE lines"
}

# ---------------- Phase 5 — teardown ----------------
phase_5_teardown() {
  if [[ $SKIP_TEARDOWN -eq 1 ]]; then
    log "Phase 5 — SKIP_TEARDOWN (containers left running)"
    return
  fi
  log "Phase 5 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

main() {
  local start_ts end_ts
  start_ts=$(date +%s)
  phase_0_genesis
  phase_1_start
  phase_2_pre
  phase_3_post
  phase_4_log_scan
  phase_5_teardown
  end_ts=$(date +%s)
  ok "L4 IDEMPOTENCY TEST PASS (elapsed $((end_ts - start_ts))s)"
}

main "$@"
