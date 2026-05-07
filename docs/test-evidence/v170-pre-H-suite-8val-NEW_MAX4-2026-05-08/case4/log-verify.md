# Probe 4 — CL/EL log evidence verification

**Probe**: `probe_pre_upgrade_external_del_unstake.sh` (expanded with Phase 2b for Raul Case 4 strict)
**Run**: 2026-05-08
**Binary**: [[yao-v170-maxval-4-localnet-rev3]] sha256=`d320c17e...` (NewMaxValidators=4, V170=70 on `StoryLocalnetID`)
**Cluster**: 8-val localnet
**Probe stdout**: `probe-run-expanded.log` (self-reported, NOT authoritative)
**Canonical chain log**: `cl-validator1-node.log` (consensus layer; all 8 vals see identical chain state, val-1 chosen as reference)
**REST queries**: `final-state.txt` (post-probe staking module state)

This doc maps each PASS claim from the probe stdout to its **CL log evidence** (line citation in `cl-validator1-node.log`) or REST evidence (`final-state.txt`). The line refs are immutable for this run; full log is retained for cross-check, slices in `events/` are pre-grep'd subsets.

---

## Pre-V170 setup phase

### Claim P1: Genesis 8 validators bonded
- **Probe assert**: implicit (probe assumes 8 vals start BONDED)
- **CL log evidence**: [`events/00-genesis-8-vals-bonded.txt`](events/00-genesis-8-vals-bonded.txt) — 8 hits of `📚 Validator bonded` at L84-91 (cl-validator1-node.log @ 07:06:49.341-342)
- **Status**: ✓ chain-asserted

### Claim P2: Phase 2 — Anvil delegates 2048 IP to val-7 PRE-V170
- **Probe assert**: `PASS external delegation injected pre-upgrade, val still BONDED`
- **CL log evidence**: [`events/phase2-anvil-stake-val7.txt`](events/phase2-anvil-stake-val7.txt) — L607 (07:07:29.828): `📚 Delegation created acc_addr=F39FD6...(Anvil) val_addr=265A3C...(val-7)`
- **Status**: ✓ chain-asserted

### Claim P3 (NEW Phase 2b — Raul Case 4 strict setup): Anvil delegates 2048 IP to val-8 PRE-V170
- **Probe assert**: implicit (in Phase 2b log line `Anvil delegated 2048 IP → val-8`)
- **CL log evidence**: [`events/phase2b-anvil-stake-val8.txt`](events/phase2b-anvil-stake-val8.txt) — L868 (07:07:47.339): `📚 Delegation created acc_addr=F39FD6...(Anvil) val_addr=27D632...(val-8)`
- **Status**: ✓ chain-asserted

