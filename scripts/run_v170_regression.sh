#!/usr/bin/env bash
# Sequential regression sweep for v1.7.0 Hans-fix verification.
# bash 3.2 compatible (no associative arrays).
# Each probe self-contained (start/stop). Fail-stop on first non-zero exit.

set -u
LOCALNET=/Users/lucas/workspace/lucas-workspace/story-localnet
EVIDENCE=/Users/lucas/workspace/lucas-workspace/docs/test-evidence/v170-hans-fix-2026-04-27
mkdir -p "$EVIDENCE"

# Pre-teardown stale cluster
if docker ps --format '{{.Names}}' | grep -qE '^validator[0-9]+-'; then
  echo "=== Pre-teardown stale cluster ==="
  (cd "$LOCALNET" && bash terminate.sh 2>&1 | tail -3)
  sleep 5
fi

cd "$LOCALNET"

# Force regen genesis with MAX_VALIDATORS_INIT=20 (pre-upgrade baseline). e2e.sh
# itself does not regen — it assumes genesis is in pre-upgrade state. If a previous
# run (e.g. interrupted idempotent.sh) left the genesis with max_validators=16,
# verify_upgrade.sh would silently see post-upgrade state at block 5 and the
# upgrade EndBlock at block 50 would be a no-op (no val_updates, no log).
echo "=== Reset genesis to MAX_VALIDATORS_INIT=20 (pre-upgrade baseline) ==="
MAX_VALIDATORS_INIT=20 STORY_BIN=/tmp/story bash scripts/assemble_genesis.sh 20 2>&1 | tail -1

PASSED=""

run_probe() {
  local name=$1; shift
  local log="$EVIDENCE/${name%.sh}.log"
  echo
  echo "==================== $name ===================="
  echo "Start: $(date -u +%H:%M:%S) UTC"
  bash "$@" 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  echo "End:   $(date -u +%H:%M:%S) UTC  rc=$status"
  if [ "$status" -ne 0 ]; then
    echo
    echo "=== FAIL: $name — leaving cluster up for debug ==="
    echo "Passed before fail:$PASSED"
    exit 1
  fi
  PASSED="$PASSED $name"
}

# Only the not-yet-verified probes. verify_upgrade.sh / tie / new_val already
# PASSED in round 3 against the same Hans binary commit 22354e1; re-running
# them is wasted time. If the binary is rebuilt or Hans pushes new code, all
# probes must be re-enabled.

# L4 idempotent (genesis already at NEW_MAX)
run_probe verify_upgrade_idempotent.sh scripts/verify_upgrade_idempotent.sh

# L6 restart across upgrade height
run_probe verify_upgrade_restart.sh scripts/verify_upgrade_restart.sh

echo
echo "==================== ALL REGRESSION PASS ===================="
echo "Passed:$PASSED"
