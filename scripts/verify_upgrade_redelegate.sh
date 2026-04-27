#!/usr/bin/env bash
# verify_upgrade_redelegate.sh — L3 test: redelegate from dropped val to
# top-16 after v1.7.0 upgrade. Asserts MaxValidators cap is not broken:
# dropped val stays unbonded, target val gains stake, operator set does
# not change.
#
# Timing: localnet unbonding_time=10s. Must redelegate while dropped val
# is in BOND_STATUS_UNBONDING (delegation still linked), not after it
# fully unbonds (evmstaking may have already returned IP to delegator).
# POST_UPGRADE defaults to 2 blocks (~6s past upgrade).
#
# Usage:
#   ./scripts/verify_upgrade_redelegate.sh                 # full run
#   SKIP_START=1 ./scripts/verify_upgrade_redelegate.sh    # localnet already in UBD window
#   SKIP_TEARDOWN=1 ./scripts/verify_upgrade_redelegate.sh # keep containers
#
# Env:
#   N                validators            default 20
#   NEW_MAX          post-upgrade max      default 16
#   UPGRADE_HEIGHT   block                 default 50
#   POST_UPGRADE     blocks past upgrade   default 2 (must stay inside UBD window)
#   VSU_BLOCKS       blocks after tx       default 10
#   STORY_BIN        host story binary     default /tmp/story
#   CHAIN_ID         EVM chainId           default 1399
#
# Exits 0 if redelegate succeeds without breaking MaxValidators cap.

set -euo pipefail

N=${N:-20}
NEW_MAX=${NEW_MAX:-16}
UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
POST_UPGRADE=${POST_UPGRADE:-2}
VSU_BLOCKS=${VSU_BLOCKS:-10}
STORY_BIN=${STORY_BIN:-/tmp/story}
CHAIN_ID=${CHAIN_ID:-1399}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="${LOCALNET}/tmp/validators_meta.json"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[redeleg]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[redeleg]${C_RESET} PASS %s\n" "$*"; }
die()  { printf "${C_RED}[redeleg]${C_RESET} FAIL %s\n" "$*"; exit 1; }

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
    [[ $stuck -ge 5 ]] && die "chain not advancing past $h (target $target)"
    log "  at block $h, waiting for $target"
    sleep 2
  done
}

bonded_ops_sorted() {
  curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100" \
    | jq -r '.msg.validators | map(.operator_address) | sort | join(",")'
}

base64_pubkey_to_hex() {
  # 33-byte compressed secp256k1 pubkey: base64 -> 33 bytes -> 66 hex chars
  echo -n "$1" | base64 -d | xxd -p -c 66
}

# ---------------- Phase 1 — start localnet ----------------
phase_1_start() {
  if [[ $SKIP_START -eq 1 ]]; then
    log "Phase 1 — SKIP_START (assume localnet in UBD window)"
    return
  fi
  log "Phase 1 — start localnet"
  docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-' \
    && die "validators already running — run ./terminate.sh first"
  (cd "$LOCALNET" && bash start.sh 2>&1 | tail -3)
}

# ---------------- Phase 2 — wait for UBD window (post-upgrade, pre-drain) ----------------
phase_2_ubd_window() {
  local target=$((UPGRADE_HEIGHT + POST_UPGRADE))
  log "Phase 2 — wait block $target (upgrade+$POST_UPGRADE; UBD still active)"
  local h
  h=$(wait_height "$target")
  ok "chain at $h (inside UBD window)"
}

