#!/usr/bin/env bash
# probe_v171_halt_v181_retire_8val.sh
#
# Aeneid DKG/CDR retirement path, as proposed for Aeneid:
#   v1.7.0 (DKG module live, vote extensions on)
#     -> rolling swap to v1.7.1 (release/1.7 + v1.8.1 fork height, no handler)
#     -> every node halts at the fork height with UPGRADE "v1.8.1" NEEDED
#     -> all nodes swap to v1.8.1 (release/1.8 + retirement handler) and resume
#
# Binaries under test (piplabs/story-private-fork):
#   v1.7.1 = chore/aeneid-dkg-halt   (story-node:v1.7.1-dkg-halt-localnet)
#   v1.8.1 = feat/aeneid-dkg-retire  (story-node:v1.8.1-dkg-retire-localnet)
#   v1.7.0 = story-node:v1.7.0-clean-localnet (commit 6a97606 unpatched, the halt
#            branch base). Not story-node:v1.7.0-localnet: that image carries
#            Horace=10/Seneca=100 test patches, so Horace would run twice and the
#            v1.7.1 nodes panic at H=100 with "horace has already been completed".
#
# Heights (StoryLocalnetID in lib/netconf/upgrades.go of both branches):
#   H_SWAP = 30   rolling v1.7.0 -> v1.7.1, one validator at a time
#   Horace = 100  fires on v1.7.1 (pre-existing localnet fork, unrelated)
#   H_FORK = 130  V181 fork height compiled into both binaries
#   H_END  = 145
#
# Genesis is patched before boot so the chain resembles Aeneid:
#   - app_state.dkg present (v1.7.0 default params), so the dkg store and
#     module are live from genesis and every block carries MsgAddDkgVote
#   - consensus_params.abci.vote_extensions_enable_height = 1
# The original genesis is saved to genesis-node.json.pre-dkg-retire and restored
# on teardown.
#
# Assertions (chain-asserted):
#   B1 H=29 app_hash identical across 8 vals (all v1.7.0)
#   B2 all 8 report v1.7.1 after the rolling swap; H=35 app_hash identical
#   B3 dkg store queryable before the fork (abci_query /store/dkg/key code 0)
#   B4 every node halts: max height stays 129, log has UPGRADE "v1.8.1" NEEDED,
#      upgrade-info.json written
#   B5 after the swap to v1.8.1 the chain passes H_FORK+10; app_hash identical
#      across 8 vals at H_FORK and H_END
#   B6 handler log "V1.8.1 upgrade complete" on all 8 vals
#   B7 dkg store no longer mounted after the fork (abci_query returns non-zero)
#   B8 vote extensions still enabled (consensus_params at H_END)
#   B9 val1 restarted on v1.8.1 after the fork catches up
# Recorded for review, not pass/fail:
#   R1 block_results at H_FORK: tx result code. Block H_FORK was proposed by
#      v1.7.1 and carries MsgAddDkgVote next to MsgExecutionPayload in one tx;
#      v1.8.1 has no dkg types, so a non-zero code means the payload at H_FORK
#      did not execute.
#   R2 EL head number while halted vs after resume.
#
# Preflight (fails in seconds, before any chain is booted):
#   P1 host tools, compose files, genesis chain_id, pinned commits present
#   P2 each image is built from its pinned commit (image label story.commit);
#      a missing or mismatched image is rebuilt from story-private-fork
#   P3 StoryLocalnetID fork table: every fork the v1.7.0 commit knows has the
#      same height in both new commits, and V181 == H_FORK in both
#   P4 log strings the assertions grep for exist in the pinned source
# Boot gate: all vals at H>=3 within 90s, else fail with the first error;
# B0 (VE on chain, MsgAddDkgVote in blocks) is checked right after.
#
# Usage:
#   ./scripts/probe_v171_halt_v181_retire_8val.sh
#   SKIP_TEARDOWN=1 ./scripts/probe_v171_halt_v181_retire_8val.sh
#   PREFLIGHT_ONLY=1 ./scripts/probe_v171_halt_v181_retire_8val.sh
#   START_PHASE=4 ./scripts/probe_v171_halt_v181_retire_8val.sh
#       resume on a chain already halted at H_FORK by v1.7.1

