# AI Cyber Sandbox Infrastructure

A hardened Azure host for testing AI coding agents that are treated as
**adversarial**. Agents (`opencode`, `codex`, `claude`) run inside disposable
`msb` microVMs driven by [`acq`](https://github.com/HoneyNutz/agentic-coding-quickstart),
on a RHEL 9 VM with nested KVM, talking only to your own Azure Foundry model
endpoints over Private Endpoints.

Why not Windows: `msb` needs hardware virtualization. Inside a Windows VM that
means WHP over nested virtualization, which is a preview path upstream and
the source of "machine isn't ready to run microVMs" errors. Linux + KVM is the
path the project validates.

## Layout

| Path | What it is |
|------|------------|
| `bicep/main.bicep` | Entry point: network, Bastion, Foundry, ACR, monitoring, VM, budget |
| `bicep/modules/` | One module per concern |
| `bicep/main.example.bicepparam` | Parameters to copy and fill in |
| `host/` | cloud-init, host bootstrap, `sandbox-run` wrapper, auditd rules |
| `scripts/` | Provider setup, image mirroring, key rotation, emergency isolation |
| `docs/ARCHITECTURE.md` | The design decisions and the layers of containment |
| `docs/VALIDATION.md` | Checklist to run before the first adversarial test |
| `docs/RUNBOOK-escape.md` | What to do when you suspect an escape |

## Deploy

Run every command below from this `infra/` directory.

Prerequisites: Azure CLI with Bicep, Owner on a resource group, an Entra ID
group for operators, and Foundry model quota in your region for the models in
`foundryAccounts`.

```bash
cp bicep/main.example.bicepparam bicep/main.bicepparam   # then edit it
ssh-keygen -t ed25519 -N '' -f /tmp/breakglass && cat /tmp/breakglass.pub   # paste into the param file
```

1. **Bootstrap deployment** (egress open so the host can reach RHUI, GitHub and
   the msb release):

   ```bash
   az deployment group create -g RG -f bicep/main.bicep -p bicep/main.bicepparam -p setupEgressOpen=true
   ```

2. **Delete the throwaway private key.** The bootstrap locks that account; no
   one should be able to use it:

   ```bash
   shred -u /tmp/breakglass
   ```

3. **Check the bootstrap.** Connect through Bastion with Entra ID, then
   confirm `/var/lib/ai-sandbox/READY` exists (if not, `NOT_READY` says why):

   ```bash
   az network bastion ssh -g RG -n PREFIX-bastion --target-resource-id VM_ID --auth-type AAD
   ```

4. **Mirror the agent images** from your workstation and record the digests:

   ```bash
   scripts/mirror-images.sh ACR_NAME
   ```

5. **Configure providers and keys** on the host (PIM-activated admin):

   ```bash
   sudo scripts/configure-providers.sh OPENCODE_SUB CODEX_SUB CLAUDE_SUB ACR_LOGIN_SERVER
   ```

6. **Lock down egress:**

   ```bash
   az deployment group create -g RG -f bicep/main.bicep -p bicep/main.bicepparam -p setupEgressOpen=false
   ```

7. **Run every check in [docs/VALIDATION.md](docs/VALIDATION.md)**, then
   snapshot the OS disk as the golden image.

## Run a test

```bash
sudo -u ai-sandbox sandbox-run opencode
sudo -u ai-sandbox sandbox-run claude --seed vuln-webapp
```

Each run is a fresh microVM with an empty (or seeded) workspace, `strict`
egress, a host-side transcript in `/var/log/ai-sandbox/runs/`, and is destroyed
on exit. Seeds are root-owned directories under `/var/lib/ai-sandbox/targets/`.

After each campaign: `scripts/rotate-keys.sh RG`, re-store keys, and rebuild
the VM from the golden image.
