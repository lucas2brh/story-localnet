# v1.7.0 prune — multi-delegator locked + unlocked val recovery probe

Date: 2026-04-30 (run 11:33 local)
Cluster: 20-val docker-compose localnet
Binary: `/tmp/story` (`yao/v170-test-hans-fix`, commit `22354e1` — `chore(localnet): lower Horace/V170 heights for faster iteration`)
Probe: `lucas2brh/story-localnet@1977c98 scripts/probe_multidel_locked_unlocked_after_prune.sh`

## Setup

Genesis modifications:
- `UNLOCKED_VALS=17` → val-17 has `support_token_type=1` (UNLOCKED, allows all 4 staking periods); val-18..20 default to `support_token_type=0` (LOCKED, only flexible delegations)
- Period 3 duration 900s → 180s (committed `lucas2brh/story-localnet@452df3d`) for tractable wallclock

5 stakes pre-upgrade:

| Delegator | Anvil idx | EVM addr | Val | Period | Delegation ID |
|---|---|---|---|---|---|
| Alice | 0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | val-17 (UNLOCKED) | flexible | 0 |
| Bob | 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | val-17 (UNLOCKED) | short (60s) | 1 |
| Carol | 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | val-17 (UNLOCKED) | medium (120s) | 2 |
| Dave | 3 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` | val-17 (UNLOCKED) | long (180s) | 3 |
| Alice | 0 | (same) | val-18 (LOCKED) | flexible | 0 |

Each stake = 1024 IP. val-17 received +4096e9 stake delta (4×1024 IP), val-18 received +1024e9. **Phase 2 token-delta assertion verified all 5 stakes truly committed on chain** (no silent CLI failure).

## Verifiable claims (grep against `probe_run.log` and `cl-validator17-node-*.log`)

### Setup PASS
```
probe_run.log: PASS baseline + seed complete
probe_run.log: PASS 5 stakes committed (val-17 +4096000000000, val-18 +1024000000000), multi-del shape verified
```

### V170 prune PASS
```
probe_run.log: val-17 post-upgrade status=1
probe_run.log: val-18 post-upgrade status=1
probe_run.log: PASS both vals pruned to UNBONDED carrying multi-del shape
```

### Operator self-unstake PASS (both vals jailed)
```
probe_run.log:   localnet-val-17 post-self-unstake: status=1 jailed=true tokens=4096000000000
probe_run.log:   localnet-val-18 post-self-unstake: status=1 jailed=true tokens=1024000000000
probe_run.log: PASS both operators self-unstaked, both vals jailed + UNBONDED with ext dels retained
```

### Phase 5 — probe-self-bug + chain-side reality

Probe issued `validator unstake --delegation-id 0` for Alice, Bob, Carol on val-17.
- Alice's actual id is 0 → unstake processed correctly
- Bob's actual id is 1, Carol's is 2 → unstake call with id=0 hits a non-existent delegation
- CLI returns `Tokens unstaked successfully` rc=0 for all 3 (probe Phase 5 PASS)

But chain log `cl-validator17-node-05-short-locks-unstake.log` shows only 1 new `Undelegate Info`:
```
03:37:13 delegator_addr=story17w0adeg64ky0daxwd2ugyuneellmjgnxpupef6 ... period_delegation_id=0 token_amount=1024000000000
```

This is Alice. Bob's and Carol's unstake calls produced no `Undelegate Info` entries on chain. Their tokens remain in val-17.

### Phase 7 — Dave (id=0 too, also no-op on chain)

Same shape: probe issues `--delegation-id 0` for Dave. Chain doesn't process. Dave's 1024 IP remains in val-17.

### Manual retry after probe finished — Carol with correct delegation-id=2

Carol's stake EVM tx assigned id=2 (verbatim from probe stdout: `Delegation ID: 2`). Manually retried unstake with id=2 against still-running cluster. Chain log evidence captured to `carol-id2-retry-chain-log.txt`:

```
26-04-30 06:04:25 DEBU Processing EVM staking withdraw
  del_story=story183zvmhdk4yq0526cthffncpaztay9yaueh0jcz
  val_story=storyvaloper1l07twgekk6armd5k5sxtkrkkapp38tmvhsf9zx
  del_evm_addr=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
  val_evm_addr=0xFbFcB72336b6ba3Db696A40cBB0eD6e84313af6c
  amount=1024000000000

26-04-30 06:04:25 DEBU Undelegate Info  module=x/staking
  delegator_addr=story183zvmhdk4yq0526cthffncpaztay9yaueh0jcz
  validator_addr=storyvaloper1l07twgekk6armd5k5sxtkrkkapp38tmvhsf9zx
  period_delegation_id=2 token_amount=1024000000000
```

val-17.tokens went from 2048e9 → 1024e9 (Carol's 1024 IP correctly debited from val record).

**But Carol's EVM balance change was −1.001 IP (gas only), not +1024 IP.**

```
Carol EVM bal pre-retry  = 975.064 IP
Carol EVM bal post-retry = 974.063 IP (after 15s for unbonding mature)
delta = -1.001569 IP (gas only)
```

The 1024 IP debited from staking module was not credited to Carol's EVM address.

(Bob with id=1 was tested similarly earlier in the session, same outcome; chain log for that test was rotated out of docker logs by the time evidence was staged.)

## Bug findings (filed as piplabs/lion-team-sync#681)

**Bug 1 — Locked-period delegators stranded on jailed-pruned UNLOCKED val.** Even with correct delegation-id, the unstake at chain layer (Undelegate Info + val.tokens decrease + Processing EVM staking withdraw) does not result in EVM credit to the delegator. Tokens are debited from val record but never reach delegator's EVM address.

**Bug 2 — CLI silent failure on wrong delegation-id.** `validator unstake --delegation-id N` against a non-existent delegation reports `Tokens unstaked successfully` rc=0 with no chain action. User cannot distinguish from a real success.

## Final on-chain state

```json
val-17 (UNLOCKED, was 4-del shape):
  status=1 jailed=true tokens=2048000000000 shares=2048000000000
  → Carol (id=2) + Dave (id=3) still stranded, 2x 1024 IP unrecovered

val-18 (LOCKED, 1-del Alice flex):
  GONE (RemoveValidator after Alice's unstake drove shares=0)
```

Bob (id=1) was manually retried after probe; his tokens still didn't reach EVM despite correct id. Carol/Dave were not retried — the chain bug is the same path so retry would not change outcome.

## NOT claimed

- Same scenario on aeneid/mainnet not verified (this is localnet only)
- Tested only with v170-test-hans-fix binary; reproducibility on fully released v1.7.0 binary unverified
- The exact code path that drops the EVM credit (evmstaking module's `processWithdrawal → MintCoins → SendCoinsToEVM`) is hypothesized but not source-traced

## Files

- `probe_run.log` — full probe stdout
- `cl-{bootnode1,validator17,validator18}-node-*-*.log` — filtered Cosmos consensus / staking / evmstaking events per phase
- `el-{validator17,validator18,rpc1}-geth-*-*.log` — geth chain head + payload events per phase
- `health-*.log` — panic/CONSENSUS FAILURE scan across all val-nodes (all clean)
- `final-localnet-val-17.json`, `final-localnet-val-18.json` — final on-chain snapshots
