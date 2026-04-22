#!/bin/bash
# Generate N validator config directories (config/story/validator{K}/) with
# random EVM private keys. Also emits tmp/validators_meta.json for genesis
# assembly. Uses host-built /tmp/story binary for key operations.
#
# Usage: ./generate_N_validators.sh [N]
#   N  validator count (default 20)
#
# Env:
#   STORY_BIN          story binary path (default /tmp/story)
#   VALIDATOR_BASE_IP  first validator geth IP (default 10.0.1.20)
#   TEMPLATE_VAL       source validator dir to template from (default validator1)

set -euo pipefail

N=${1:-20}
STORY_BIN=${STORY_BIN:-/tmp/story}
VALIDATOR_BASE_IP=${VALIDATOR_BASE_IP:-10.0.1.20}
TEMPLATE_VAL=${TEMPLATE_VAL:-validator1}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config/story"
TEMPLATE_DIR="${CONFIG_DIR}/${TEMPLATE_VAL}"
META_DIR="${REPO_ROOT}/tmp"
META_FILE="${META_DIR}/validators_meta.json"

[ -x "$STORY_BIN" ] || { echo "ERROR: $STORY_BIN not executable" >&2; exit 1; }

if [ ! -d "$TEMPLATE_DIR" ]; then
  echo "Template $TEMPLATE_DIR missing — restoring from git HEAD" >&2
  (cd "$REPO_ROOT" && git checkout HEAD -- "config/story/${TEMPLATE_VAL}") \
    || { echo "ERROR: template missing and git checkout failed" >&2; exit 1; }
fi

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }

mkdir -p "$META_DIR"

TEMPLATE_CACHE=$(mktemp -d)
cp -R "$TEMPLATE_DIR"/. "$TEMPLATE_CACHE/"
trap 'rm -rf "$TEMPLATE_CACHE"' EXIT

echo "Wiping existing config/story/validator*" >&2
find "$CONFIG_DIR" -maxdepth 1 -type d -name 'validator*' -exec rm -rf {} +

IFS='.' read -r o1 o2 o3 o4 <<< "$VALIDATOR_BASE_IP"

meta_entries=()

for K in $(seq 1 "$N"); do
  VAL_DIR="${CONFIG_DIR}/validator${K}"
  mkdir -p "${VAL_DIR}/story" "${VAL_DIR}/geth"

  GETH_IP="${o1}.${o2}.${o3}.$((o4 + (K-1)*2))"
  NODE_IP="${o1}.${o2}.${o3}.$((o4 + (K-1)*2 + 1))"

  PRIV=$(openssl rand -hex 32)

  PRIVATE_KEY="$PRIV" "$STORY_BIN" key gen-priv-key-json \
    --keyfile "${VAL_DIR}/story/priv_validator_key.json" >/dev/null

  INIT_TMP=$(mktemp -d)
  "$STORY_BIN" init --home "$INIT_TMP" --network local --force --clean \
    >/dev/null 2>&1 || true
  cp "${INIT_TMP}/config/node_key.json" "${VAL_DIR}/story/node_key.json"
  rm -rf "$INIT_TMP"

  openssl rand -hex 32 > "${VAL_DIR}/geth/nodekey"

  sed -e "s|${TEMPLATE_VAL}-geth|validator${K}-geth|g" \
      -e "s|^moniker = .*|moniker = \"localnet-val-${K}\"|" \
      -e "s|^external_address = .*|external_address = \"${NODE_IP}:26656\"|" \
      "${TEMPLATE_CACHE}/story/config.toml" > "${VAL_DIR}/story/config.toml"

  sed -e "s|${TEMPLATE_VAL}-geth|validator${K}-geth|g" \
      "${TEMPLATE_CACHE}/story/story.toml" > "${VAL_DIR}/story/story.toml"

  sed -e "s|${TEMPLATE_VAL}-geth|validator${K}-geth|g" \
      "${TEMPLATE_CACHE}/geth/geth.toml" > "${VAL_DIR}/geth/geth.toml"

  info=$("$STORY_BIN" key convert --validator-key-file "${VAL_DIR}/story/priv_validator_key.json")
  PUBKEY_B64=$(echo "$info" | awk -F': ' '/Compressed Public Key \(base64\)/ {print $2}')
  EVM_ADDR=$(echo "$info"   | awk -F': ' '/EVM Address/ {print $2}')
  VAL_BECH=$(echo "$info"   | awk -F': ' '/Validator Address/ {print $2}')
  DEL_BECH=$(echo "$info"   | awk -F': ' '/Delegator Address/ {print $2}')

  meta_entries+=("$(jq -nc \
    --arg index "$K" \
    --arg moniker "localnet-val-${K}" \
    --arg priv_key_hex "$PRIV" \
    --arg evm_address "$EVM_ADDR" \
    --arg validator_address "$VAL_BECH" \
    --arg delegator_address "$DEL_BECH" \
    --arg pubkey_base64 "$PUBKEY_B64" \
    --arg geth_ip "$GETH_IP" \
    --arg node_ip "$NODE_IP" \
    '{index: ($index|tonumber), moniker:$moniker, priv_key_hex:$priv_key_hex, evm_address:$evm_address, validator_address:$validator_address, delegator_address:$delegator_address, pubkey_base64:$pubkey_base64, geth_ip:$geth_ip, node_ip:$node_ip}')")

  printf 'val %2d  geth=%s  node=%s  val=%s\n' \
    "$K" "$GETH_IP" "$NODE_IP" "$VAL_BECH" >&2
done

printf '%s\n' "${meta_entries[@]}" | jq -s '.' > "$META_FILE"
echo "Wrote $N validator dirs + $META_FILE" >&2
