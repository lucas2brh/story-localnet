# v1.7.0 MaxValidators Reduction — QA Runbook

**Goal**: verify that the v1.7.0 fix in `piplabs/story-private-fork@hans/v1.7.0-max-validators-v2` (commit `57e597c`, 2026-04-25) correctly reduces `MaxValidators` from 80 to 16 without halting the chain.

This branch (`piplabs/story-localnet@lucas/probe-jail-active`) carries the full probe suite. Run from this branch.

## 0. Background

The pre-fix v1.7.0 handler discarded the `[]abci.ValidatorUpdate` returned by `ApplyAndReturnValidatorSetUpdates`. CometBFT therefore kept all 80 validators in its vote set while `x/staking` had pruned to 16. A later `RemoveValidator` (e.g. on a single-delegator UNBONDED pruned validator self-unstaking 100%) then triggered a chain-wide `CONSENSUS FAILURE` in `x/distribution.AllocateTokens`.

Hans's fix defers the `MaxValidators` change from the upgrade handler (PreBlocker) to `evmstaking.EndBlock`, mirroring the standard cosmos-sdk `gov.EndBlocker → staking.EndBlocker` flow. ABCI updates flow through the normal EndBlock return path; CometBFT and `x/staking` stay in sync.

Full bug analysis, fix-option comparison, and forensic evidence: `lucas-workspace:docs/plans/v1.7.0-chain-halt-sot.md` (commit `f378794`).

## 1. Binary build

```bash
# story-private-fork
git remote add origin git@github.com:piplabs/story-private-fork.git    # if not already
git fetch origin hans/v1.7.0-max-validators-v2
git checkout -b yao/v170-test-hans-fix origin/hans/v1.7.0-max-validators-v2

# Localnet height override: lower Horace 100→20 and V170 200→50 so each
# upgrade cycle finishes in ~80 blocks instead of ~230. Localnet-only;
# AeneidChainID and StoryChainID heights untouched.
git fetch origin abc4de4                                                # commit on yao/v170-chain-halt-poc
git cherry-pick abc4de4

make build
cp $(pwd)/client/story /tmp/story
/tmp/story version    # expect: 1.7.0-...
```

Result: `/tmp/story` is the binary every probe defaults to (`STORY_BIN`).

## 2. Probe sequence

Run in this order. All probes are idempotent — they regenerate genesis from `distribution_mainnet_snapshot.json`, start a fresh 20-validator localnet, run the assertion, and tear down (unless `SKIP_TEARDOWN=1`).

| # | Probe | What it verifies | Expected | Time |
|---|---|---|---|---|
| 1 | `scripts/poc_chain_halt_unstake.sh EXPECT=progress` | Minimal halt-path sanity (single-del 100% self-unstake on pruned val-17 → no halt) | exit 0 | ~5 min |
| 2 | `scripts/probe_unstake_pruned_val.sh` | Case A (val-17 single-del, 100% self-unstake) AND Case B (val-18 ext-del, 100% self-unstake) on the same localnet | both Case A and Case B "OBSERVATION MATCHES" | ~6 min |
| 3 | `scripts/verify_upgrade.sh` | General upgrade-block assertions: `bonded_count==16`, `MaxValidators==16` post-upgrade, EVM balances credited, chain liveness past block 80 | "ALL ASSERTIONS PASS" | ~5 min |
| 4 | `scripts/verify_upgrade_tie.sh` | L1 — power tie at rank 16/17, deterministic prune across all 20 nodes | "ALL ASSERTIONS PASS", no halt | ~5 min |
| 5 | `scripts/verify_upgrade_new_val.sh` | L2 — `MsgCreateValidator` post-upgrade displaces current rank-16 | new val bonded, old rank-16 unbonded, count stays 16 | ~6 min |
| 6 | `scripts/verify_upgrade_idempotent.sh` | L4 — genesis already at `MaxValidators=16`, V170 EndBlock should be a no-op (no UBD entries created) | "ALL ASSERTIONS PASS" | ~5 min |
| 7 | `scripts/verify_upgrade_restart.sh` | L6 — pruned state survives `docker stop` + `docker start` | "ALL ASSERTIONS PASS", chain resumes past block 80 | ~6 min |
| 8 | `scripts/verify_upgrade_redelegate.sh` | L3 — redelegate from dropped val to top-16 during UBD window. Note: L3 root cause is cosmos-sdk `BeginRedelegation` (issue #619), unaffected by Hans's fix; symptoms are expected to remain. | symptom unchanged from pre-fix run | ~5 min |

Total wall-clock for full pass: ~45 min.

Each script's header documents env var overrides (`UPGRADE_HEIGHT`, `NEW_MAX`, `SKIP_START`, `SKIP_TEARDOWN`, `STORY_BIN`).

## 3. Hans-fix-specific assertions (manual, one-time)

These check the claimed advantage of the EndBlock-deferred approach over the rejected PreBlocker queue (Option B). Run after probe #1 has produced a clean upgrade block.

```bash
UPGRADE_HEIGHT=50

# (a) HistoricalInfo at upgrade block records the OLD validator set (80)
docker compose -f docker-compose-validator1.yml exec story-rpc1 \
  story query staking historical-info $UPGRADE_HEIGHT --output json \
  | jq '.hist.valset | length'
# expect: 80   (CometBFT block N was signed by 80 vals; HistoricalInfo[N] should match)

# (b) HistoricalInfo at upgrade_height+1 records the new validator set (16)
docker compose -f docker-compose-validator1.yml exec story-rpc1 \
  story query staking historical-info $((UPGRADE_HEIGHT+1)) --output json \
  | jq '.hist.valset | length'
# expect: 16

# (c) Upgrade block ABCI return contains 4 val_updates (4 pruned vals to power=0)
docker logs story-localnet-validator1 2>&1 \
  | grep -E "block.*$UPGRADE_HEIGHT.*val_updates|num_val_updates" \
  | head
# expect: val_updates count = 4
```

If (a) returns 16 instead of 80, Hans's accuracy claim is broken — escalate before signing off.

## 4. Pass/fail rollup

A clean run requires all 8 probes exit 0 AND the 3 manual assertions in §3 produce expected counts. If anything fails, capture the full container log set (`docker logs` for all 20 vals + rpc1) into `/tmp/v170_qa_<timestamp>/` and link in the team Slack thread before re-running.

## 5. References

- Halt-fix decision SoT: `lucas-workspace:docs/plans/v1.7.0-chain-halt-sot.md` (commit `f378794`)
- L3 redelegate (separate bug, #619) SoT: `lucas-workspace:docs/plans/v1.7.0-redelegate-bug-sot.md` (commit `ff0356d`)
- Tracking issue: `piplabs/lion-team-sync#626`
- Hans's design discussion: Slack channel `#val-reduction-review` (C0B03QXGGKT)
