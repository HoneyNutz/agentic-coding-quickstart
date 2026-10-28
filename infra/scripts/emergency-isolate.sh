#!/usr/bin/env bash
# Step 1-3 of docs/RUNBOOK-escape.md, from an operator workstation.
# Cuts ALL host network traffic, deallocates the VM, and takes a forensic
# snapshot of its OS disk. Destructive to running sessions by design.
#
#   ./emergency-isolate.sh RESOURCE_GROUP PREFIX
set -euo pipefail

rg=${1:?usage: emergency-isolate.sh RESOURCE_GROUP PREFIX}
prefix=${2:?usage: emergency-isolate.sh RESOURCE_GROUP PREFIX}
nsg="$prefix-nsg-host"
vm="$prefix-host"
stamp=$(date -u +%Y%m%dT%H%M%SZ)

echo "[1/3] Denying all traffic on $nsg (priority 50, above every allow rule)"
for dir in Inbound Outbound; do
  az network nsg rule create -g "$rg" --nsg-name "$nsg" -n "IncidentDenyAll$dir" \
    --priority 50 --direction "$dir" --access Deny --protocol '*' \
    --source-address-prefixes '*' --destination-address-prefixes '*' \
    --source-port-ranges '*' --destination-port-ranges '*' -o none
done

echo "[2/3] Deallocating $vm (stops every microVM with it)"
az vm deallocate -g "$rg" -n "$vm" -o none

echo "[3/3] Snapshotting the OS disk for forensics"
disk=$(az vm show -g "$rg" -n "$vm" --query storageProfile.osDisk.managedDisk.id -o tsv)
az snapshot create -g "$rg" -n "$vm-forensic-$stamp" --source "$disk" \
  --tags incident="$stamp" -o none

echo "Isolated. Continue with step 4 (rotate keys) in docs/RUNBOOK-escape.md."
