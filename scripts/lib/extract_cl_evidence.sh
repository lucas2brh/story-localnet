#!/usr/bin/env bash
# extract_cl_evidence.sh — extract CL log slices for QA evidence (per-claim grep).
#
# Reads:
#   $EV_DIR (full CL/EL logs already captured here, e.g., cl-validator{1..8}-node.log)
#   $META  (validators_meta.json — for val_addr lookup)
#
# Writes:
#   $EV_DIR/events/<claim-id>.txt — one file per claim, each containing:
#     header: claim name + grep pattern + source log
#     matched lines with line numbers
#
# Story CL log format uses emoji-prefixed events: 📚 Validator created/bonded/begin unbonding,
# 📚 Delegation created/modified/removed/shares modified.
# val_addr / acc_addr / cons_addr are uppercase hex (EVM-style without 0x).

set -u
EV_DIR=${1:?usage: extract_cl_evidence.sh <evidence_dir> <meta_json>}
META=${2:?usage: extract_cl_evidence.sh <evidence_dir> <meta_json>}

ANVIL_UPPER="F39FD6E51AAD88F6F4CE6AB8827279CFFFB92266"
SRC_LOG="$EV_DIR/cl-validator1-node.log"   # canonical chain log (all vals see same chain state)
mkdir -p "$EV_DIR/events"

# Get val val_addr (uppercase, no 0x) for each moniker
declare -a VAL_ADDR_UPPER
for i in $(seq 1 8); do
  evm=$(jq -r --arg m "localnet-val-$i" '.[] | select(.moniker==$m) | .evm_address' "$META")
  upper=$(echo "$evm" | sed 's/^0x//' | tr 'a-z' 'A-Z')
  VAL_ADDR_UPPER[$i]=$upper
done

# ---- helper ----
write_slice() {
  local claim_id=$1 pattern=$2 src=$3 description=$4
  local out="$EV_DIR/events/$claim_id.txt"
  {
    echo "# claim: $claim_id"
    echo "# desc:  $description"
    echo "# source: $(basename "$src")"
    echo "# pattern: $pattern"
    echo "---"
    grep -nE "$pattern" "$src" || echo "(no matches — claim not supported by log evidence)"
  } > "$out"
}

# ---- claims ----

# 0. Genesis: 8 vals BONDED at h=0
write_slice "00-genesis-8-vals-bonded" "📚 Validator bonded" "$SRC_LOG" "Genesis: 8 validators bonded at chain start (8 hits expected)"

# 1. Phase 2: Anvil delegates 2048 IP to val-7 PRE-V170 (target_moniker)
write_slice "phase2-anvil-stake-val7" "📚 Delegation created.*acc_addr=$ANVIL_UPPER.*val_addr=${VAL_ADDR_UPPER[7]}" "$SRC_LOG" "Phase 2 (PRE-V170): Anvil delegated 2048 IP to val-7"

# 2. Phase 2b: Anvil delegates to val-8 (Raul Case 4 strict setup)
write_slice "phase2b-anvil-stake-val8" "📚 Delegation created.*acc_addr=$ANVIL_UPPER.*val_addr=${VAL_ADDR_UPPER[8]}" "$SRC_LOG" "Phase 2b (PRE-V170, Raul Case 4 strict): Anvil delegated 2048 IP to val-8 to set up multi-del shape"

# 3. Phase 2b: Anvil 100% UNSTAKE from val-8 PRE-V170 (Raul Case 4 strict core)
write_slice "phase2b-anvil-unstake-val8-preH" "📚 Delegation removed.*acc_addr=$ANVIL_UPPER.*val_addr=${VAL_ADDR_UPPER[8]}" "$SRC_LOG" "Phase 2b (PRE-V170, Raul Case 4 strict CORE): Anvil 100% unstaked from val-8 BEFORE H — Delegation removed event chain-asserts the preemptive undelegate"

# 4. V170 fire at h=70 — val_updates with 4 powers=0 (the 4 pruned vals)
write_slice "phase3-v170-fire-h70" "FinalizeBlock.*height=70|val_updates=4.*power_0=0.*power_1=0.*power_2=0.*power_3=0|prune.*height=70" "$SRC_LOG" "Phase 3: V170 fires at h=70 — ABCI val_updates=4 with power_0..3=0 (4 vals removed from active set)"

# 5. Each pruned val (5..8) got 'Validator begin unbonding' at h=70
for i in 5 6 7 8; do
  write_slice "phase3-prune-val$i-begin-unbonding" "📚 Validator begin unbonding.*val_addr=${VAL_ADDR_UPPER[$i]}" "$SRC_LOG" "Phase 3: V170 prune — val-$i BONDED→UNBONDING at h=70"
done

# 6. Bonded vals (1..4) stay BONDED — should NOT have 'begin unbonding' at h=70
for i in 1 2 3 4; do
  write_slice "phase3-bonded-val$i-no-unbonding" "📚 Validator begin unbonding.*val_addr=${VAL_ADDR_UPPER[$i]}" "$SRC_LOG" "Phase 3: top-4 val-$i should NOT have 'begin unbonding' (stays BONDED). 0 hits = PASS."
done

# 7. Phase 4: Anvil unstakes from val-7 POST-V170
write_slice "phase4-anvil-unstake-val7-postH" "📚 Delegation removed.*acc_addr=$ANVIL_UPPER.*val_addr=${VAL_ADDR_UPPER[7]}" "$SRC_LOG" "Phase 4 (POST-V170): Anvil 100% unstaked from val-7 (the existing post-V170 scenario)"

# 8. Chain liveness — no panic / consensus failure across all val nodes
{
  echo "# claim: chain-liveness-no-halt"
  echo "# desc:  No panic / CONSENSUS FAILURE in any val-node CL log (chain didn't halt)"
  echo "# pattern: panic|CONSENSUS FAILURE"
  echo "# scope: cl-validator{1..8}-node.log"
  echo "---"
  total=0
  for c in $(ls "$EV_DIR"/cl-validator*-node.log 2>/dev/null); do
    n=$(grep -cE "panic|CONSENSUS FAILURE" "$c" 2>/dev/null | tr -d '[:space:]')
    n=${n:-0}
    echo "$(basename "$c"): $n hits"
    total=$(( total + ${n:-0} ))
  done
  echo "TOTAL: $total"
  [[ $total -eq 0 ]] && echo "PASS: chain liveness — no halt" || echo "FAIL: $total panic/CONSENSUS FAILURE hits"
} > "$EV_DIR/events/chain-liveness-no-halt.txt"

# 9. Block production continued post-V170 (FinalizeBlock past h=70)
write_slice "chain-progressed-past-v170" "FinalizeBlock.*height=(7[1-9]|[89][0-9]|[1-9][0-9]{2,})" "$SRC_LOG" "Chain progressed past V170 (h=70) — FinalizeBlock events at h>=71"

echo "Wrote slices to $EV_DIR/events/:"
ls "$EV_DIR/events/" | sed 's/^/  /'
