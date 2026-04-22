#!/bin/bash
# End-to-end assertion runner for v1.7.0 MaxValidators upgrade test.
# Polls rpc1 (host ports 8545 EVM / 1317 REST / 26657 CometBFT) and validates
# pre-upgrade baseline (block 5), post-upgrade state (UPGRADE_HEIGHT+5 / +15),
# and chain liveness (UPGRADE_HEIGHT+30). Exits 0 if ALL assertions pass.
#
# Dropped the "block UPGRADE_HEIGHT-1" sample — on localnet (block_time ~3s)
# the REST-latest-state query races past the target height and always reads
# post-upgrade. Phase 1 at block 5 already covers pre-upgrade integrity.
#
# Expects:
#   tmp/validators_meta.json  — per-val delegator EVM addresses
#   distribution.json         — per-val token amounts (ranked top-N)
# Assumes NEW_MAX=16 validators post-upgrade, N=20 pre-upgrade.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${REPO_ROOT}/tmp/validators_meta.json"
DIST="${REPO_ROOT}/distribution.json"

N=${N:-20}
NEW_MAX=${NEW_MAX:-16}
UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
EVM=${EVM:-http://localhost:8545}
REST=${REST:-http://localhost:1317}

[ -f "$META" ] || { echo "FAIL: $META missing" >&2; exit 1; }
[ -f "$DIST" ] || { echo "FAIL: $DIST missing" >&2; exit 1; }

FAILS=0

log()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
ok()   { log "PASS  $*"; }
fail() { log "FAIL  $*"; FAILS=$((FAILS + 1)); }

get_height() {
  local hex
  hex=$(curl -fsS -m 5 "$EVM" -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r '.result' 2>/dev/null)
  [ -z "$hex" ] || [ "$hex" = "null" ] && { echo 0; return; }
  printf '%d\n' "$hex"
}

wait_for_block() {
  local target=$1 h
  while :; do
    h=$(get_height)
    if [ "$h" -ge "$target" ]; then return 0; fi
    log "  waiting for block $target (at $h)"
    sleep 2
  done
}

rest_get() { curl -fsS -m 5 "${REST}$1" 2>/dev/null; }

count_validators_by_status() {
  rest_get "/staking/validators?status=$1&pagination.limit=100" \
    | jq -r '.msg.validators | length' 2>/dev/null || echo 0
}

get_max_validators() {
  rest_get "/staking/params" | jq -r '.msg.params.max_validators' 2>/dev/null || echo 0
}

get_bonded_tokens() {
  rest_get "/staking/pool" | jq -r '.msg.pool.bonded_tokens' 2>/dev/null || echo 0
}

get_evm_balance() {
  local addr=$1 hex
  hex=$(curl -fsS -m 5 "$EVM" -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$addr\",\"latest\"],\"id\":1}" 2>/dev/null \
    | jq -r '.result' 2>/dev/null)
  [ -z "$hex" ] || [ "$hex" = "null" ] && { echo 0; return; }
  python3 -c "print(int('$hex', 16))" 2>/dev/null || echo 0
}

log "== Phase 1 (block 5): pre-upgrade baseline =="
wait_for_block 5
bonded=$(count_validators_by_status BOND_STATUS_BONDED)
mv=$(get_max_validators)
[ "$bonded" = "$N" ] && ok "bonded=$bonded (expected $N)" || fail "bonded=$bonded (expected $N)"
[ "$mv" = "$N" ] && ok "max_validators=$mv (expected $N)" || fail "max_validators=$mv (expected $N)"

log "== Phase 2 (block $((UPGRADE_HEIGHT + 5))): post-upgrade state =="
wait_for_block $((UPGRADE_HEIGHT + 5))
bonded=$(count_validators_by_status BOND_STATUS_BONDED)
mv=$(get_max_validators)
pool=$(get_bonded_tokens)
expected_pool=$(python3 -c "import json; d=json.load(open('$DIST')); print(sum(v['tokens'] for v in d[:$NEW_MAX]))")

# NOTE: transient UNBONDING count dropped — on localnet (unbonding_time=10s,
# block_time ~3s) the 4 pruned UBDs mature before the Phase 2 sample even
# runs. UNBONDED count + EVM balances in Phase 3 cover the post-mature state.

[ "$bonded" = "$NEW_MAX" ] && ok "bonded=$bonded (expected $NEW_MAX)" || fail "bonded=$bonded (expected $NEW_MAX)"
[ "$mv" = "$NEW_MAX" ] && ok "max_validators=$mv (expected $NEW_MAX)" || fail "max_validators=$mv (expected $NEW_MAX)"
[ "$pool" = "$expected_pool" ] && ok "bonded_tokens=$pool (expected $expected_pool)" || fail "bonded_tokens=$pool (expected $expected_pool)"

log "== Phase 3 (block $((UPGRADE_HEIGHT + 15))): UBD matured, evmstaking withdrew =="
wait_for_block $((UPGRADE_HEIGHT + 15))
unbonding=$(count_validators_by_status BOND_STATUS_UNBONDING)
[ "$unbonding" = "0" ] && ok "unbonding=0 (UBD queue drained)" || fail "unbonding=$unbonding (expected 0)"

for K in $(seq $((NEW_MAX + 1)) "$N"); do
  evm_addr=$(jq -r --argjson idx "$K" '.[] | select(.index == $idx) | .evm_address' "$META")
  bal=$(get_evm_balance "$evm_addr")
  # awk handles arbitrary-precision integers (bash -gt overflows on >int64 wei values)
  if awk -v b="$bal" 'BEGIN{exit !(b+0 > 0)}'; then
    ok "pruned val $K ($evm_addr) evm balance=$bal > 0"
  else
    fail "pruned val $K ($evm_addr) evm balance=$bal (expected > 0)"
  fi
done

log "== Phase 4 (block $((UPGRADE_HEIGHT + 30))): liveness =="
wait_for_block $((UPGRADE_HEIGHT + 30))
h=$(get_height)
[ "$h" -ge $((UPGRADE_HEIGHT + 30)) ] && ok "chain advanced to $h" || fail "chain stuck at $h"

log "== Log scan: no panic/CONSENSUS FAILURE in validator*-node =="
bad_containers=()
for c in $(docker ps --format '{{.Names}}' | grep -E 'validator[0-9]+-node$' || true); do
  # grep -c reads stdin to EOF (no SIGPIPE under pipefail), || true for zero matches
  n=$(docker logs "$c" 2>&1 | grep -cE 'panic|CONSENSUS FAILURE' || true)
  [ "$n" -gt 0 ] && bad_containers+=("$c")
done
if [ ${#bad_containers[@]} -eq 0 ]; then
  ok "no panic/CONSENSUS FAILURE"
else
  fail "panic/CONSENSUS FAILURE in: ${bad_containers[*]}"
fi

log "========================================"
if [ "$FAILS" -eq 0 ]; then
  log "ALL CHECKS PASSED"
  exit 0
else
  log "$FAILS CHECKS FAILED"
  exit 1
fi
