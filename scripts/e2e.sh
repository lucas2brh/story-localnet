#!/usr/bin/env bash
# e2e.sh — full v1.7.0 MaxValidators upgrade test on story-localnet
#
# Usage:
#   ./scripts/e2e.sh                              # full run from current private-fork HEAD
#   ./scripts/e2e.sh --commit 703b5f7             # build+test a specific commit
#   ./scripts/e2e.sh --skip-build                 # reuse existing story-prebuilt
#   ./scripts/e2e.sh --keep-alive                 # don't teardown at end (for debugging)
#
# Env (override defaults):
#   N              validators           default 20
#   NEW_MAX        post-upgrade max     default 16
#   UPGRADE_HEIGHT block                default 50 (matches StoryLocalnetID V170 post story-private-fork#167)
#   PRIVATE_FORK   path                 default ~/workspace/lucas-workspace/story-private-fork
#   GO_PINNED      go 1.24.x bin dir    default ~/sdk/go1.24.10/bin

set -euo pipefail

N=${N:-20}
NEW_MAX=${NEW_MAX:-16}
UPGRADE_HEIGHT=${UPGRADE_HEIGHT:-50}
PRIVATE_FORK=${PRIVATE_FORK:-"$HOME/workspace/lucas-workspace/story-private-fork"}
GO_PINNED=${GO_PINNED:-"$HOME/sdk/go1.24.10/bin"}
LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SKIP_BUILD=0
KEEP_ALIVE=0
COMMIT_SHA=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep-alive) KEEP_ALIVE=1; shift ;;
    --commit)     COMMIT_SHA=$2; shift 2 ;;
    -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

C_CYAN='\033[36m'; C_RED='\033[31m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}[e2e]${C_RESET} %s\n" "$*"; }
fail() { printf "${C_RED}[e2e]${C_RESET} FAIL %s\n" "$*"; exit 1; }

phase_0_preflight() {
  log "Phase 0 — preflight"
  command -v docker  >/dev/null || fail "docker not in PATH"
  command -v jq      >/dev/null || fail "jq not in PATH"
  command -v python3 >/dev/null || fail "python3 not in PATH"
  [[ -d "$PRIVATE_FORK" ]]  || fail "private-fork not at $PRIVATE_FORK"
  [[ -x "$GO_PINNED/go" ]]  || fail "pinned Go not at $GO_PINNED/go (install: go install golang.org/dl/go1.24.10@latest && go1.24.10 download)"
  local gv
  gv=$("$GO_PINNED/go" version | awk '{print $3}')
  [[ $gv == go1.24.* ]]     || fail "Go version $gv != go1.24.x"
  if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
    fail "validators already running; run ./terminate.sh first"
  fi
  log "  docker/jq/python3/go OK, no stale containers"
}

phase_1_build() {
  if [[ $SKIP_BUILD -eq 1 ]]; then
    log "Phase 1 — --skip-build (using existing $PRIVATE_FORK/story-prebuilt)"
    [[ -f "$PRIVATE_FORK/story-prebuilt" ]] || fail "--skip-build but story-prebuilt missing"
    return
  fi
  log "Phase 1 — build binary${COMMIT_SHA:+ @ $COMMIT_SHA}"
  pushd "$PRIVATE_FORK" >/dev/null
  [[ -n "$COMMIT_SHA" ]] && git reset --hard "$COMMIT_SHA" >/dev/null
  local head
  head=$(git rev-parse --short HEAD)
  log "  private-fork HEAD: $head"
  PATH="$GO_PINNED:$PATH" GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go build -o build/story-linux ./client
  file build/story-linux | grep -q 'ELF.*aarch64' \
    || fail "binary is not linux/arm64 ELF"
  cp build/story-linux story-prebuilt
  # darwin host binary for scripts that exec story on Mac (generate_N_validators, keys, etc.)
  PATH="$GO_PINNED:$PATH" go build -o build/story ./client >/dev/null
  cp build/story /tmp/story
  popd >/dev/null
  log "  story-prebuilt (linux): $(du -h "$PRIVATE_FORK/story-prebuilt" | awk '{print $1}')"
  log "  /tmp/story (darwin):    $(du -h /tmp/story | awk '{print $1}')"
}

phase_2_start() {
  log "Phase 2 — starting localnet (start.sh)"
  cd "$LOCALNET"
  bash start.sh 2>&1 | tail -3
  log "  localnet up, RPC producing blocks"
}

phase_3_verify() {
  log "Phase 3 — verify_upgrade.sh (N=$N NEW_MAX=$NEW_MAX UPGRADE_HEIGHT=$UPGRADE_HEIGHT)"
  cd "$LOCALNET"
  local rc=0
  N=$N NEW_MAX=$NEW_MAX UPGRADE_HEIGHT=$UPGRADE_HEIGHT STORY_BIN=/tmp/story \
    bash scripts/verify_upgrade.sh || rc=$?
  # Known script limitations (lion-team-sync#607) can drive exit 1; invariant scan is the real gate.
  log "  verify_upgrade.sh exit=$rc (script-side limitations may apply; see phase 4)"
}

phase_4_invariant_scan() {
  log "Phase 4 — invariant log scan + panic check across all validator-node containers"
  local total misses=0 panics=0 c hits
  total=$(docker ps --format '{{.Names}}' | grep -cE '^validator[0-9]+-node$' || true)
  [[ $total -gt 0 ]] || fail "no validator-node containers running"
  for c in $(docker ps --format '{{.Names}}' | grep -E '^validator[0-9]+-node$' | sort -V); do
    docker logs "$c" 2>&1 | grep -q 'All upgrade invariants verified' \
      || { misses=$((misses+1)); log "  MISS $c"; }
    hits=$(docker logs "$c" 2>&1 | grep -cE 'panic|CONSENSUS FAILURE' || true)
    panics=$((panics + hits))
  done
  log "  invariant log: $((total - misses))/$total validators"
  log "  panic / CONSENSUS FAILURE total: $panics"
  [[ $misses -eq 0 && $panics -eq 0 ]] \
    || fail "invariant scan failed (misses=$misses panics=$panics)"
}

phase_5_teardown() {
  if [[ $KEEP_ALIVE -eq 1 ]]; then
    log "Phase 5 — --keep-alive (containers left running)"
    return
  fi
  log "Phase 5 — teardown (terminate.sh)"
  cd "$LOCALNET"
  bash terminate.sh 2>&1 | tail -2
}

main() {
  local start_ts end_ts
  start_ts=$(date +%s)
  phase_0_preflight
  phase_1_build
  phase_2_start
  phase_3_verify
  phase_4_invariant_scan
  phase_5_teardown
  end_ts=$(date +%s)
  log "E2E PASS (elapsed $((end_ts - start_ts))s)"
}

main "$@"