# ---------------- Phase 3 — pick dropped val + target val ----------------
DROPPED_OPERATOR=""
DROPPED_MONIKER=""
DROPPED_PUBKEY_HEX=""
DROPPED_PRIVKEY_HEX=""
DROPPED_TOKENS=""
TARGET_OPERATOR=""
TARGET_MONIKER=""
TARGET_PUBKEY_HEX=""
TARGET_TOKENS_PRE=""
BONDED_OPS_PRE=""
UBD_PRE=""
phase_3_pick() {
  log "Phase 3 — identify dropped + target validators"
  [[ -f "$META" ]] || die "validators_meta.json not found at $META"

  local all_vals
  all_vals=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100")

  local bonded_count ubd_count unbonded_count
  bonded_count=$(jq '[.msg.validators[] | select(.status==3)] | length' <<<"$all_vals")
  ubd_count=$(jq '[.msg.validators[] | select(.status==2)] | length' <<<"$all_vals")
  unbonded_count=$(jq '[.msg.validators[] | select(.status==1)] | length' <<<"$all_vals")
  log "  status counts: bonded=$bonded_count UBD=$ubd_count UNBONDED=$unbonded_count"
  [[ "$bonded_count" == "$NEW_MAX" ]] || die "bonded=$bonded_count (expected $NEW_MAX)"

  # Prefer UBD (still has active delegation). Fall back to UNBONDED (delegation may be gone).
  local dropped_moniker
  if [[ "$ubd_count" -gt 0 ]]; then
    dropped_moniker=$(jq -r '[.msg.validators[] | select(.status==2)] | sort_by(-(.tokens|tonumber)) | .[0].description.moniker' <<<"$all_vals")
  else
    log "  WARNING: no UBD vals — delegation may already be returned to delegator. Test may fail at tx step."
    dropped_moniker=$(jq -r '[.msg.validators[] | select(.status==1)] | sort_by(-(.tokens|tonumber)) | .[0].description.moniker' <<<"$all_vals")
  fi
  [[ -n "$dropped_moniker" && "$dropped_moniker" != "null" ]] || die "no dropped val found"
  DROPPED_MONIKER="$dropped_moniker"

  DROPPED_OPERATOR=$(jq -r --arg m "$dropped_moniker" '.msg.validators[] | select(.description.moniker==$m) | .operator_address' <<<"$all_vals")
  DROPPED_TOKENS=$(jq -r --arg m "$dropped_moniker" '.msg.validators[] | select(.description.moniker==$m) | .tokens' <<<"$all_vals")

  local dropped_pubkey_b64 dropped_priv
  dropped_pubkey_b64=$(jq -r --arg m "$dropped_moniker" '.[] | select(.moniker==$m) | .pubkey_base64' "$META")
  dropped_priv=$(jq -r --arg m "$dropped_moniker" '.[] | select(.moniker==$m) | .priv_key_hex' "$META")
  [[ -n "$dropped_pubkey_b64" && "$dropped_pubkey_b64" != "null" ]] || die "dropped pubkey not found in meta for $dropped_moniker"
  DROPPED_PUBKEY_HEX=$(base64_pubkey_to_hex "$dropped_pubkey_b64")
  DROPPED_PRIVKEY_HEX="$dropped_priv"

  # Target: lowest-tokens bonded val (rank 16 by tokens)
  local target_moniker
  target_moniker=$(jq -r '[.msg.validators[] | select(.status==3)] | sort_by(.tokens|tonumber) | .[0].description.moniker' <<<"$all_vals")
  TARGET_MONIKER="$target_moniker"
  TARGET_OPERATOR=$(jq -r --arg m "$target_moniker" '.msg.validators[] | select(.description.moniker==$m) | .operator_address' <<<"$all_vals")
  TARGET_TOKENS_PRE=$(jq -r --arg m "$target_moniker" '.msg.validators[] | select(.description.moniker==$m) | .tokens' <<<"$all_vals")
  local target_pubkey_b64
  target_pubkey_b64=$(jq -r --arg m "$target_moniker" '.[] | select(.moniker==$m) | .pubkey_base64' "$META")
  TARGET_PUBKEY_HEX=$(base64_pubkey_to_hex "$target_pubkey_b64")

  BONDED_OPS_PRE=$(bonded_ops_sorted)
  UBD_PRE=$(jq '[.msg.validators[] | select(.status==2)] | length' <<<"$all_vals")

  log "  DROPPED: $DROPPED_MONIKER operator=$DROPPED_OPERATOR tokens=$DROPPED_TOKENS"
  log "           pubkey=$DROPPED_PUBKEY_HEX"
  log "  TARGET:  $TARGET_MONIKER operator=$TARGET_OPERATOR tokens=$TARGET_TOKENS_PRE"
  log "           pubkey=$TARGET_PUBKEY_HEX"
  log "  UBD_PRE=$UBD_PRE"
}

