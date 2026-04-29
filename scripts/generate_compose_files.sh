#!/usr/bin/env bash
# generate_compose_files.sh — emit docker-compose-validator{1..N}.yml from
# docker-compose-validator1.yml as template. Idempotent overwrite.
#
# Usage:
#   ./scripts/generate_compose_files.sh [N]
#
# Per-val template differs from val1 only in 3 token kinds:
#   - "validator1"  → "validator{K}"   (service / container / volume / bind path)
#   - "10.0.1.20"  → "10.0.1.{18+2K}"  (val-geth ipv4_address + --nat=extip)
#   - "10.0.1.21"  → "10.0.1.{19+2K}"  (val-node ipv4_address)
#
# IP capacity check: val{K}-node sits at 10.0.1.{19+2K}, so K up to ~117 fits
# in 10.0.1.0/24, and the bridge subnet 10.0.0.0/16 leaves headroom for
# thousands. K > 117 needs subnet-layout rework.

set -euo pipefail

N=${1:-20}

if ! [[ "$N" =~ ^[0-9]+$ ]] || [[ "$N" -lt 1 ]]; then
    echo "ERROR: N must be a positive integer (got: $N)" >&2
    exit 1
fi

LOCALNET_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$LOCALNET_DIR/docker-compose-validator1.yml"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "ERROR: template $TEMPLATE not found" >&2
    exit 1
fi

if [[ "$N" -gt 117 ]]; then
    echo "ERROR: N=$N exceeds 10.0.1.0/24 capacity (val-node would land at 10.0.1.$((19+2*N))). Rework subnet layout first." >&2
    exit 1
fi

echo "Generating $N docker-compose-validator{1..$N}.yml from $TEMPLATE"

# Snapshot template into a tmp file before the loop so K=1 doesn't read
# from the same path it's about to truncate (`> docker-compose-validator1.yml`
# would zero out the template before awk reads it).
TEMPLATE_SNAPSHOT=$(mktemp)
trap 'rm -f "$TEMPLATE_SNAPSHOT"' EXIT
cp "$TEMPLATE" "$TEMPLATE_SNAPSHOT"

for K in $(seq 1 "$N"); do
    GETH_IP="10.0.1.$((18 + 2*K))"
    NODE_IP="10.0.1.$((19 + 2*K))"
    OUT="$LOCALNET_DIR/docker-compose-validator${K}.yml"

    # Replace token kinds in the template. Order matters: do IP swaps first
    # because they're literal-string-unique, then validator1 -> validator{K}.
    # Using awk because macOS sed differs from GNU sed for -i.
    awk -v K="$K" -v GIP="$GETH_IP" -v NIP="$NODE_IP" '
        # IPs: 10.0.1.20 (geth) and 10.0.1.21 (node) appear as ipv4_address
        # and as --nat=extip values. Swap before val name to avoid clashes.
        { gsub(/10\.0\.1\.20/, GIP);
          gsub(/10\.0\.1\.21/, NIP);
          gsub(/validator1/, "validator" K);
          print }
    ' "$TEMPLATE_SNAPSHOT" > "$OUT"
done

echo "---"
echo "Spot-check val${N} (last):"
grep -E "container_name: validator|ipv4_address|--nat=extip" "$LOCALNET_DIR/docker-compose-validator${N}.yml" | head -10
echo "---"
echo "Done. Last val IP range: ${GETH_IP} (geth) / ${NODE_IP} (node)."
