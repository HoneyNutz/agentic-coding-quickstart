#!/usr/bin/env bash
# Run on an OPERATOR workstation with the Azure CLI, not on the host.
# Imports the acq agent images into the private ACR and prints the digests to
# pin. `az acr import` runs server-side in Azure, so the host never talks to
# Docker Hub.
#
#   ./mirror-images.sh ACR_NAME [TAG_SUFFIX]
#
# Copy each printed digest to /etc/ai-sandbox/images/<agent>.digest on the host,
# then re-run configure-providers.sh with the ACR login server.
set -euo pipefail

acr=${1:?usage: mirror-images.sh ACR_NAME}
suffix=${2:-docker}

# acq agent token -> Docker sandbox-templates stem (acq.backends/agents.sh).
declare -A stems=([opencode]=opencode [codex]=codex [claude]=claude-code)

for agent in opencode codex claude; do
  src="docker.io/docker/sandbox-templates:${stems[$agent]}-$suffix"
  dst="sandbox-templates/$agent:${stems[$agent]}-$suffix"
  echo "importing $src -> $acr/$dst"
  az acr import --name "$acr" --source "$src" --image "$dst" --force >/dev/null
  digest=$(az acr repository show --name "$acr" --image "$dst" --query digest -o tsv)
  printf '%s\t%s\n' "$agent" "$digest"
done