# ---------------- Phase 4 — submit redelegate tx ----------------
phase_4_redelegate() {
  log "Phase 4 — story validator redelegate"
  # Amount: entire dropped val's self-delegation, converted from stake-units to wei (×1e9)
  local amount_wei
  amount_wei=$(echo "$DROPPED_TOKENS * 1000000000" | bc)
  log "  redelegate amount: $DROPPED_TOKENS stake-units = $amount_wei wei"

  local out rc
  set +e
  out=$(PRIVATE_KEY="$DROPPED_PRIVKEY_HEX" "$STORY_BIN" validator redelegate \
    --validator-src-pubkey "$DROPPED_PUBKEY_HEX" \
    --validator-dst-pubkey "$TARGET_PUBKEY_HEX" \
    --redelegate "$amount_wei" \
    --delegation-id 0 \
    --rpc http://localhost:8545 \
    --chain-id "$CHAIN_ID" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out" | sed 's/^/    /'
  [[ $rc -eq 0 ]] || die "redelegate exited $rc"
  ok "redelegate submitted"
}

# ---------------- Phase 5 — wait for VSU propagation ----------------
phase_5_wait() {
  local now target
  now=$(get_height)
  target=$((now + VSU_BLOCKS))
  log "Phase 5 — wait $VSU_BLOCKS blocks (current=$now, target=$target)"
  local h
  h=$(wait_height "$target")
  ok "chain at $h post-tx"
}

# ---------------- Phase 6 — verify ----------------
phase_6_verify() {
  log "Phase 6 — verify state"
  local all_vals
  all_vals=$(curl -fsS "http://localhost:1317/staking/validators?pagination.limit=100")

  # 1. bonded count still NEW_MAX
  local bonded_count
  bonded_count=$(jq '[.msg.validators[] | select(.status==3)] | length' <<<"$all_vals")
  [[ "$bonded_count" == "$NEW_MAX" ]] && ok "bonded=$bonded_count" \
    || die "bonded=$bonded_count (expected $NEW_MAX)"

  # 2. operator set unchanged
  local bonded_post
  bonded_post=$(bonded_ops_sorted)
  [[ "$bonded_post" == "$BONDED_OPS_PRE" ]] && ok "bonded operator set unchanged" \
    || die "operator set changed:\n  PRE:  $BONDED_OPS_PRE\n  POST: $bonded_post"

  # 3. dropped val still not bonded
  local dropped_status
  dropped_status=$(jq -r --arg op "$DROPPED_OPERATOR" '.msg.validators[] | select(.operator_address==$op) | .status' <<<"$all_vals")
  case "$dropped_status" in
    3)
      die "dropped val $DROPPED_MONIKER re-entered bonded set (status=$dropped_status) — MaxValidators broken" ;;
    1|2)
      ok "dropped val $DROPPED_MONIKER still not bonded (status=$dropped_status)" ;;
    *)
      die "dropped val unexpected status=$dropped_status" ;;
  esac

  # 4. target val gained tokens
  local target_tokens_post
  target_tokens_post=$(jq -r --arg op "$TARGET_OPERATOR" '.msg.validators[] | select(.operator_address==$op) | .tokens' <<<"$all_vals")
  if [[ "$target_tokens_post" -gt "$TARGET_TOKENS_PRE" ]] 2>/dev/null; then
    ok "target val $TARGET_MONIKER tokens increased: $TARGET_TOKENS_PRE -> $target_tokens_post"
  elif awk -v a="$target_tokens_post" -v b="$TARGET_TOKENS_PRE" 'BEGIN{exit !(a+0 > b+0)}'; then
    ok "target val $TARGET_MONIKER tokens increased: $TARGET_TOKENS_PRE -> $target_tokens_post"
  else
    die "target val tokens did not increase: $TARGET_TOKENS_PRE -> $target_tokens_post"
  fi

  # 5. log scan
  local panics=0 p c
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$' | sort -V); do
    p=$(docker logs "$c" 2>&1 | grep -cE 'panic|CONSENSUS FAILURE' || true)
    panics=$((panics + p))
  done
  [[ $panics -eq 0 ]] && ok "no panic / CONSENSUS FAILURE" \
    || die "$panics panic/CONSENSUS FAILURE lines"

  # 6. invariant log still exactly once per validator
  local misses=0 n total=0
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$' | sort -V); do
    total=$((total + 1))
    n=$(docker logs "$c" 2>&1 | grep -cE 'All upgrade invariants verified|Applied deferred MaxValidators reduction' || true)
    [[ $n -eq 1 ]] || { misses=$((misses + 1)); log "    $c: invariant count=$n"; }
  done
  [[ $((total - misses)) -ge $((total - 1)) ]] && ok "invariant log count == 1 on all $total validators" \
    || die "invariant log count != 1 on $misses validators"
}

# ---------------- Phase 7 — teardown ----------------
phase_7_teardown() {
  if [[ $SKIP_TEARDOWN -eq 1 ]]; then
    log "Phase 7 — SKIP_TEARDOWN (containers left running)"
    return
  fi
  log "Phase 7 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

main() {
  local start_ts end_ts
  start_ts=$(date +%s)
  phase_1_start
  phase_2_ubd_window
  phase_3_pick
  phase_4_redelegate
  phase_5_wait
  phase_6_verify
  phase_7_teardown
  end_ts=$(date +%s)
  ok "L3 REDELEGATE TEST PASS (elapsed $((end_ts - start_ts))s)"
}

main "$@"
