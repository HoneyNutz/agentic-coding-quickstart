#!/usr/bin/env bash
# Run on an OPERATOR workstation with the Azure CLI, not on the host.
# Imports the acq agent images into the private ACR and prints the digests to
# pin. `az acr import` runs server-side in Azure, so the host never talks to
# Docker Hub.
#
#   ./mirror-images.sh ACR_NAME
#
# Copy each printed digest to /etc/ai-sandbox/images/<agent>.digest on the host,
# then re-run configure-providers.sh with the ACR login server.
set -euo pipefail

acr=${1:?usage: mirror-images.sh ACR_NAME}
# Every image must already contain its agent. acq's default opencode base
# (the devenv image) installs opencode from npm on first boot, which the
# locked-down host cannot reach, so opencode uses Docker's prebuilt template
# like codex and claude. Templates are tags, so the digest printed below is
# what gets pinned.
declare -A sources=(
  [opencode]="docker.io/docker/sandbox-templates:opencode-docker"
  [codex]="docker.io/docker/sandbox-templates:codex-docker"
  [claude]="docker.io/docker/sandbox-templates:claude-code-docker"
)

for agent in opencode codex claude; do
  src=${sources[$agent]}
  dst="sandbox-templates/$agent:mirrored"
  echo "importing $src -> $acr/$dst"
  az acr import --name "$acr" --source "$src" --image "$dst" --force >/dev/null
  digest=$(az acr repository show --name "$acr" --image "$dst" --query digest -o tsv)
  printf '%s\t%s\n' "$agent" "$digest"
done
