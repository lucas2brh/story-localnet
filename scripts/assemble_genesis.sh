#!/bin/bash
# Assemble config/story/genesis-node.json with N validators from
# tmp/validators_meta.json + distribution.json. Replaces auth.accounts,
# bank.balances, genutil.gen_txs, bank.supply, staking.params.max_validators,
# staking.params.singularity_height.
#
# Usage: ./assemble_genesis.sh [N]
#
# Inputs (relative to repo root):
#   distribution.json          (from fetch_mainnet_distribution.sh)
#   tmp/validators_meta.json   (from generate_N_validators.sh)
# Output:
#   config/story/genesis-node.json  (in-place rewrite)

set -euo pipefail

N=${1:-20}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENESIS="${REPO_ROOT}/config/story/genesis-node.json"
DIST="${REPO_ROOT}/distribution.json"
META="${REPO_ROOT}/tmp/validators_meta.json"
MAX_VALIDATORS_INIT=${MAX_VALIDATORS_INIT:-$N}
SINGULARITY_HEIGHT=${SINGULARITY_HEIGHT:-0}

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }
[ -f "$GENESIS" ] || { echo "ERROR: $GENESIS missing (restore from git)" >&2; exit 1; }
[ -f "$DIST" ]    || { echo "ERROR: $DIST missing — run fetch_mainnet_distribution.sh first" >&2; exit 1; }
[ -f "$META" ]    || { echo "ERROR: $META missing — run generate_N_validators.sh first" >&2; exit 1; }

meta_len=$(jq 'length' "$META")
dist_len=$(jq 'length' "$DIST")
if [ "$meta_len" != "$N" ] || [ "$dist_len" != "$N" ]; then
  echo "ERROR: meta($meta_len)/dist($dist_len) size != N($N)" >&2
  exit 1
fi

ZIP=$(jq -s --argjson n "$N" '
  .[0] as $dist | .[1] as $meta
  | [range($n) | {
      index: (. + 1),
      tokens: ($dist[.].tokens | tostring),
      moniker: $meta[.].moniker,
      delegator_address: $meta[.].delegator_address,
      validator_address: $meta[.].validator_address,
      pubkey_base64: $meta[.].pubkey_base64
    }]
' "$DIST" "$META")

ACCOUNTS=$(echo "$ZIP" | jq '
  [.[] | {
    "@type": "/cosmos.auth.v1beta1.BaseAccount",
    address: .delegator_address,
    pub_key: null,
    account_number: ((.index - 1) | tostring),
    sequence: "0"
  }]
')

BALANCES=$(echo "$ZIP" | jq '
  [.[] | {
    address: .delegator_address,
    coins: [{denom: "stake", amount: .tokens}]
  }]
')

GEN_TXS=$(echo "$ZIP" | jq '
  [.[] | {
    body: {
      messages: [{
        "@type": "/cosmos.staking.v1beta1.MsgCreateValidator",
        description: {
          moniker: .moniker,
          identity: "",
          website: "",
          security_contact: "",
          details: ""
        },
        commission: {
          rate: "0.070000000000000000",
          max_rate: "0.100000000000000000",
          max_change_rate: "0.010000000000000000"
        },
        min_self_delegation: "1024000000000",
        delegator_address: .delegator_address,
        validator_address: .validator_address,
        pubkey: {
          "@type": "/cosmos.crypto.secp256k1.PubKey",
          key: .pubkey_base64
        },
        value: {denom: "stake", amount: .tokens},
        support_token_type: 0
      }],
      memo: "",
      timeout_height: "0",
      extension_options: [],
      non_critical_extension_options: []
    },
    auth_info: {
      signer_infos: [],
      fee: {amount: [], gas_limit: "0", payer: "", granter: ""},
      tip: null
    },
    signatures: []
  }]
')

TOTAL_SUPPLY=$(echo "$ZIP" | python3 -c "import json,sys; print(sum(int(v['tokens']) for v in json.load(sys.stdin)))")

tmp_out=$(mktemp)
jq \
  --argjson accounts "$ACCOUNTS" \
  --argjson balances "$BALANCES" \
  --argjson gen_txs "$GEN_TXS" \
  --arg supply "$TOTAL_SUPPLY" \
  --argjson max_validators "$MAX_VALIDATORS_INIT" \
  --arg singularity "$SINGULARITY_HEIGHT" \
  '
  .app_state.auth.accounts = $accounts
  | .app_state.bank.balances = $balances
  | .app_state.genutil.gen_txs = $gen_txs
  | .app_state.bank.supply = [{denom: "stake", amount: $supply}]
  | .app_state.staking.params.max_validators = $max_validators
  | .app_state.staking.params.singularity_height = $singularity
  | .app_state.staking.delegations = []
  | .app_state.staking.last_validator_powers = []
  ' "$GENESIS" > "$tmp_out"

mv "$tmp_out" "$GENESIS"

echo "Rewrote $GENESIS: $N validators, supply=$TOTAL_SUPPLY, max_validators=$MAX_VALIDATORS_INIT, singularity_height=$SINGULARITY_HEIGHT" >&2
