#!/usr/bin/env bash
# Regenerates BOTH keys on every agent's Foundry account, invalidating any key
# a model may have seen. Run after every test campaign and in step 4 of
# docs/RUNBOOK-escape.md. Then store the new key1 on the host with
# configure-providers.sh (or after the rebuild).
#
#   ./rotate-keys.sh RESOURCE_GROUP
set -euo pipefail

rg=${1:?usage: rotate-keys.sh RESOURCE_GROUP}

accounts=$(az cognitiveservices account list -g "$rg" \
  --query "[?tags.workload=='ai-cyber-sandbox'].name" -o tsv)
[ -n "$accounts" ] || { echo "no ai-cyber-sandbox Foundry accounts in $rg" >&2; exit 1; }

for acct in $accounts; do
  for key in key1 key2; do
    az cognitiveservices account keys regenerate -g "$rg" -n "$acct" --key-name "$key" -o none
  done
  echo "rotated both keys on $acct"
done
