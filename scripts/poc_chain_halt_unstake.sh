#!/usr/bin/env bash
# poc_chain_halt_unstake.sh — minimal reproducer for v1.7.0 chain-halt bug
# and Option B fix verification.
#
# Repros the halt: val-17 (pruned UNBONDED, self-del only) 100% unstake →
# RemoveValidator fires at tx-inclusion block → next block's
# x/distribution.AllocateTokens ValidatorByConsAddr lookup fails → halt.
#
# Usage:
#   EXPECT=halt     ./scripts/poc_chain_halt_unstake.sh  # bug-present binary
#   EXPECT=progress ./scripts/poc_chain_halt_unstake.sh  # Option B patched binary
#
# Env:
#   EXPECT          halt (default) or progress
#   STORY_BIN       host story binary        default /tmp/story
#   CHAIN_ID        EVM chainId              default 1399
#   ANVIL_PK        Anvil #0 private key     default well-known
#   UPGRADE_HEIGHT  upgrade block            default 50
#
# Exit code: 0 if observation matches EXPECT; 1 otherwise.

set -u

EXPECT=${EXPECT:-halt}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
TARGET_MONIKER="localnet-val-17"
WAIT_BLOCK=85
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[poc]${C_RESET} %s\n" "$*"; }
pass() { printf "${C_GREEN}[poc]${C_RESET} PASS %s\n" "$*"; }
fail() { printf "${C_RED}[poc]${C_RESET} FAIL %s\n" "$*"; }

get_height() {
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null \
    | jq -r .result 2>/dev/null)
  [[ -z $hex || $hex == null ]] && { echo 0; return; }
  printf '%d\n' "$hex"
}
wait_height() { local t=$1 h; while :; do h=$(get_height); [[ $h -ge $t ]] && { echo $h; return; }; sleep 2; done }
meta_pubkey_hex() { local b64; b64=$(jq -r --arg m "$1" '.[] | select(.moniker==$m) | .pubkey_base64' "$META"); echo -n "$b64" | base64 -d | xxd -p -c 66; }
meta_privkey() { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"; }
meta_evm_addr() { jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"; }

# Phase 0 — start
log "Phase 0: fresh localnet"
if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
  sleep 5
fi
MAX_VALIDATORS_INIT=20 STORY_BIN="$STORY_BIN" bash "${LOCALNET}/scripts/assemble_genesis.sh" 20 2>&1 | tail -1
(cd "$LOCALNET" && bash start.sh 2>&1 | tail -2)
# rpc1 JWT workaround
deadline=$(( $(date +%s) + 90 )); h=0
while :; do
  h=$(get_height)
  [[ $h -gt 0 ]] && { log "rpc1 sync ok h=$h"; break; }
  if [[ $(date +%s) -ge $deadline ]]; then
    docker restart rpc1-node >/dev/null 2>&1; sleep 15
    h=$(get_height); [[ $h -gt 0 ]] && break
    fail "rpc1 stuck"; exit 1
  fi
  sleep 3
done

# Phase 1 — wait past upgrade
log "Phase 1: wait block 60"
wait_height 60 >/dev/null

# Phase 2 — fund val-17 operator EVM wallet
op_addr=$(meta_evm_addr "$TARGET_MONIKER")
log "Phase 2: fund $TARGET_MONIKER op $op_addr with 10 IP"
cast send --rpc-url http://localhost:8545 --private-key "$ANVIL_PK" "$op_addr" \
  --value 10ether --legacy --gas-price 50gwei 2>&1 | grep -E "status|Error" | head -2
sleep 6

# Phase 3 — val-17 100% self-unstake
log "Phase 3: $TARGET_MONIKER 100% self-unstake"
tokens=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" \
  | jq -r --arg m "$TARGET_MONIKER" '.msg.validators[] | select(.description.moniker==$m) | .tokens')
amount_wei=$(echo "$tokens * 1000000000" | bc)
pub=$(meta_pubkey_hex "$TARGET_MONIKER")
priv=$(meta_privkey "$TARGET_MONIKER")
out=$(PRIVATE_KEY="$priv" "$STORY_BIN" validator unstake \
  --validator-pubkey "$pub" --unstake "$amount_wei" --delegation-id 0 \
  --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
printf '%s\n' "$out" | tail -3 | sed 's/^/    /'
tx=$(grep -oE '0x[0-9a-f]{64}' <<<"$out" | head -1)
log "tx=$tx"

# Phase 4 — wait-or-timeout for halt detection
log "Phase 4: observe chain for 30s to detect halt vs progress (target block $WAIT_BLOCK)"
deadline=$(( $(date +%s) + 30 ))
last_h=0; stuck_count=0; progressed=0
while [[ $(date +%s) -lt $deadline ]]; do
  h=$(get_height)
  if [[ $h -ge $WAIT_BLOCK ]]; then progressed=1; break; fi
  if [[ $h -eq $last_h ]]; then stuck_count=$((stuck_count+1)); else stuck_count=0; fi
  last_h=$h
  sleep 2
done

final_h=$(get_height)
log "final height=$final_h (stuck_count=$stuck_count, progressed=$progressed)"

# Phase 5 — verdict
if [[ $progressed -eq 1 ]]; then
  OBSERVED=progress
else
  OBSERVED=halt
fi
log "OBSERVED=$OBSERVED  EXPECT=$EXPECT"

# Phase 6 — teardown only on success (leave evidence on mismatch for debugging)
if [[ "$OBSERVED" == "$EXPECT" ]]; then
  pass "outcome matches expectation"
  if [[ "${SKIP_TEARDOWN:-0}" != "1" ]]; then
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
  fi
  exit 0
else
  fail "outcome $OBSERVED != expected $EXPECT — containers left running for debugging"
  exit 1
fi
