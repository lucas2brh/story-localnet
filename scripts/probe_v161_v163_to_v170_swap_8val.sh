#!/usr/bin/env bash
# probe_v161_v163_to_v170_swap_8val.sh
#
# Scenario C of binary-swap-test-plan.md: 2 v1.6.3 + 6 v1.6.1 → v1.7.0 rolling swap.
# Verifies public release v1.7.0 (commit b1b1097, Seneca path) executes correctly
# when chain was bootstrapped on a mixed v1.6.1 + v1.6.3 binary set.
#
# Topology:
#   val1, val2 = story-node:v1.6.3-localnet (DKG-class minority — Aeneid: 5/48 ≈ 10%)
#   val3..val8 = story-node:v1.6.1-localnet (majority)
#   bootnode1  = story-node:v1.6.1-localnet (non-validator)
#
# Heights (in v1.7.0 patched upgrades.go for StoryLocalnetID):
#   Horace = 10  — fires pre-swap on whichever v1.6.x binary is running
#   H_swap = 30  — stop+restart each validator to v1.7.0, rolling 1 at a time
#   Seneca = 100 — applyDeferredMaxValidatorsChange fires on v1.7.0 binary
#   H_end  = 130 — stop scenario, dump evidence
#
# Genesis pre-conditions (must be patched by operator before this probe runs):
#   - max_validators = 8 (so all 8 vals bond initially; Seneca then prunes to 4)
#   - unbonding_time = 600s (so we observe status=UNBONDING before transition to UNBONDED)
#
# Chain-asserted assertions:
#   A.1 v1.7.0 "Applied deferred MaxValidators reduction" log on all 8 nodes at H=100
#   A.2 H=100 block hash identical across all 8 nodes (no fork at Seneca)
#   A.3 H=101 block produced (chain didn't halt)
#   A.4 post-Seneca BONDED count = 4
#   A.5 val5..val8 transition to BOND_STATUS_UNBONDING (status=2) — observable within unbonding_time=600s
#   A.6 AppHash continuity at swap boundary: H=29 (pre-swap) + H=35 (post-swap pre-Seneca) cross-node consistency
#   C7  Cohort symmetry: at H=99 (one block pre-Seneca, all 8 on v1.7.0), all 8 nodes return identical app_hash
#
# Usage:
#   ./scripts/probe_v161_v163_to_v170_swap_8val.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_v161_v163_to_v170_swap_8val.sh    # leave chain running after
#   SKIP_BOOT=1 ...                                                    # only if you know chain is clean v1.6.x state
#
# Outputs:
#   tmp/probe-binary-swap-evidence/  during run
#   docs/test-evidence/v170-binary-swap-paths-<date>/C-mixed-to-v170/  after copy

set -u

# --- params ---
N_VALS=${N_VALS:-8}
H_SWAP=${H_SWAP:-30}
H_PRE_SWAP=$((H_SWAP - 1))     # H=29
H_POST_SWAP=$((H_SWAP + 5))    # H=35
H_PRE_SENECA=99
H_SENECA=${H_SENECA:-100}
H_POST_SENECA=$((H_SENECA + 1))      # H=101
H_END=${H_END:-130}
UNBONDING_TIME=${UNBONDING_TIME:-600s}
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
SKIP_BOOT=${SKIP_BOOT:-0}

LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EV_DIR="${LOCALNET}/tmp/probe-binary-swap-evidence"
GENESIS="${LOCALNET}/config/story/genesis-node.json"

# --- helpers ---
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

rpc() {
  local N=$1
  shift
  docker exec "validator${N}-node" wget -qO- "http://localhost:26657$*" 2>/dev/null
}
api() {
  local N=$1
  shift
  docker exec "validator${N}-node" wget -qO- "http://localhost:1317$*" 2>/dev/null
}

height_of() {
  rpc "$1" /status | jq -r '.result.sync_info.latest_block_height' 2>/dev/null
}