set -u

N_VALS=${N_VALS:-8}
H_SWAP=${H_SWAP:-30}
H_PRE_SWAP=$((H_SWAP - 1))
H_POST_SWAP=$((H_SWAP + 5))
H_FORK=${H_FORK:-130}
H_PRE_FORK=$((H_FORK - 1))
H_POST_FORK=$((H_FORK + 10))
H_END=${H_END:-145}
SKIP_TEARDOWN=${SKIP_TEARDOWN:-0}
START_PHASE=${START_PHASE:-0}
PREFLIGHT_ONLY=${PREFLIGHT_ONLY:-0}

COMMIT_V170=6a9760693cf135cf069e7377d9ead0fdc8c044e8 # v1.7.0 stable, unpatched
COMMIT_V171=c05f3415d4bb2308837a5d7e904e443cb052d66f # chore/aeneid-dkg-halt
COMMIT_V181=0954989ae98a8533d1f7adef73f2499cec618708 # feat/aeneid-dkg-retire

IMG_V170=story-node:v1.7.0-clean-localnet
IMG_V171=story-node:v1.7.1-dkg-halt-localnet
IMG_V181=story-node:v1.8.1-dkg-retire-localnet

LOCALNET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EV_DIR="${LOCALNET}/tmp/probe-v181-dkg-retire-evidence"
FORK_REPO="${LOCALNET}/../story-private-fork"
BUILD_DIR="${LOCALNET}/tmp/probe-v181-dkg-retire-build"
GENESIS="${LOCALNET}/config/story/genesis-node.json"
GENESIS_BAK="${GENESIS}.pre-dkg-retire"
# v1.7.0 DefaultParams (client/x/dkg/types/params.go at 6a97606). The newer
# story-cdr-e2e genesis carries fields v1.7.0 rejects.
DKG_JSON='{"params":{"registration_period":34560,"dealing_period":34560,"finalization_period":34560,"active_period":138240,"dkg_committee_reward_portion":"0.050000000000000000","min_req_registered_participants":5,"min_req_finalized_participants":5,"operational_threshold":500}}'

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
fail() { log "FAIL: $*"; dump_logs; log "genesis left patched; restore with: cp $GENESIS_BAK $GENESIS"; exit 1; }

rpc() {
  local N=$1
  shift
  docker exec "validator${N}-node" wget -qO- "http://localhost:26657$*" 2>/dev/null
}

el_head() {
  docker exec "validator${1}-geth" geth attach --exec 'eth.blockNumber' /root/.story/geth/data/geth.ipc 2>/dev/null | tr -d '\r'
}

height_of() {
  rpc "$1" /status | jq -r '.result.sync_info.latest_block_height' 2>/dev/null
}

compose_vals() {
  local args=(-f "$LOCALNET/docker-compose-bootnode1.yml")
  for N in $(seq 1 $N_VALS); do
    args+=(-f "$LOCALNET/docker-compose-validator${N}.yml")
  done
  args+=(-f "$1")
  shift
  docker compose "${args[@]}" "$@"
}

max_min_heights() {
  local min=999999 max=0 H
  for N in $(seq 1 $N_VALS); do
    H=$(height_of "$N")
    [ -z "$H" ] || [ "$H" = "null" ] && H=0
    [ "$H" -lt "$min" ] && min=$H
    [ "$H" -gt "$max" ] && max=$H
  done
  echo "$min $max"
}

