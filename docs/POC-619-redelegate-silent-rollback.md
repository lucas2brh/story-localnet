# PoC for piplabs/lion-team-sync#619 — silent-rollback redelegate bug

End-to-end localnet reproduction of the cosmos-sdk staking silent-rollback
bug tracked in <https://github.com/piplabs/lion-team-sync/issues/619>.

## What the probe verifies

`scripts/probe_redelegate_silent_rollback.sh` runs against a 20-validator
localnet with a v1.7.0 upgrade scheduled at block 50 (`MaxValidators` 80→16).
After the upgrade, vals 17-20 transition `BONDED → UNBONDING → UNBONDED`.
The probe then submits a 100% self-delegation redelegate from val-19 (now
status=Unbonded with sole self-delegator) to val-1 and asserts four
silent-rollback indicators.

PROBE PASS = bug reproduces (red light).
PROBE FAIL = fix is in effect (green light).

## Trigger conditions (all required)

1. `srcVal.Status == Unbonded` (1) at `BeginRedelegation` time
2. delegator holds 100% of remaining `DelegatorShares` on src
3. single-call 100% redelegate of that delegation

## Build inputs and the docker context gotcha

Story localnet builds the `story-node:localnet` image via:

```yaml
# docker-compose-bootnode1.yml
bootnode1-node:
  image: story-node:localnet
  build:
    context: ../story-private-fork                  # <- IMPORTANT
    dockerfile: ../story-localnet/Dockerfile.story-node
```

`Dockerfile.story-node` then runs `COPY story-prebuilt /usr/local/bin/story`.
The `story-prebuilt` source path is resolved against the **build context**,
which is `../story-private-fork`. The file at `story-localnet/story-prebuilt`
is NOT consumed by the build.

→ Stage the linux-arm64 binary at `story-private-fork/story-prebuilt`,
not at `story-localnet/story-prebuilt`.

## How to run

```bash
# 1. Build a bug-present story binary against the public piplabs/cosmos-sdk pin
#    (no local replace, default go.mod state).
cd /path/to/story-private-fork
git checkout 22354e1                                # known-good base for this PoC
make build
GOOS=linux GOARCH=arm64 go build -o build/story-linux ./client

# 2. Stage the host (mac) binary as the CLI used by the probe.
cp build/story /tmp/story

# 3. Stage the linux binary at the docker build-context path
#    (script derives the destination from docker-compose, so it works
#    whether the build.context points to story-private-fork, story, or
#    any other sibling repo). Records a sha256 fingerprint so start.sh
#    can later assert the image binary matches.
cd /path/to/story-localnet
bash scripts/stage_binary.sh ../story-private-fork/build/story-linux

# 4. Run the probe (in story-localnet repo).
bash terminate.sh                                    # if a previous cluster is up
docker rmi -f story-node:localnet 2>/dev/null        # ensure fresh image build
docker builder prune -af                             # clear stale build cache
bash scripts/probe_redelegate_silent_rollback.sh
```

`start.sh` (invoked inside the probe) automatically asserts the image's
embedded binary sha256 matches the one `stage_binary.sh` recorded; on
mismatch it exits 1 with a clear error before any cluster work begins.

Total wall-clock per run: ~5-6 min on first run (image rebuild from scratch),
~3-4 min on subsequent runs.

## Expected outcome on bug-present binary

```
PASS SRC confirmed UNBONDED (status=1) — bug trigger condition (1) met
Phase 4 — assert 4 silent-rollback indicators (PASS = bug still present)
  (a) SRC val record in store post-tx: yes
  (b) SRC tokens: 247568544444937 -> 247568544444937 (unchanged)
  (c) DST tokens: 914123992692492 -> 914123992692492 (unchanged)
  (d) found error string in validatorN-node log:
      ERRO Failed to process redelegate
PASS all 4 silent-rollback indicators confirmed — bug reproduces on this binary
```

EVM tx returns status=1 (gas burned, hash on-chain). CLI returns rc=0. But
on-chain redelegation never persists — the user-visible "successful" tx is
silently rolled back.

## Expected outcome on fix-applied binary

The probe FAILS at Phase 4 indicator (a) because `RemoveValidator` actually
persists, and dst tokens increment by exactly the redelegated amount. This
is the green signal that the fix has taken effect.

## Reference fix

`piplabs/cosmos-sdk#43` (lucas/redelegate-getbegininfo-fix branch):
in `x/staking/keeper/delegation.go` `getBeginInfo`, when
`GetValidator(valSrcAddr)` returns `ErrNoValidatorFound`, set
`completeNow = true` and clear the named-return `err`. Original eng owns
the merge decision.

## Verifying which binary is in your image

When in doubt about whether the running image has the fix:

```bash
docker create --name temp story-node:localnet
docker cp temp:/usr/local/bin/story /tmp/story-from-image
docker rm temp
go version -m /tmp/story-from-image | grep cosmos-sdk
```

If the line shows `=> /<some local path>/cosmos-sdk (devel)`, the binary was
built against a local clone (likely fix-applied). If it shows
`=> github.com/piplabs/cosmos-sdk v0.50.14-piplabs-v1.1`, the binary is the
public-pin (bug-present) version.