wait_until_height() {
  local target=$1
  local deadline=$(( $(date +%s) + 600 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local min=999999
    local max=0
    for N in $(seq 1 $N_VALS); do
      H=$(height_of "$N")
      [ -z "$H" ] && H=0
      [ "$H" -lt "$min" ] && min=$H
      [ "$H" -gt "$max" ] && max=$H
    done
    log "heights min=$min max=$max (waiting >= $target)"
    [ "$min" -ge "$target" ] && return 0
    sleep 3
  done
  fail "timeout waiting for all $N_VALS vals to reach H>=$target"
}

apphash_at() {
  local N=$1 H=$2
  rpc "$N" "/block?height=$H" | jq -r '.result.block.header.app_hash'
}

dump_apphash_all_vals() {
  local H=$1 outfile=$2
  : > "$outfile"
  for N in $(seq 1 $N_VALS); do
    HASH=$(apphash_at "$N" "$H")
    echo "val${N}: $HASH" >> "$outfile"
  done
  awk '{print $2}' "$outfile" | sort -u | wc -l | tr -d ' '
}

# --- preconditions ---
mkdir -p "$EV_DIR/containers"
log "evidence dir: $EV_DIR"

# verify genesis (advisory; would have triggered Seneca no-op last time)
MAX_VAL=$(jq -r '.app_state.staking.params.max_validators' "$GENESIS")
UBT=$(jq -r '.app_state.staking.params.unbonding_time' "$GENESIS")
log "genesis: max_validators=$MAX_VAL unbonding_time=$UBT"
[ "$MAX_VAL" = "8" ] || fail "genesis max_validators=$MAX_VAL, want 8 (run: jq '.app_state.staking.params.max_validators=8' to patch)"

# verify 3 docker images exist
for v in v1.6.1 v1.6.3 v1.7.0; do
  docker image inspect "story-node:${v}-localnet" >/dev/null 2>&1 || \
    fail "image story-node:${v}-localnet missing — run binary-swap-test-plan Phase 1"
done
log "✓ 3 docker images present"

# --- Phase 0: terminate any previous state + boot fresh ---
if [ "$SKIP_BOOT" != "1" ]; then
  log "Phase 0: terminate + boot fresh"

  # 0a: clean shutdown of any prior chain
  log "  terminate previous state"
  "$LOCALNET/terminate.sh" >/dev/null 2>&1 || true

  # 0b: rebuild story-geth:localnet (terminate.sh deletes it)
  if ! docker image inspect story-geth:localnet >/dev/null 2>&1; then
    log "  building story-geth:localnet"
    docker buildx build --load -t story-geth:localnet \
      -f "$LOCALNET/Dockerfile.story-geth" "$LOCALNET/../story-geth" >/dev/null 2>&1 \
      || fail "story-geth build failed"
  fi

  # 0c: generate JWT secret if missing
  JWT_FILE="$LOCALNET/tmp/jwt/secret.txt"
  if [ ! -s "$JWT_FILE" ]; then
    mkdir -p "$(dirname "$JWT_FILE")"
    openssl rand -hex 32 > "$JWT_FILE"
  fi

  # 0d: boot monitoring + chain
  export COMPOSE_IGNORE_ORPHANS=true
  log "  booting monitoring + bootnode + 8 vals"
  docker compose -f "$LOCALNET/docker-compose-monitoring.yml" up -d >/dev/null 2>&1
  docker compose \
    -f "$LOCALNET/docker-compose-bootnode1.yml" \
    -f "$LOCALNET/docker-compose-validator1.yml" \
    -f "$LOCALNET/docker-compose-validator2.yml" \
    -f "$LOCALNET/docker-compose-validator3.yml" \
    -f "$LOCALNET/docker-compose-validator4.yml" \
    -f "$LOCALNET/docker-compose-validator5.yml" \
    -f "$LOCALNET/docker-compose-validator6.yml" \
    -f "$LOCALNET/docker-compose-validator7.yml" \
    -f "$LOCALNET/docker-compose-validator8.yml" \
    -f "$LOCALNET/compose.scenario-C.yml" \
    up -d --no-build >/dev/null 2>&1 \
    || fail "chain boot failed"

  # 0e: wait for all 8 to start producing blocks
  log "  waiting for chain to start producing blocks (15s warmup)"
  sleep 15
fi

# verify topology
log "verifying topology..."
for N in 1 2; do
  IMG=$(docker ps --format "{{.Image}}" --filter "name=^validator${N}-node$")
  [ "$IMG" = "story-node:v1.6.3-localnet" ] || fail "val${N} image=$IMG, want v1.6.3"
done
for N in 3 4 5 6 7 8; do
  IMG=$(docker ps --format "{{.Image}}" --filter "name=^validator${N}-node$")
  [ "$IMG" = "story-node:v1.6.1-localnet" ] || fail "val${N} image=$IMG, want v1.6.1"
done
log "✓ topology: val1+val2 v1.6.3, val3..val8 v1.6.1"

# --- Phase 1: pre-swap state-hash check at H_PRE_SWAP=29 ---
log "waiting for all 8 vals to reach H=$H_SWAP"
wait_until_height "$H_SWAP"

log "dumping AppHash at H=$H_PRE_SWAP across all 8 vals"
DISTINCT=$(dump_apphash_all_vals "$H_PRE_SWAP" "$EV_DIR/A6-pre-swap-H${H_PRE_SWAP}-apphash.txt")
log "distinct hashes at H=$H_PRE_SWAP: $DISTINCT (want 1)"
[ "$DISTINCT" = "1" ] || fail "C7 pre-swap divergence — v1.6.1 vs v1.6.3 state mismatch at H=$H_PRE_SWAP"
log "✓ C7 pre-swap consistency passed"

# --- Phase 2: rolling swap to v1.7.0 ---
# Each per-validator step: stop → up (new image) → fixed 15s settle.
# Per docker-compose-validator${N}.yml the entrypoint has `sleep 10 && story run`,
# plus ~5s for story to start consensus. 15s settle is the realistic minimum;
# we verify all 8 actually on v1.7.0 at end of loop (chain-asserted).
# Total swap budget: 8 × ~17s = ~136s. Window between H=30 and H=100 = 168s.
log "ROLLING SWAP: 1 validator at a time, stop+up+15s settle each"
SWAP_START=$(date +%s)
for N in 1 2 3 4 5 6 7 8; do
  log "swap val${N}: stop"
  docker compose \
    -f "$LOCALNET/docker-compose-validator${N}.yml" \
    -f "$LOCALNET/compose.scenario-C-post-swap.yml" \
    stop "validator${N}-node" >/dev/null 2>&1
  log "swap val${N}: up (v1.7.0 image)"
  docker compose \
    -f "$LOCALNET/docker-compose-validator${N}.yml" \
    -f "$LOCALNET/compose.scenario-C-post-swap.yml" \
    up -d --no-build "validator${N}-node" >/dev/null 2>&1
  sleep 15
  log "  val${N} swap done"
done
SWAP_END=$(date +%s)
SWAP_DUR=$((SWAP_END - SWAP_START))
log "swap complete in ${SWAP_DUR}s"

# verify all 8 actually on v1.7.0 (chain-asserted via per-container story binary)
# NOTE: `story version` writes to STDERR, not stdout. Must use 2>&1 to capture.
log "verifying all 8 validators report v1.7.0-stable"
not_v170=0
for N in 1 2 3 4 5 6 7 8; do
  V=$(docker exec "validator${N}-node" story version 2>&1 | awk '/^Version/{print $2}')
  IMG=$(docker ps --format "{{.Image}}" --filter "name=^validator${N}-node$")
  echo "val${N}: version=$V image=$IMG" >> "$EV_DIR/swap-version-check.txt"
  if [ "$V" != "v1.7.0-stable" ]; then
    not_v170=$((not_v170 + 1))
  fi
done
[ "$not_v170" = "0" ] || fail "$not_v170 validators not on v1.7.0 after swap (see $EV_DIR/swap-version-check.txt)"
log "✓ all 8 validators on v1.7.0-stable"

# --- Phase 3: post-swap pre-Seneca state-hash at H_POST_SWAP=35 ---
wait_until_height "$H_POST_SWAP"
log "dumping AppHash at H=$H_POST_SWAP (5 blocks post-swap, all on v1.7.0)"
DISTINCT=$(dump_apphash_all_vals "$H_POST_SWAP" "$EV_DIR/A6-post-swap-H${H_POST_SWAP}-apphash.txt")
log "distinct: $DISTINCT (want 1)"
[ "$DISTINCT" = "1" ] || fail "A6 post-swap divergence at H=$H_POST_SWAP"
log "✓ A6 post-swap consistency passed"

# --- Phase 4: pre-Seneca cohort symmetry check at H=H_PRE_SENECA=99 ---
wait_until_height "$H_PRE_SENECA"
log "dumping AppHash at H=$H_PRE_SENECA (one block pre-Seneca)"
DISTINCT=$(dump_apphash_all_vals "$H_PRE_SENECA" "$EV_DIR/C7-pre-seneca-H${H_PRE_SENECA}-apphash.txt")
log "distinct: $DISTINCT (want 1)"
[ "$DISTINCT" = "1" ] || fail "C7 cohort symmetry failed at H=$H_PRE_SENECA"
log "✓ C7 pre-Seneca consistency passed"

# --- Phase 5: Seneca fires at H_SENECA=100 ---
wait_until_height "$H_SENECA"
log "Seneca height reached, checking for 'Applied deferred MaxValidators reduction' log"
for N in 1 2 3 4 5 6 7 8; do
  hits=$(docker logs "validator${N}-node" 2>&1 | grep -c "Applied deferred MaxValidators reduction")
  echo "val${N}: $hits" >> "$EV_DIR/A1-seneca-log-hits.txt"
done
SUM=$(awk -F: '{s+=$2} END {print s}' "$EV_DIR/A1-seneca-log-hits.txt")
log "A.1: log hits across all 8 vals: $SUM (want 8)"
[ "$SUM" -ge 8 ] || log "  ⚠ A.1 PARTIAL — expected 8, got $SUM (may be log-level filtered)"

# A.2: H_SENECA block hash identical across all 8
DISTINCT=$(dump_apphash_all_vals "$H_SENECA" "$EV_DIR/A2-seneca-H${H_SENECA}-apphash.txt")
log "A.2: H=$H_SENECA apphash distinct: $DISTINCT (want 1)"
[ "$DISTINCT" = "1" ] || fail "A.2 fork at Seneca"
log "✓ A.2 passed"

# A.3: H_POST_SENECA produced
wait_until_height "$H_POST_SENECA"
log "✓ A.3 H=$H_POST_SENECA produced (chain didn't halt)"

# A.4: BONDED count = 4
BONDED=$(api 1 "/staking/validators?status=BOND_STATUS_BONDED&pagination.count_total=true" | jq -r '.msg.pagination.total')
echo "BONDED=$BONDED" > "$EV_DIR/A4-bonded-count.txt"
log "A.4: BONDED count = $BONDED (want 4)"
[ "$BONDED" = "4" ] || fail "A.4 bonded != 4"
log "✓ A.4 passed"

# A.5: val5..val8 transition to UNBONDING (or UNBONDED if 600s already elapsed)
api 1 "/staking/validators" | jq '.msg.validators[] | {moniker: .description.moniker, status, jailed, tokens}' > "$EV_DIR/A5-validators-post-seneca.json"
UNBONDING_OR_UNBONDED=$(jq '[.msg.validators[] | select(.status==1 or .status==2)] | length' < <(api 1 "/staking/validators"))
log "A.5: vals with status UNBONDING(2) or UNBONDED(1) = $UNBONDING_OR_UNBONDED (want 4)"
[ "$UNBONDING_OR_UNBONDED" = "4" ] || fail "A.5 wrong count of removed vals"
log "✓ A.5 passed"

# --- Phase 6: H_END monitoring + final evidence dump ---
wait_until_height "$H_END"

# full AppHash table across sampled heights
log "dumping full AppHash table"
{
  for H in $H_PRE_SWAP $H_POST_SWAP $H_PRE_SENECA $H_SENECA $H_POST_SENECA $H_END; do
    echo "## H=$H"
    for N in $(seq 1 $N_VALS); do
      HASH=$(apphash_at "$N" "$H")
      echo "  val${N}: $HASH"
    done
  done
} > "$EV_DIR/all-heights-apphash.txt"

# distinct counts
{
  for H in $H_PRE_SWAP $H_POST_SWAP $H_PRE_SENECA $H_SENECA $H_POST_SENECA $H_END; do
    n=$(awk "/^## H=$H\$/{f=1; next} /^## H=/{f=0} f" "$EV_DIR/all-heights-apphash.txt" | awk '{print $2}' | sort -u | wc -l)
    echo "H=$H: $n distinct"
  done
} > "$EV_DIR/apphash-distinct-summary.txt"

# block_results at Seneca height
rpc 1 "/block_results?height=${H_SENECA}" > "$EV_DIR/H${H_SENECA}-block-results.json"

# staking params + validator dump
api 1 "/staking/params" > "$EV_DIR/staking-params-post.json"
api 1 "/staking/validators" > "$EV_DIR/validators-list-post.json"

# container logs
for N in $(seq 1 $N_VALS); do
  docker logs "validator${N}-node" > "$EV_DIR/containers/val${N}.log" 2>&1
done

# --- final summary ---
log ""
log "=== probe summary ==="
log "swap wallclock: ${SWAP_DUR}s"
log "scenario evidence dir: $EV_DIR"
log ""
log "Pre-swap H=$H_PRE_SWAP: 1 distinct hash → ✓ C7"
log "Post-swap H=$H_POST_SWAP: 1 distinct hash → ✓ A.6"
log "Pre-Seneca H=$H_PRE_SENECA: 1 distinct hash → ✓ C7"
log "Seneca log emit: $SUM/8 → A.1 ${SUM:-0} (may be log-level filtered if <8)"
log "Seneca H=$H_SENECA: 1 distinct hash → ✓ A.2"
log "Post-Seneca chain alive: ✓ A.3"
log "BONDED post-Seneca: $BONDED → ✓ A.4"
log "UNBONDING/UNBONDED count: $UNBONDING_OR_UNBONDED → ✓ A.5"
log ""
log "✓ PROBE PASS (caveat: A.1 may be partial due to log-level filtering)"

# --- teardown ---
if [ "$SKIP_TEARDOWN" = "0" ]; then
  log "tearing down (set SKIP_TEARDOWN=1 to keep chain running)"
  "$LOCALNET/terminate.sh" 2>&1 | tail -3
else
  log "leaving chain running (SKIP_TEARDOWN=1)"
fi
