#!/usr/bin/env bash
# Run on an OPERATOR workstation with the Azure CLI, from a checkout of this
# repository at the same commit the host pins (acqCommitSha), not on the host.
# Imports the acq agent images into the private ACR and prints the digests to
# pin. `az acr import` runs server-side in Azure, so the host never talks to
# Docker Hub or ghcr.io.
#
#   ./mirror-images.sh ACR_NAME
#
# Copy each printed digest to /etc/ai-sandbox/images/<agent>.digest on the host,
# then re-run configure-providers.sh with the ACR login server.
set -euo pipefail

acr=${1:?usage: mirror-images.sh ACR_NAME}
agents_sh="$(cd "$(dirname "$0")/../.." && pwd)/acq.backends/agents.sh"

# opencode boots the digest-pinned devenv image acq defaults to; read it from
# acq itself so the mirror always matches the pinned acq commit.
opencode_src=$(sed -n 's/^ACQ_DEFAULT_OPENCODE_DEVENV_IMAGE="\(.*\)"$/\1/p' "$agents_sh")
[[ "$opencode_src" == *@sha256:* ]] || { echo "could not read ACQ_DEFAULT_OPENCODE_DEVENV_IMAGE from $agents_sh" >&2; exit 1; }

# codex and claude still use Docker's sandbox-templates (acq_agent_template_image
# in acq.backends/agents.sh). Those are tags, so the digest printed below is
# what gets pinned.
declare -A sources=(
  [opencode]="$opencode_src"
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