wait_until_height() {
  local target=$1 deadline=$(( $(date +%s) + 600 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    read -r min max <<<"$(max_min_heights)"
    log "heights min=$min max=$max (waiting >= $target)"
    [ "$min" -ge "$target" ] && return 0
    sleep 3
  done
  fail "timeout waiting for all $N_VALS vals to reach H>=$target"
}

apphash_at() {
  rpc "$1" "/block?height=$2" | jq -r '.result.block.header.app_hash'
}

dump_apphash_all_vals() {
  local H=$1 outfile=$2
  : > "$outfile"
  for N in $(seq 1 $N_VALS); do
    echo "val${N}: $(apphash_at "$N" "$H")" >> "$outfile"
  done
  if grep -q -E ': (null)?$' "$outfile"; then
    echo 0
    return
  fi
  awk '{print $2}' "$outfile" | sort -u | wc -l | tr -d ' '
}

tx_msg_types() {
  rpc "$1" "/block?height=$2" | jq -r '.result.block.data.txs[0] // empty' | base64 -d 2>/dev/null \
    | strings | grep -oE '/story\.[A-Za-z0-9.]+' | sort -u | tr '\n' ' '
}

dkg_store_code() {
  rpc "$1" '/abci_query?path=%22/store/dkg/key%22&data=0x01' | jq -r '.result.response.code'
}

dump_logs() {
  mkdir -p "$EV_DIR/containers"
  for N in $(seq 1 $N_VALS); do
    docker logs "validator${N}-node" > "$EV_DIR/containers/val${N}.log" 2>&1
  done
}

check_versions() {
  local want=$1 bad=0 V
  : > "$EV_DIR/version-check-${want}.txt"
  for N in $(seq 1 $N_VALS); do
    V=$(docker exec "validator${N}-node" story version 2>&1 | awk '/^Version/{print $2}')
    echo "val${N}: $V" >> "$EV_DIR/version-check-${want}.txt"
    [ "$V" = "$want" ] || bad=$((bad + 1))
  done
  echo "$bad"
}

# --- preflight ---
image_commit() {
  docker image inspect -f '{{index .Config.Labels "story.commit"}}' "$1" 2>/dev/null
}

ensure_image() {
  local img=$1 commit=$2
  local wt="$BUILD_DIR/wt-${commit:0:7}" ctx="$BUILD_DIR/ctx-${commit:0:7}"
  [ "$(image_commit "$img")" = "$commit" ] && return 0
  log "P2 building $img from ${commit:0:7}"
  mkdir -p "$ctx"
  [ -d "$wt" ] || git -C "$FORK_REPO" worktree add --detach "$wt" "$commit" >/dev/null 2>&1 \
    || fail "P2 worktree for $commit"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$commit" ] || fail "P2 worktree $wt not at $commit"
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "P2 worktree $wt is dirty"
  (cd "$wt" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o "$ctx/story-prebuilt" ./client) \
    > "$BUILD_DIR/build-${commit:0:7}.log" 2>&1 || fail "P2 go build ${commit:0:7} (see $BUILD_DIR)"
  docker build -q --label "story.commit=$commit" -t "$img" -f "$LOCALNET/Dockerfile.story-node" "$ctx" \
    >/dev/null || fail "P2 docker build $img"
  [ "$(image_commit "$img")" = "$commit" ] || fail "P2 $img label mismatch after build"
}

fork_table() {
  git -C "$FORK_REPO" show "$1:lib/netconf/upgrades.go" \
    | awk '/StoryLocalnetID: \{/{f=1; next} f && /^\t\},?$/{exit} f && /^\t\t[A-Za-z0-9]+: *[0-9]+,/{gsub(/[:,]/,""); print $1, $2}' \
    | sort
}

[ "$START_PHASE" = "0" ] && rm -rf "$EV_DIR"
mkdir -p "$EV_DIR/containers" "$BUILD_DIR"
log "evidence dir: $EV_DIR"

# P1
for t in docker jq go git strings base64 awk comm; do
  command -v "$t" >/dev/null || fail "P1 missing host tool: $t"
done
NYML=$(ls "$LOCALNET"/docker-compose-validator*.yml | wc -l | tr -d ' ')
[ "$NYML" = "$N_VALS" ] || fail "P1 found $NYML validator compose files, want $N_VALS (stale cluster files?)"
SRC_GENESIS="$GENESIS"
[ -f "$GENESIS_BAK" ] && SRC_GENESIS="$GENESIS_BAK"
[ "$(jq -r '.chain_id' "$SRC_GENESIS")" = "story-localnet" ] || fail "P1 genesis chain_id is not story-localnet"
[ "$(jq -r '.consensus_params.abci.vote_extensions_enable_height' "$SRC_GENESIS")" != "null" ] \
  || fail "P1 genesis has no consensus_params.abci.vote_extensions_enable_height to patch"
for c in $COMMIT_V170 $COMMIT_V171 $COMMIT_V181; do
  git -C "$FORK_REPO" cat-file -e "$c^{commit}" 2>/dev/null || fail "P1 commit $c not in $FORK_REPO (git fetch?)"
done
log "P1 pass: tools, compose files, genesis, commits"

# P2
ensure_image "$IMG_V170" "$COMMIT_V170"
ensure_image "$IMG_V171" "$COMMIT_V171"
ensure_image "$IMG_V181" "$COMMIT_V181"
for pair in "$IMG_V170=v1.7.0-stable" "$IMG_V171=v1.7.1-unstable" "$IMG_V181=v1.8.1-unstable"; do
  img=${pair%=*}
  want=${pair#*=}
  got=$(docker run --rm --entrypoint story "$img" version 2>&1 | awk '/^Version/{print $2}')
  [ "$got" = "$want" ] || fail "P2 $img reports $got, want $want"
done
for i in "$IMG_V170" "$IMG_V171" "$IMG_V181"; do echo "$i $(image_commit "$i")"; done > "$EV_DIR/P2-images.txt"
log "P2 pass: images built from pinned commits"

# P3
fork_table "$COMMIT_V170" > "$EV_DIR/P3-forks-v170.txt"
fork_table "$COMMIT_V171" > "$EV_DIR/P3-forks-v171.txt"
fork_table "$COMMIT_V181" > "$EV_DIR/P3-forks-v181.txt"
[ -s "$EV_DIR/P3-forks-v170.txt" ] || fail "P3 could not parse the StoryLocalnetID fork table"
for newer in v171 v181; do
  missing=$(comm -23 "$EV_DIR/P3-forks-v170.txt" "$EV_DIR/P3-forks-${newer}.txt")
  [ -z "$missing" ] || fail "P3 fork heights in v1.7.0 differ in ${newer}: $missing"
  h=$(awk '$1=="V181"{print $2}' "$EV_DIR/P3-forks-${newer}.txt")
  [ "$h" = "$H_FORK" ] || fail "P3 ${newer} V181=$h, want H_FORK=$H_FORK"
done
log "P3 pass: fork tables consistent: $(tr '\n' ' ' < "$EV_DIR/P3-forks-v171.txt")"

# P4
git -C "$FORK_REPO" grep -q "V1.8.1 upgrade complete" "$COMMIT_V181" -- client/app/upgrades/v_1_8_1 \
  || fail "P4 handler log string not in v1.8.1 source"
log "P4 pass: assertion log strings present in source"

if [ "$PREFLIGHT_ONLY" = "1" ]; then
  log "preflight only, exiting"
  exit 0
fi

if [ "$START_PHASE" = "0" ]; then
# --- Phase 0: terminate, patch genesis, boot on v1.7.0 ---
log "Phase 0: terminate + patch genesis + boot"
"$LOCALNET/terminate.sh" >/dev/null 2>&1 || true

[ -f "$GENESIS_BAK" ] || cp "$GENESIS" "$GENESIS_BAK"
jq --argjson dkg "$DKG_JSON" \
  '.app_state.dkg = $dkg | .consensus_params.abci.vote_extensions_enable_height = "1"' \
  "$GENESIS_BAK" > "$GENESIS"
jq -c '{dkg: .app_state.dkg.params.operational_threshold, ve: .consensus_params.abci.vote_extensions_enable_height}' "$GENESIS" \
  > "$EV_DIR/genesis-patch.json"
log "genesis patched: $(cat "$EV_DIR/genesis-patch.json")"

if ! docker image inspect story-geth:localnet >/dev/null 2>&1; then
  log "building story-geth:localnet"
  docker buildx build --load -t story-geth:localnet \
    -f "$LOCALNET/Dockerfile.story-geth" "$LOCALNET/../story-geth" >/dev/null 2>&1 \
    || fail "story-geth build failed"
fi

JWT_FILE="$LOCALNET/tmp/jwt/secret.txt"
if [ ! -s "$JWT_FILE" ]; then
  mkdir -p "$(dirname "$JWT_FILE")"
  openssl rand -hex 32 > "$JWT_FILE"
fi

export COMPOSE_IGNORE_ORPHANS=true
compose_vals "$LOCALNET/compose.scenario-dkg-retire-v170.yml" up -d --no-build >/dev/null 2>&1 \
  || fail "chain boot failed"

# Boot gate: a genesis the binary rejects shows up here, not at H=30.
deadline=$(( $(date +%s) + 90 ))
while :; do
  read -r min max <<<"$(max_min_heights)"
  [ "$min" -ge 3 ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    p=$(docker logs validator1-node 2>&1 | grep -m1 -E '^panic:|CONSENSUS FAILURE|Error:' | cut -c1-200)
    fail "boot gate: vals not at H>=3 after 90s (min=$min max=$max), first error: $p"
  fi
  sleep 3
done
log "boot gate pass: all vals producing blocks"

VE0=$(rpc 1 "/consensus_params?height=2" | jq -r '.result.consensus_params.abci.vote_extensions_enable_height')
MSGS0=$(tx_msg_types 1 2)
echo "H=2 ve=$VE0 msgs=$MSGS0" > "$EV_DIR/B0-aeneid-shape.txt"
[ "$VE0" = "1" ] || fail "B0 vote_extensions_enable_height=$VE0 on chain, want 1"
echo "$MSGS0" | grep -q MsgAddDkgVote || fail "B0 no MsgAddDkgVote in block 2 ($MSGS0)"
log "B0 pass: VE enabled, block carries MsgAddDkgVote"

for N in $(seq 1 $N_VALS); do
  IMG=$(docker ps --format "{{.Image}}" --filter "name=^validator${N}-node$")
  [ "$IMG" = "$IMG_V170" ] || fail "val${N} image=$IMG, want $IMG_V170"
done
log "topology: all $N_VALS vals on $IMG_V170"

# --- Phase 1: B1 pre-swap consistency ---
wait_until_height "$H_SWAP"
DISTINCT=$(dump_apphash_all_vals "$H_PRE_SWAP" "$EV_DIR/B1-H${H_PRE_SWAP}-apphash.txt")
[ "$DISTINCT" = "1" ] || fail "B1 app_hash at H=$H_PRE_SWAP distinct=$DISTINCT"
log "B1 pass: H=$H_PRE_SWAP app_hash identical"

# --- Phase 2: rolling swap v1.7.0 -> v1.7.1 ---
SWAP_START=$(date +%s)
for N in $(seq 1 $N_VALS); do
  log "swap val${N} -> v1.7.1"
  docker compose -f "$LOCALNET/docker-compose-validator${N}.yml" \
    -f "$LOCALNET/compose.scenario-dkg-retire-v171.yml" \
    up -d --no-build --force-recreate "validator${N}-node" >/dev/null 2>&1
  sleep 15
done
docker compose -f "$LOCALNET/docker-compose-bootnode1.yml" \
  -f "$LOCALNET/compose.scenario-dkg-retire-v171.yml" \
  up -d --no-build --force-recreate bootnode1-node >/dev/null 2>&1
log "rolling swap took $(( $(date +%s) - SWAP_START ))s"

BAD=$(check_versions v1.7.1-unstable)
[ "$BAD" = "0" ] || fail "B2 $BAD vals not on v1.7.1-unstable"
read -r min max <<<"$(max_min_heights)"
[ "$max" -lt "$H_PRE_FORK" ] || fail "B2 swap finished at H=$max, too close to the fork height"
wait_until_height "$H_POST_SWAP"
DISTINCT=$(dump_apphash_all_vals "$H_POST_SWAP" "$EV_DIR/B2-H${H_POST_SWAP}-apphash.txt")
[ "$DISTINCT" = "1" ] || fail "B2 app_hash at H=$H_POST_SWAP distinct=$DISTINCT"
log "B2 pass: all on v1.7.1, H=$H_POST_SWAP app_hash identical"

# --- Phase 3: B3 dkg store live before the fork ---
CODE=$(dkg_store_code 1)
echo "dkg store abci_query code before fork: $CODE" > "$EV_DIR/B3-dkg-store-pre.txt"
[ "$CODE" = "0" ] || fail "B3 dkg store query code=$CODE before the fork, want 0"
log "B3 pass: dkg store mounted before the fork"

fi # START_PHASE=0

# --- Phase 4: B4 halt at H_FORK ---
# Once a node halts its RPC never comes back (it panics again while replaying
# H_FORK on every restart), so track the highest height seen instead of min.
SEEN_MAX=0
deadline=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  read -r min max <<<"$(max_min_heights)"
  [ "$max" -gt "$SEEN_MAX" ] && SEEN_MAX=$max
  log "heights min=$min max=$max seen_max=$SEEN_MAX (waiting for halt at $H_FORK)"
  [ "$SEEN_MAX" -ge "$H_PRE_FORK" ] && { [ "$max" -lt "$SEEN_MAX" ] || [ "$min" -ge "$H_PRE_FORK" ]; } && break
  sleep 3
done
log "reached H=$H_PRE_FORK, waiting 40s to confirm the halt"
sleep 40
read -r min max <<<"$(max_min_heights)"
[ "$max" -gt "$SEEN_MAX" ] && SEEN_MAX=$max
EL_HALT=$(el_head 1)
echo "seen_max=$SEEN_MAX rpc_min=$min rpc_max=$max el_head_val1=$EL_HALT" > "$EV_DIR/B4-halt-heights.txt"
dump_logs
HALTED=0
for N in $(seq 1 $N_VALS); do
  grep -q 'UPGRADE "v1.8.1" NEEDED at height: '"$H_FORK" "$EV_DIR/containers/val${N}.log" && HALTED=$((HALTED + 1))
  docker cp "validator${N}-node:/root/.story/story/data/upgrade-info.json" - 2>/dev/null \
    | tar -xO 2>/dev/null > "$EV_DIR/B4-upgrade-info-val${N}.json"
done
log "B4: seen_max=$SEEN_MAX, halt log on $HALTED/$N_VALS vals, EL head=$EL_HALT"
# /status latest_block_height is the block store height. CometBFT saves the
# decided block H_FORK before FinalizeBlock panics on it, so H_FORK can show
# up there without having been applied. Nothing may reach H_FORK+1.
[ "$SEEN_MAX" -le "$H_FORK" ] || fail "B4 v1.7.1 went past $H_FORK (seen_max=$SEEN_MAX)"
[ "$HALTED" = "$N_VALS" ] || fail "B4 halt log on $HALTED/$N_VALS vals"
[ -s "$EV_DIR/B4-upgrade-info-val1.json" ] || fail "B4 upgrade-info.json missing on val1"
log "B4 pass: every node halted at H=$H_FORK"

# --- Phase 5: swap all to v1.8.1 ---
log "swapping all vals to v1.8.1"
compose_vals "$LOCALNET/compose.scenario-dkg-retire-v181.yml" up -d --no-build --force-recreate \
  bootnode1-node $(for N in $(seq 1 $N_VALS); do echo "validator${N}-node"; done) >/dev/null 2>&1 \
  || fail "swap to v1.8.1 failed"
sleep 15
BAD=$(check_versions v1.8.1-unstable)
[ "$BAD" = "0" ] || fail "B5 $BAD vals not on v1.8.1-unstable"

wait_until_height "$H_POST_FORK"
EL_RESUME=$(el_head 1)
DISTINCT=$(dump_apphash_all_vals "$H_FORK" "$EV_DIR/B5-H${H_FORK}-apphash.txt")
[ "$DISTINCT" = "1" ] || fail "B5 app_hash at H=$H_FORK distinct=$DISTINCT"
log "B5 pass (fork block): H=$H_FORK app_hash identical, chain at >= $H_POST_FORK"

# --- R1/R2 recorded ---
rpc 1 "/block_results?height=${H_FORK}" > "$EV_DIR/R1-H${H_FORK}-block-results.json"
rpc 1 "/block_results?height=$((H_FORK + 1))" > "$EV_DIR/R1-H$((H_FORK + 1))-block-results.json"
R1_CODE=$(jq -r '[.result.txs_results[]?.code] | tostring' "$EV_DIR/R1-H${H_FORK}-block-results.json")
R1_LOG=$(jq -r '[.result.txs_results[]?.log] | tostring' "$EV_DIR/R1-H${H_FORK}-block-results.json")
R1_MSGS=$(tx_msg_types 1 "$H_FORK")
R1_MSGS_NEXT=$(tx_msg_types 1 "$((H_FORK + 1))")
echo "H=$H_FORK msgs=$R1_MSGS; H=$((H_FORK + 1)) msgs=$R1_MSGS_NEXT" > "$EV_DIR/R1-msg-types.txt"
log "R1: H=$H_FORK msgs=$R1_MSGS; H=$((H_FORK + 1)) msgs=$R1_MSGS_NEXT"
R1_NEXT=$(jq -r '[.result.txs_results[]?.code] | tostring' "$EV_DIR/R1-H$((H_FORK + 1))-block-results.json")
echo "el_head_halted=$EL_HALT el_head_after_H${H_POST_FORK}=$EL_RESUME" > "$EV_DIR/R2-el-head.txt"
log "R1: H=$H_FORK tx codes=$R1_CODE log=$R1_LOG; H=$((H_FORK + 1)) tx codes=$R1_NEXT"
log "R2: EL head halted=$EL_HALT, after H=$H_POST_FORK=$EL_RESUME"

# --- B6 handler ran ---
dump_logs
DONE=0
for N in $(seq 1 $N_VALS); do
  grep -q "V1.8.1 upgrade complete" "$EV_DIR/containers/val${N}.log" && DONE=$((DONE + 1))
done
grep -h -E "Retired module account|Moved retired module account|V1.8.1 upgrade complete" \
  "$EV_DIR/containers/val1.log" > "$EV_DIR/B6-handler-log-val1.txt"
[ "$DONE" = "$N_VALS" ] || fail "B6 handler completion log on $DONE/$N_VALS vals"
log "B6 pass: handler completed on all vals"

# --- B7 dkg store gone ---
CODE=$(dkg_store_code 1)
rpc 1 '/abci_query?path=%22/store/dkg/key%22&data=0x01' > "$EV_DIR/B7-dkg-store-post.json"
[ "$CODE" != "0" ] && [ -n "$CODE" ] && [ "$CODE" != "null" ] || fail "B7 dkg store query code=$CODE after the fork, want non-zero"
log "B7 pass: dkg store not mounted after the fork (code=$CODE)"

# --- B8 VE still enabled ---
wait_until_height "$H_END"
VE=$(rpc 1 "/consensus_params?height=$H_END" | jq -r '.result.consensus_params.abci.vote_extensions_enable_height')
echo "vote_extensions_enable_height=$VE" > "$EV_DIR/B8-ve.txt"
[ "$VE" = "1" ] || fail "B8 vote_extensions_enable_height=$VE, want 1"
log "B8 pass: vote extensions still enabled"

DISTINCT=$(dump_apphash_all_vals "$H_END" "$EV_DIR/B5-H${H_END}-apphash.txt")
[ "$DISTINCT" = "1" ] || fail "B5 app_hash at H=$H_END distinct=$DISTINCT"
log "B5 pass (tail): H=$H_END app_hash identical"

# --- B9 restart on v1.8.1 ---
docker restart validator1-node >/dev/null
TARGET=$(( $(height_of 2) + 5 ))
sleep 20
wait_until_height "$TARGET"
log "B9 pass: val1 restarted on v1.8.1 and reached H>=$TARGET"

dump_logs
log "=== PROBE PASS (B1-B9); review R1/R2 in $EV_DIR ==="

if [ "$SKIP_TEARDOWN" = "0" ]; then
  "$LOCALNET/terminate.sh" 2>&1 | tail -3
  cp "$GENESIS_BAK" "$GENESIS" && rm -f "$GENESIS_BAK"
  log "teardown done, genesis restored"
else
  log "chain left running; restore genesis with: cp $GENESIS_BAK $GENESIS"
fi
