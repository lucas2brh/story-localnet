#!/usr/bin/env bash
# verify_upgrade_new_val.sh — L2 test: MsgCreateValidator (via IPTokenStaking
# EVM predeploy) after v1.7.0 activation. Expects new validator to enter
# bonded set and displace current rank-16, keeping bonded count at NEW_MAX.
#
# Usage:
#   ./scripts/verify_upgrade_new_val.sh                       # full run
#   SKIP_START=1 ./scripts/verify_upgrade_new_val.sh          # localnet already up
#   SKIP_TEARDOWN=1 ./scripts/verify_upgrade_new_val.sh       # keep containers for debug
#
# Env:
#   N                validators           default 20
#   NEW_MAX          post-upgrade max     default 16
#   UPGRADE_HEIGHT   block                default 50
#   POST_UPGRADE     blocks past upgrade  default 10 (wait window before create-val)
#   VSU_BLOCKS       blocks after tx      default 10 (wait for validator-set update)
#   STAKE_MARGIN     numerator/10         default 12 (=> stake = rank16 * 1.2)
#   WEI_PER_STAKE    wei per stake unit   default 1000000000 (1e9; Story IP→stake ratio)
#   STORY_BIN        host story binary    default /tmp/story
#   ANVIL_PK         EVM signer (no 0x)   default Anvil #0 (well-known test key)
#   CHAIN_ID         EVM chainId          default 1399 (localnet genesis-geth.json)
#
# Exits 0 if new validator replaces rank-16 and bonded stays at NEW_MAX.

set -euo pipefail

N=${N:-20}
NEW_MAX=${NEW_MAX:-16}
UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
POST_UPGRADE=${POST_UPGRADE:-10}
VSU_BLOCKS=${VSU_BLOCKS:-10}
STAKE_MARGIN=${STAKE_MARGIN:-12}
WEI_PER_STAKE=${WEI_PER_STAKE:-1000000000}
STORY_BIN=${STORY_BIN:-/tmp/story}
ANVIL_PK=${ANVIL_PK:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
CHAIN_ID=${CHAIN_ID:-1399}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAL21_HOME=/tmp/val21-home
VAL21_KEY="${VAL21_HOME}/config/priv_validator_key.json"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[newval]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[newval]${C_RESET} PASS %s\n" "$*"; }
die()  { printf "${C_RED}[newval]${C_RESET} FAIL %s\n" "$*"; exit 1; }

SKIP_START=${SKIP_START:-0}
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}

# ---------------- Phase 0 — generate val-21 CometBFT key ----------------
phase_0_keygen() {
  log "Phase 0 — generate val-21 CometBFT key at $VAL21_KEY"
  rm -rf "$VAL21_HOME"
  mkdir -p "${VAL21_HOME}/config"
  PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" key gen-priv-key-json \
    --home "$VAL21_HOME" \
    --keyfile "$VAL21_KEY" \
    >/dev/null 2>&1 || die "gen-priv-key-json failed"
  [[ -f "$VAL21_KEY" ]] || die "keyfile not created at $VAL21_KEY"
  local pubkey
  pubkey=$(jq -r '.pub_key.value' "$VAL21_KEY")
  log "  pub_key=$pubkey"
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
    [[ $stuck -ge 5 ]] && die "chain HALTED at block $h (5 polls unchanged)"
    log "  at block $h, waiting for $target"
    sleep 10
  done
}

# ---------------- Phase 2 — wait for post-upgrade window ----------------
phase_2_post_upgrade() {
  local target=$((UPGRADE_HEIGHT + POST_UPGRADE))
  log "Phase 2 — wait for block $target (upgrade+$POST_UPGRADE)"
  local h
  h=$(wait_height "$target")
  ok "chain advanced to $h"
}

# ---------------- Phase 3 — record rank-16 baseline ----------------
RANK16_OPERATOR=""
RANK16_TOKENS=""
STAKE_WEI=""
phase_3_baseline() {
  log "Phase 3 — record current rank-16 baseline"
  local vals
  vals=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100")
  local count
  count=$(jq '.msg.validators | length' <<<"$vals")
  [[ "$count" == "$NEW_MAX" ]] || die "bonded=$count (expected $NEW_MAX post-upgrade)"

  RANK16_OPERATOR=$(jq -r '.msg.validators | sort_by(-(.tokens|tonumber)) | .[15].operator_address' <<<"$vals")
  RANK16_TOKENS=$(jq -r '.msg.validators | sort_by(-(.tokens|tonumber)) | .[15].tokens' <<<"$vals")
  # Stake (wei IP) = rank16_tokens * STAKE_MARGIN/10 * WEI_PER_STAKE.
  # Use bc — bash ints overflow and awk doubles lose precision past ~15 digits.
  STAKE_WEI=$(echo "$RANK16_TOKENS * $STAKE_MARGIN / 10 * $WEI_PER_STAKE" | bc)
  log "  rank-16 operator=$RANK16_OPERATOR"
  log "  rank-16 tokens  =$RANK16_TOKENS (stake units)"
  log "  val-21 stake    =$STAKE_WEI wei (${STAKE_MARGIN}0% of rank-16 × ${WEI_PER_STAKE} wei/stake)"
}

