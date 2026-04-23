#!/usr/bin/env bash
# investigate_pruned_val_behavior.sh — deep-dive after L3 finding that
# redelegate from an UNBONDED (pruned by v1.7.0) validator is silently
# rejected by x/evmstaking with "validator does not exist".
#
# Runs 5 probes against localnet post-upgrade, each independently pass/fail:
#   Q0 sanity: redelegate bonded -> bonded (should work — rules out path bugs)
#   Q2: unstake (undelegate) from pruned val (can delegator accelerate exit?)
#   Q3: stake (delegate) more IP to pruned val (should be rejected)
#   Q4: pre-upgrade redelegate (done BEFORE upgrade block — escape hatch)
#   Q5: natural unbonding returns IP to delegator EVM balance
#
# Each probe:
#   - submit tx via story CLI
#   - record tx hash
#   - wait 10 blocks
#   - grep rpc1-node logs for "Failed to process X" or success events
#   - compare on-chain state before/after
#
# Usage:
#   ./scripts/investigate_pruned_val_behavior.sh   # full fresh run
#   SKIP_TEARDOWN=1 ...                            # keep containers
#
# Env:
#   UPGRADE_HEIGHT   default 50
#   STORY_BIN        default /tmp/story
#   CHAIN_ID         default 1399
#   ANVIL_PK         default well-known anvil key 0 (for Q3 stake)

set -u  # NOT -e: we want to continue past individual probe failures

UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RESET='\033[0m'
log()   { printf "${C_CYAN}[invest]${C_RESET} %s\n" "$*"; }
pass()  { printf "${C_GREEN}[invest]${C_RESET} PASS %s\n" "$*"; }
fail()  { printf "${C_RED}[invest]${C_RESET} FAIL %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[invest]${C_RESET} WARN %s\n" "$*"; }

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
  local target=$1 h
  while :; do
    h=$(get_height)
    [[ $h -ge $target ]] && { echo "$h"; return; }
    sleep 2
  done
}

get_bonded_tokens() {
  local op=$1
  curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null | jq -r '.msg.validator.tokens // "0"'
}

get_evm_balance() {
  local addr=$1
  local hex
  hex=$(curl -fsS -m 5 http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$addr\",\"latest\"],\"id\":1}" \
    | jq -r .result)
  python3 -c "print(int('$hex', 16))" 2>/dev/null || echo 0
}

base64_pubkey_to_hex() {
  echo -n "$1" | base64 -d | xxd -p -c 66
}

val_status() {
  local op=$1
  curl -fsS "http://localhost:1317/staking/validators/${op}" 2>/dev/null | jq -r '.msg.validator.status // "error"'
}

# Look up meta fields by moniker
meta_pubkey_hex() {
  local moniker=$1 b64
  b64=$(jq -r --arg m "$moniker" '.[] | select(.moniker==$m) | .pubkey_base64' "$META")
  base64_pubkey_to_hex "$b64"
}
meta_privkey() {
  jq -r --arg m "$1" '.[] | select(.moniker==$m) | .priv_key_hex' "$META"
}
meta_evm_addr() {
  jq -r --arg m "$1" '.[] | select(.moniker==$m) | .evm_address' "$META"
}

# ---------------- Phase 0 — start fresh localnet ----------------
phase_0_start() {
  log "Phase 0 — start fresh localnet"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    log "  existing containers found, tearing down first (NOT suppressed)"
    (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -5)
    sleep 5
    # assert clean
    if docker ps --format '{{.Names}}' | grep -qE '^(validator[0-9]+-|rpc1-|bootnode1-)'; then
      log "  teardown incomplete, remaining containers:"
      docker ps --format '{{.Names}}' | grep -E '^(validator[0-9]+-|rpc1-|bootnode1-)' | sed 's/^/    /'
      log "  FAIL Phase 0 — terminate.sh did not clean"
      exit 1
    fi
  fi
  log "  starting localnet"
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -3)
  # sanity: rpc1 should produce blocks
  log "  sanity check: waiting 30s for rpc1 to start producing blocks"
  local deadline h
  deadline=$(( $(date +%s) + 60 ))
  while :; do
    h=$(get_height)
    if [[ $h -gt 0 ]]; then
      log "  rpc1 height=$h — start successful"
      return
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      log "  FAIL Phase 0 — rpc1 stuck at height 0 after 60s"
      docker logs --tail 10 rpc1-geth 2>&1 | tail -5 | sed 's/^/    rpc1-geth: /'
      exit 1
    fi
    sleep 3
  done
}