### **★ Claim P4 (NEW Phase 2b — Raul Case 4 strict CORE): Anvil 100% UNSTAKES from val-8 BEFORE H**
- **Probe assert**: `PASS Raul Case 4 strict pre-V170: Anvil 100% unstaked from localnet-val-8, val still BONDED + not jailed (operator self-del intact)`
- **CL log evidence**: [`events/phase2b-anvil-unstake-val8-preH.txt`](events/phase2b-anvil-unstake-val8-preH.txt) — L1041 (07:07:59.005): `📚 Delegation removed acc_addr=F39FD6...(Anvil) val_addr=27D632...(val-8)`
- **Timing**: 07:07:59 — well before V170 fire at 07:10:16 (h=70). This is the pre-H delegator preemptive undelegate that strictly maps to Raul Case 4.
- **Status**: ✓ **chain-asserted (this is the new evidence that didn't exist on this probe before)**

---

## V170 fire phase

### Claim V1: V170 upgrade fires at h=70
- **Probe assert**: implicit (probe waits past V170 in Phase 3)
- **CL log evidence**: [`events/phase3-v170-fire-h70.txt`](events/phase3-v170-fire-h70.txt) — L3055-3100 (07:10:16):
  - L3055: `ABCI call: FinalizeBlock height=70`
  - L3096: `ABCI response: FinalizeBlock val_updates=4 height=70 pubkey_0=03cdfc8 power_0=0 pubkey_1=03c95a4 power_1=0 pubkey_2=022fae6 power_2=0 pubkey_3=03da35d power_3=0` — **4 vals removed from active set, powers all 0**
  - L3098-3100: `prune start/end height=70`
- **Status**: ✓ chain-asserted

### Claim V2: lib sanity — `params.max_validators == 4`
- **Probe assert**: `PASS binary↔probe consistent: staking/params.max_validators = 4 == NEW_MAX`
- **REST evidence**: `final-state.txt` line 3: `{"max_validators":4}`
- **Status**: ✓ REST chain-asserted (probe queries `/staking/params` and asserts equality)

### Claim V3: val-5..8 BONDED→UNBONDING at V170 (4 prunes)
- **Probe assert**: `PASS pruned vals (val-5..8) all in status ∈ {1,2} post-V170`
- **CL log evidence**: 4 slices, each L3066-3070 (07:10:16):
  - val-5: [`events/phase3-prune-val5-begin-unbonding.txt`](events/phase3-prune-val5-begin-unbonding.txt) — L3066
  - val-6: [`events/phase3-prune-val6-begin-unbonding.txt`](events/phase3-prune-val6-begin-unbonding.txt)
  - val-7: [`events/phase3-prune-val7-begin-unbonding.txt`](events/phase3-prune-val7-begin-unbonding.txt)
  - val-8: [`events/phase3-prune-val8-begin-unbonding.txt`](events/phase3-prune-val8-begin-unbonding.txt) — L3070
- **Status**: ✓ chain-asserted (4 distinct `📚 Validator begin unbonding` events at h=70)

### Claim V4: val-1..4 stay BONDED post-V170
- **Probe assert**: `PASS bonded vals (val-1..4) all in status=3 post-V170`
- **CL log evidence**: 4 slices, all show "(no matches — claim not supported by log evidence)" — meaning no `Validator begin unbonding` event for val-1..4. Absence of unbonding event = stays BONDED.
  - val-1: [`events/phase3-bonded-val1-no-unbonding.txt`](events/phase3-bonded-val1-no-unbonding.txt)
  - val-2: [`events/phase3-bonded-val2-no-unbonding.txt`](events/phase3-bonded-val2-no-unbonding.txt)
  - val-3: [`events/phase3-bonded-val3-no-unbonding.txt`](events/phase3-bonded-val3-no-unbonding.txt)
  - val-4: [`events/phase3-bonded-val4-no-unbonding.txt`](events/phase3-bonded-val4-no-unbonding.txt)
- **Status**: ✓ chain-asserted by **absence** of unbonding event (combined with V1's `val_updates=4 power=0` showing only 4 vals pruned)

### Claim V5: Raul Case 4 strict carry-through (val-8 reaches expected post-V170 state)
- **Probe assert**: `PASS Raul Case 4 strict: pre-V170 Anvil 100% unstake on val-8 carried through V170 prune`
- **CL log evidence**:
  - Pre-V170 unstake: P4 (L1041)
  - V170 prune: V3 (val-8 begin unbonding, L3070)
  - These two events happen on the same val_addr, in expected temporal order
- **REST evidence**: `final-state.txt` val-8 row: `{"status":1,"jailed":false,"tokens":"807753484131516","unbonding_height":"70"}` — tokens = genesis (Anvil portion already unbonded pre-V170), unbonding_height=70 (val-level UNBONDING started at V170)
- **Status**: ✓ chain-asserted

---

## Post-V170 phase (existing scenario, val-7)

### Claim Q1: Phase 4 — Anvil 100% unstakes from val-7 POST-V170
- **Probe assert**: `Phase 4 — Anvil 100% unstakes from localnet-val-7 ... CLI rc=0 tx=0x3004099ca15beff43a54323e681b1b629c09a842b3820223201607552d43e408`
- **CL log evidence**: [`events/phase4-anvil-unstake-val7-postH.txt`](events/phase4-anvil-unstake-val7-postH.txt) — L3381 (07:10:39.854): `📚 Delegation removed acc_addr=F39FD6...(Anvil) val_addr=265A3C...(val-7)`
- **Timing**: 07:10:39 — POST-V170 (which fired at 07:10:16)
- **Status**: ✓ chain-asserted

### Claim Q2: val-7 final state — UNBONDED, not jailed, tokens reduced
- **Probe assert**: `val status post-prune=UNBONDED(1) post-unstake=1`, `tokens pre=834953744897255 post-stake=837001744897255 post-unstake=834953744897255 (Anvil portion drained)`
- **REST evidence**: `final-state.txt` val-7 row: `{"status":1,"jailed":false,"tokens":"834953744897255",...}` — tokens back to genesis (Anvil's 2048 IP fully drained)
- **Status**: ✓ REST chain-asserted

---

## Chain liveness

### Claim L1: No panic, no CONSENSUS FAILURE across all 8 vals
- **Probe assert**: `PASS chain still progressing post-unstake (no halt)` and `Final chain height: 92 (no halt)`
- **CL log evidence**: [`events/chain-liveness-no-halt.txt`](events/chain-liveness-no-halt.txt) — `TOTAL: 0` panic/CONSENSUS FAILURE across 8 val nodes; explicit `PASS: chain liveness — no halt`
- **Status**: ✓ chain-asserted (this slice scans all 8 cl-validator*-node.log files; only val-1 retained on disk, others were scanned at slice generation time before deletion)

### Claim L2: Block production continued past V170
- **Probe assert**: `Final chain height: 92 (no halt)`
- **CL log evidence**: [`events/chain-progressed-past-v170.txt`](events/chain-progressed-past-v170.txt) — many `FinalizeBlock height=71..92+` events
- **Status**: ✓ chain-asserted

---

## Summary

| # | Claim | Source | Status |
|---|---|---|---|
| P1 | Genesis 8 vals bonded | CL L84-91 | ✓ |
| P2 | Anvil → val-7 stake (Phase 2 PRE-V170) | CL L607 | ✓ |
| P3 | Anvil → val-8 stake (Phase 2b PRE-V170) | CL L868 | ✓ |
| **P4** | **Anvil 100% unstake from val-8 PRE-V170 (Raul Case 4 strict)** | **CL L1041** | ✓ **(new)** |
| V1 | V170 fire at h=70, 4 vals power=0 | CL L3055-3100 | ✓ |
| V2 | params.max_validators=4 | REST | ✓ |
| V3 | val-5..8 begin unbonding at V170 | CL L3066-3070 | ✓ |
| V4 | val-1..4 stay BONDED | CL absence | ✓ |
| V5 | val-8 carry-through (Raul Case 4 strict end-to-end) | CL L1041 + L3070 + REST | ✓ |
| Q1 | Anvil unstake val-7 POST-V170 | CL L3381 | ✓ |
| Q2 | val-7 final state (UNBONDED, not jailed) | REST | ✓ |
| L1 | No panic / CONSENSUS FAILURE | CL scan all 8 vals = 0 | ✓ |
| L2 | Block production past V170 | CL FinalizeBlock h=71..92+ | ✓ |

**All 13 PASS claims are CL log or REST chain-asserted.** Probe stdout's PASS lines are corroborated by independent log evidence.

## Limitations of this evidence package

- EL (geth) logs not retained — staking actions go through Cosmos x/staking (CL), so EL evidence is not needed for these claims. Tx hashes recorded in probe stdout for traceability only.
- Only `cl-validator1-node.log` retained as canonical. Other 7 vals would have identical content (consensus layer); their slices were extracted at gen-time.
- Slice line numbers are immutable references to `cl-validator1-node.log` — modifying that file invalidates line refs. Tree state is `git`-tracked once committed.