# ---------------- Phase 4 — submit create-validator tx ----------------
phase_4_create_val() {
  log "Phase 4 — story validator create for val-21"
  local out rc
  set +e
  out=$(PRIVATE_KEY="$ANVIL_PK" "$STORY_BIN" validator create \
    --keyfile "$VAL21_KEY" \
    --rpc http://localhost:8545 \
    --chain-id "$CHAIN_ID" \
    --stake "$STAKE_WEI" \
    --moniker localnet-val-21 \
    --unlocked 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out" | sed 's/^/    /'
  [[ $rc -eq 0 ]] || die "validator create exited $rc"
  ok "validator create submitted"
}

# ---------------- Phase 5 — wait for VSU propagation ----------------
phase_5_vsu() {
  local now target
  now=$(get_height)
  target=$((now + VSU_BLOCKS))
  log "Phase 5 — wait $VSU_BLOCKS blocks for VSU (current=$now, target=$target)"
  local h
  h=$(wait_height "$target")
  ok "chain advanced to $h after tx"
}

# ---------------- Phase 6 — verify replacement ----------------
phase_6_verify() {
  log "Phase 6 — verify val-21 in bonded set, old rank-16 kicked"
  local bonded_json bonded_count val21_status rank16_status
  bonded_json=$(curl -fsS "http://localhost:1317/staking/validators?status=BOND_STATUS_BONDED&pagination.limit=100")
  bonded_count=$(jq '.msg.validators | length' <<<"$bonded_json")
  [[ "$bonded_count" == "$NEW_MAX" ]] && ok "bonded=$bonded_count" \
    || die "bonded=$bonded_count (expected $NEW_MAX, must never exceed)"

  # val-21 presence — match by moniker
  val21_status=$(jq -r '.msg.validators[] | select(.description.moniker=="localnet-val-21") | .status' <<<"$bonded_json")
  [[ -n "$val21_status" ]] && ok "val-21 in bonded set (status=$val21_status)" \
    || die "val-21 not in bonded set after $VSU_BLOCKS blocks"

  # old rank-16 status — pull across all statuses
  rank16_status=$(curl -fsS "http://localhost:1317/staking/validators/${RANK16_OPERATOR}" \
    | jq -r '.msg.validator.status')
  case "$rank16_status" in
    BOND_STATUS_UNBONDING|BOND_STATUS_UNBONDED|1|2)
      ok "old rank-16 kicked (status=$rank16_status)" ;;
    BOND_STATUS_BONDED|3)
      die "old rank-16 still bonded (status=$rank16_status) — displacement failed" ;;
    *)
      die "old rank-16 unexpected status=$rank16_status" ;;
  esac

  log "  top validators around boundary (sorted by tokens):"
  jq -r '.msg.validators | sort_by(-(.tokens|tonumber)) | .[14:18][] | "    \(.description.moniker)  status=\(.status)  tokens=\(.tokens)  operator=\(.operator_address)"' <<<"$bonded_json"
}

# ---------------- Phase 7 — invariant log + panic scan ----------------
phase_7_log_scan() {
  log "Phase 7 — invariant log + panic scan"
  local total misses=0 panics=0 c n p
  total=$(docker ps --format '{{.Names}}' | grep -cE '^validator[0-9]+-node$' || true)
  [[ $total -gt 0 ]] || die "no validator-node containers"
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$' | sort -V); do
    n=$(docker logs "$c" 2>&1 | grep -cE 'All upgrade invariants verified|Applied deferred MaxValidators reduction' || true)
    [[ $n -eq 0 ]] && { misses=$((misses + 1)); log "    MISS $c"; }
    p=$(docker logs "$c" 2>&1 | grep -cE 'panic|CONSENSUS FAILURE' || true)
    panics=$((panics + p))
  done
  [[ $((total - misses)) -ge $((total - 1)) ]] && ok "invariant log on all $total validators" \
    || die "invariant log missing on $misses validators"
  [[ $panics -eq 0 ]] && ok "no panic / CONSENSUS FAILURE" \
    || die "$panics panic/CONSENSUS FAILURE lines"
}

# ---------------- Phase 8 — teardown ----------------
phase_8_teardown() {
  if [[ $SKIP_TEARDOWN -eq 1 ]]; then
    log "Phase 8 — SKIP_TEARDOWN (containers left running)"
    return
  fi
  log "Phase 8 — teardown"
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -2)
}

main() {
  local start_ts end_ts
  start_ts=$(date +%s)
  phase_0_keygen
  phase_1_start
  phase_2_post_upgrade
  phase_3_baseline
  phase_4_create_val
  phase_5_vsu
  phase_6_verify
  phase_7_log_scan
  phase_8_teardown
  end_ts=$(date +%s)
  ok "L2 NEW-VAL TEST PASS (elapsed $((end_ts - start_ts))s)"
}

main "$@"