# ---------------- Phase 1 — Q4: pre-upgrade redelegate ----------------
# Try redelegate from val that WILL be pruned (rank 17) to val that will be bonded (rank 16),
# done before the upgrade fires. Per-val rank predictable from distribution.json.
Q4_RESULT=""
phase_1_q4_pre_upgrade() {
  log "Phase 1 [Q4] — pre-upgrade redelegate: val-17 (soon-to-be-pruned) -> val-16 (stays bonded)"
  # Wait block (UPGRADE_HEIGHT - 10) to have plenty of room
  local window_end=$((UPGRADE_HEIGHT - 5))
  wait_height "$((UPGRADE_HEIGHT - 15))" >/dev/null
  log "  at block $(get_height), will complete before $window_end"

  local src_pub dst_pub src_priv
  src_pub=$(meta_pubkey_hex "localnet-val-17")
  dst_pub=$(meta_pubkey_hex "localnet-val-16")
  src_priv=$(meta_privkey "localnet-val-17")

  local src_tokens_pre dst_tokens_pre
  src_tokens_pre=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" | jq -r '.msg.validators[] | select(.description.moniker=="localnet-val-17") | .tokens')
  dst_tokens_pre=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" | jq -r '.msg.validators[] | select(.description.moniker=="localnet-val-16") | .tokens')
  log "  pre-tx: val-17 tokens=$src_tokens_pre val-16 tokens=$dst_tokens_pre"

  # Small redelegate (1% of val-17's tokens) in wei
  local amount_wei
  amount_wei=$(echo "$src_tokens_pre * 1000000000 / 100" | bc)

  local h_before
  h_before=$(get_height)
  local tx_out
  tx_out=$(PRIVATE_KEY="$src_priv" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$src_pub" --validator-dst-pubkey "$dst_pub" \
    --redelegate "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  local cli_rc=$?
  local tx_hash
  tx_hash=$(grep -oE '0x[0-9a-f]{64}' <<<"$tx_out" | head -1)
  log "  CLI rc=$cli_rc tx=$tx_hash"

  wait_height "$((h_before + 8))" >/dev/null

  local log_err log_ok
  log_err=$(docker logs rpc1-node 2>&1 | grep "Failed to process redelegate" | wc -l | tr -d ' ')
  log_ok=$(docker logs rpc1-node 2>&1 | grep -c "EVM staking relegation processed" || true)
  log "  logs: Failed=$log_err Success=$log_ok"

  local src_tokens_post dst_tokens_post
  src_tokens_post=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" | jq -r '.msg.validators[] | select(.description.moniker=="localnet-val-17") | .tokens')
  dst_tokens_post=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" | jq -r '.msg.validators[] | select(.description.moniker=="localnet-val-16") | .tokens')
  log "  post-tx: val-17 tokens=$src_tokens_post val-16 tokens=$dst_tokens_post"

  if [[ $cli_rc -eq 0 && $log_err -eq 0 && "$dst_tokens_post" != "$dst_tokens_pre" ]]; then
    Q4_RESULT="PASS: pre-upgrade redelegate worked"
    pass "Q4 — pre-upgrade redelegate succeeded, dst tokens moved"
  else
    Q4_RESULT="FAIL: cli_rc=$cli_rc log_err=$log_err dst_tokens_delta=$((dst_tokens_post - dst_tokens_pre))"
    fail "Q4 — pre-upgrade redelegate did NOT take effect"
  fi
}

# ---------------- Phase 2 — wait past upgrade ----------------
phase_2_past_upgrade() {
  local target=$((UPGRADE_HEIGHT + 3))
  log "Phase 2 — wait block $target (past upgrade, pruned vals in UNBONDED)"
  wait_height "$target" >/dev/null
  # sample status distribution
  local statuses
  statuses=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" | jq '[.msg.validators[] | {status, moniker: .description.moniker}] | group_by(.status) | map({status: .[0].status, count: length})')
  log "  status distribution: $statuses"
}

# ---------------- Phase 3 — Q0 sanity: bonded -> bonded redelegate ----------------
Q0_RESULT=""
phase_3_q0_sanity() {
  log "Phase 3 [Q0 sanity] — bonded -> bonded redelegate (should succeed)"
  # Pick two bonded vals (top 2 bonded, low ranks)
  local src_moniker dst_moniker
  src_moniker="localnet-val-1"
  dst_moniker="localnet-val-2"
  # Ensure both are bonded
  local s1 s2
  s1=$(val_status "$(meta_evm_addr $src_moniker)")
  s2=$(val_status "$(meta_evm_addr $dst_moniker)")
  [[ "$s1" != "3" || "$s2" != "3" ]] && { warn "Q0 skipped: src_status=$s1 dst_status=$s2"; Q0_RESULT="SKIP"; return; }

  local src_pub dst_pub src_priv src_tokens_pre
  src_pub=$(meta_pubkey_hex "$src_moniker")
  dst_pub=$(meta_pubkey_hex "$dst_moniker")
  src_priv=$(meta_privkey "$src_moniker")
  src_tokens_pre=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" | jq -r --arg m "$src_moniker" '.msg.validators[] | select(.description.moniker==$m) | .tokens')

  local amount_wei
  amount_wei=$(echo "$src_tokens_pre * 1000000000 / 1000" | bc)  # 0.1% of src

  local h_before log_err_before log_ok_before
  h_before=$(get_height)
  log_err_before=$(docker logs rpc1-node 2>&1 | grep -c "Failed to process redelegate" || true)
  log_ok_before=$(docker logs rpc1-node 2>&1 | grep -c "EVM staking relegation processed" || true)

  local tx_out cli_rc
  tx_out=$(PRIVATE_KEY="$src_priv" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$src_pub" --validator-dst-pubkey "$dst_pub" \
    --redelegate "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  cli_rc=$?
  wait_height "$((h_before + 8))" >/dev/null

  local log_err_after log_ok_after
  log_err_after=$(docker logs rpc1-node 2>&1 | grep -c "Failed to process redelegate" || true)
  log_ok_after=$(docker logs rpc1-node 2>&1 | grep -c "EVM staking relegation processed" || true)

  log "  tx rc=$cli_rc  err delta=$((log_err_after - log_err_before))  ok delta=$((log_ok_after - log_ok_before))"

  if [[ $cli_rc -eq 0 && $((log_err_after - log_err_before)) -eq 0 && $((log_ok_after - log_ok_before)) -gt 0 ]]; then
    Q0_RESULT="PASS: bonded->bonded redelegate works"
    pass "Q0 — bonded->bonded redelegate succeeded (sanity check passes)"
  else
    Q0_RESULT="FAIL: cli_rc=$cli_rc err_delta=$((log_err_after - log_err_before))"
    fail "Q0 — bonded->bonded redelegate failed (CLI path may be broken, not just pruned vals)"
  fi
}

# ---------------- Phase 4 — Q2: unstake from pruned val ----------------
Q2_RESULT=""
phase_4_q2_unstake() {
  log "Phase 4 [Q2] — unstake from pruned val (val-17)"
  local src_pub src_priv
  src_pub=$(meta_pubkey_hex "localnet-val-17")
  src_priv=$(meta_privkey "localnet-val-17")
  local src_tokens_pre
  src_tokens_pre=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" | jq -r '.msg.validators[] | select(.description.moniker=="localnet-val-17") | .tokens')
  local amount_wei
  amount_wei=$(echo "$src_tokens_pre * 1000000000 / 1000" | bc)

  local h_before
  h_before=$(get_height)
  local tx_out cli_rc
  tx_out=$(PRIVATE_KEY="$src_priv" "$STORY_BIN" validator unstake \
    --validator-pubkey "$src_pub" --unstake "$amount_wei" --delegation-id 0 \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  cli_rc=$?
  wait_height "$((h_before + 8))" >/dev/null

  local log_err log_ok
  log_err=$(docker logs rpc1-node 2>&1 | grep -c "Failed to process withdraw" || true)
  log_ok=$(docker logs rpc1-node 2>&1 | grep -c "EVM staking withdraw processed" || true)
  log "  tx rc=$cli_rc  Failed_logs=$log_err  Success_logs=$log_ok"
  # (log message key may differ — we'll examine rcp1 directly)
  docker logs rpc1-node 2>&1 | tail -50 | grep -iE "unstake|withdraw|unbond|validator_not_found" | tail -10 | sed 's/^/    /'

  if [[ $cli_rc -eq 0 ]]; then
    Q2_RESULT="PASS: unstake CLI accepted (see logs for actual processing)"
    pass "Q2 — unstake CLI submitted (manual log review for cosmos-side)"
  else
    Q2_RESULT="FAIL: cli rc=$cli_rc"
    fail "Q2 — unstake CLI failed"
  fi
}

# ---------------- Phase 5 — Q3: stake more to pruned val ----------------
Q3_RESULT=""
phase_5_q3_stake() {
  log "Phase 5 [Q3] — stake MORE IP to pruned val (val-17) using Anvil #0 as signer"
  local dst_pub
  dst_pub=$(meta_pubkey_hex "localnet-val-17")
  local amount_wei="2048000000000000000000"  # 2048 IP, well above 1024 min

  local h_before
  h_before=$(get_height)
  local tx_out cli_rc
  tx_out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator stake \
    --validator-pubkey "$dst_pub" --stake "$amount_wei" --staking-period flexible \
    --rpc http://localhost:8545 --chain-id "$CHAIN_ID" 2>&1)
  cli_rc=$?
  wait_height "$((h_before + 8))" >/dev/null

  local log_err
  log_err=$(docker logs rpc1-node 2>&1 | grep -c "Failed to process deposit" || true)
  log "  tx rc=$cli_rc  Failed_deposit_logs=$log_err"
  docker logs rpc1-node 2>&1 | tail -80 | grep -iE "deposit|stake|validator_not_found" | tail -5 | sed 's/^/    /'

  # Check: did val-17 tokens increase?
  local src_tokens_post
  src_tokens_post=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100" | jq -r '.msg.validators[] | select(.description.moniker=="localnet-val-17") | .tokens')
  log "  post val-17 tokens: $src_tokens_post"

  Q3_RESULT="INFO: cli_rc=$cli_rc Failed_deposit_logs=$log_err (see manual output)"
  log "Q3 — deposit/stake to pruned val result captured (characterize via log+state)"
}

# ---------------- Phase 6 — Q5: natural unbonding returns IP ----------------
Q5_RESULT=""
phase_6_q5_natural_unbond() {
  log "Phase 6 [Q5] — wait for natural unbonding to return IP to pruned val's delegator EVM balance"
  local delegator_addr bal_pre bal_post
  delegator_addr=$(meta_evm_addr "localnet-val-17")
  bal_pre=$(get_evm_balance "$delegator_addr")
  log "  delegator $delegator_addr balance pre-wait: $bal_pre wei"
  # Chain unbonding_time=10s; vals pruned at block 50, chain now block ~55-70. They should
  # have fully unbonded already. If IP returned, balance increase visible NOW.
  # Wait another 5 blocks just in case evmstaking processes on some periodic tick.
  local h
  h=$(get_height)
  wait_height "$((h + 5))" >/dev/null
  bal_post=$(get_evm_balance "$delegator_addr")
  log "  delegator balance post-wait: $bal_post wei"

  if awk -v a="$bal_post" -v b="$bal_pre" 'BEGIN{exit !(a+0 > b+0)}'; then
    Q5_RESULT="PASS: delegator EVM balance increased (IP returned)"
    pass "Q5 — delegator balance increased: $bal_pre -> $bal_post"
  else
    Q5_RESULT="FAIL: delegator EVM balance did NOT increase — IP not returned via natural unbond"
    fail "Q5 — delegator balance unchanged $bal_pre -> $bal_post"
  fi
}

# ---------------- Phase 7 — summary ----------------
phase_7_summary() {
  printf "\n========== INVESTIGATION SUMMARY ==========\n"
  printf "Q0 (bonded->bonded redelegate sanity): %s\n" "$Q0_RESULT"
  printf "Q2 (unstake from pruned val):          %s\n" "$Q2_RESULT"
  printf "Q3 (stake more to pruned val):         %s\n" "$Q3_RESULT"
  printf "Q4 (pre-upgrade redelegate):           %s\n" "$Q4_RESULT"
  printf "Q5 (natural unbond returns IP):        %s\n" "$Q5_RESULT"
  printf "===========================================\n"
}

# ---------------- Phase 8 — teardown ----------------
phase_8_teardown() {
  if [[ $SKIP_TEARDOWN -eq 1 ]]; then
    log "Phase 8 — SKIP_TEARDOWN"
    return
  fi
  log "Phase 8 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

main() {
  phase_0_start
  phase_1_q4_pre_upgrade
  phase_2_past_upgrade
  phase_3_q0_sanity
  phase_4_q2_unstake
  phase_5_q3_stake
  phase_6_q5_natural_unbond
  phase_7_summary
  phase_8_teardown
}

main "$@"
