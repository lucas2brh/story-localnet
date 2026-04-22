#!/usr/bin/env bash
# verify_upgrade_tie.sh — L1 test: deterministic prune at power-tie boundary.
#
# Setup: forces rank-16 and rank-17 in distribution.json to have IDENTICAL
# token amounts, rebuilds genesis, then runs the full localnet. Expects the
# v1.7.0 handler to still produce a deterministic validator set across all
# 20 nodes — no chain halt at activation.
#
# Usage:
#   ./scripts/verify_upgrade_tie.sh                          # full run (regen genesis + start + verify + teardown)
#   SKIP_START=1 ./scripts/verify_upgrade_tie.sh             # localnet already up, just verify + cleanup
#   SKIP_TEARDOWN=1 ./scripts/verify_upgrade_tie.sh          # keep localnet alive for debug
#
# Env:
#   N               validators          default 20
#   NEW_MAX         post-upgrade max    default 16
#   UPGRADE_HEIGHT  block               default 50
#   LIVENESS_DELTA  blocks past upgrade default 30 (final check at UPGRADE_HEIGHT+LIVENESS_DELTA)
#   STORY_BIN       host story binary   default /tmp/story
#
# Exits 0 on deterministic tie resolution, 1 on halt / non-determinism / missing invariant log.

set -euo pipefail

N=${N:-20}
NEW_MAX=${NEW_MAX:-16}
UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
LIVENESS_DELTA=${LIVENESS_DELTA:-30}
STORY_BIN=${STORY_BIN:-/tmp/story}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${LOCALNET}/distribution.json"
DIST_BAK="${LOCALNET}/distribution.json.tie.bak"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[tie]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[tie]${C_RESET} PASS %s\n" "$*"; }
die()  { printf "${C_RED}[tie]${C_RESET} FAIL %s\n" "$*"; exit 1; }

restore_dist() {
  if [[ -f "$DIST_BAK" ]]; then
    mv "$DIST_BAK" "$DIST"
    log "  distribution.json restored from backup"
  fi
}
trap restore_dist EXIT

SKIP_START=${SKIP_START:-0}
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

# ---------------- Phase 0 — tie distribution + rebuild genesis ----------------
phase_0_tie() {
  log "Phase 0 — tie rank-16 and rank-17 in distribution.json"
  [[ -f "$DIST" ]] || die "distribution.json not found at $DIST"
  cp "$DIST" "$DIST_BAK"
  local r16 r17_before
  r16=$(jq '.[15].tokens' "$DIST")
  r17_before=$(jq '.[16].tokens' "$DIST")
  log "  before: rank-16=$r16  rank-17=$r17_before"
  jq '.[16].tokens = .[15].tokens' "$DIST" > "${DIST}.new" && mv "${DIST}.new" "$DIST"
  local r17
  r17=$(jq '.[16].tokens' "$DIST")
  [[ "$r16" == "$r17" ]] || die "tie did not take — rank-16=$r16 rank-17=$r17"
  log "  after:  rank-16=$r16  rank-17=$r17  (tied)"

  log "  rebuild genesis with tied distribution"
  STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" "$N" 2>&1 | tail -1
}

# ---------------- Phase 1 — start localnet ----------------
phase_1_start() {
  if [[ $SKIP_START -eq 1 ]]; then
    log "Phase 1 — --SKIP_START (assume localnet up)"
    return
  fi
  log "Phase 1 — start localnet"
  docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-' \
    && die "validators already running — run ./terminate.sh first"
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -3)
}

# ---------------- Phase 2 — wait for liveness past activation ----------------
get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}

phase_2_liveness() {
  local target=$((UPGRADE_HEIGHT + LIVENESS_DELTA))
  log "Phase 2 — wait for block $target (upgrade at $UPGRADE_HEIGHT + liveness $LIVENESS_DELTA)"
  local prev=0 stuck=0 h
  while :; do
    h=$(get_height)
    if [[ $h -ge $target ]]; then
      ok "chain advanced to $h"
      return
    fi
    if [[ $h -eq $prev ]]; then
      stuck=$((stuck + 1))
    else
      stuck=0
    fi
    prev=$h
    if [[ $stuck -ge 5 ]]; then
      die "chain HALTED at block $h (5 polls unchanged ~50s) — tie likely resolved non-deterministically"
    fi
    log "  at block $h, waiting for $target"
    sleep 10
  done
}

# ---------------- Phase 3 — verify state + tie resolution ----------------
phase_3_verify() {
  log "Phase 3 — verify post-upgrade state + tie resolution"
  local bonded unbonded mv
  bonded=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" | jq '.msg.validators | length')
  unbonded=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_UNBONDED&pagination.limit=100" | jq '.msg.validators | length')
  mv=$(curl -fsS http://localhost:1317/staking/params | jq -r '.msg.params.max_validators')
  [[ "$bonded" == "$NEW_MAX" ]] && ok "bonded=$bonded" || die "bonded=$bonded (expected $NEW_MAX)"
  [[ "$unbonded" == "$((N - NEW_MAX))" ]] && ok "unbonded=$unbonded" || die "unbonded=$unbonded (expected $((N - NEW_MAX)))"
  [[ "$mv" == "$NEW_MAX" ]] && ok "max_validators=$mv" || die "max_validators=$mv (expected $NEW_MAX)"

  log "  tie resolution:"
  curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" \
    | jq -r '.msg.validators | sort_by(-(.tokens|tonumber)) | .[14:18][] | "    \(.description.moniker)  status=\(.status)  tokens=\(.tokens)  operator=\(.operator_address)"'
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
  [[ $misses -eq 0 ]] && ok "invariant log on all $total validators" || die "invariant log missing on $misses validators"
  [[ $panics -eq 0 ]] && ok "no panic / CONSENSUS FAILURE" || die "$panics panic/CONSENSUS FAILURE lines"
}

# ---------------- Phase 5 — teardown ----------------
phase_5_teardown() {
  if [[ $SKIP_TEARDOWN -eq 1 ]]; then
    log "Phase 5 — --SKIP_TEARDOWN (containers left running)"
    return
  fi
  log "Phase 5 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

main() {
  local start_ts end_ts
  start_ts=$(date +%s)
  phase_0_tie
  phase_1_start
  phase_2_liveness
  phase_3_verify
  phase_4_log_scan
  phase_5_teardown
  end_ts=$(date +%s)
  ok "L1 TIE TEST PASS (elapsed $((end_ts - start_ts))s)"
}

main "$@"
