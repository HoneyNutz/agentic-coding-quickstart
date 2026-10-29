# Architecture

## Threat model

The model under test is **adversarial**: assume it will try to escape the
sandbox, read secrets, exfiltrate data, persist, and tamper with evidence.
Every control below assumes the layer inside it has already failed.

## Layers of containment (outermost first)

1. **Azure network.** The host has no public IP. Inbound is SSH from the
   Bastion subnet only. Outbound is denied to the Internet and to the rest of
   the VNet, except HTTPS to the Private Endpoint subnet and Entra ID
   (`AzureActiveDirectory` service tag, needed for sign-in). The Internet allow
   rules exist only while `setupEgressOpen=true`. A NAT gateway is the host's
   only route out; the NSG decides what may use it.
2. **Private Endpoints.** Foundry, ACR and Azure Monitor have public network
   access disabled. Even a fully compromised host can reach only these, and
   only with the keys it holds.
3. **Host hardening.** RHEL 9 with SELinux enforcing, auditd shipped off-host,
   a locked local admin, and a dedicated `ai-sandbox` service account that owns
   `acq`, `msb` and the secret store. Operators can run exactly one command as
   that account: `sandbox-run`.
4. **microVM boundary.** Every run is a separate `msb` microVM (KVM) with its
   own guest kernel, not a container sharing the host kernel.
5. **Pinned guest egress.** `strict` alone is deny-by-default plus the union of
   every applied kit's allow-list, which still includes every known LLM
   provider, GitHub and npm. `sandbox-run` therefore sets `ACQ_EGRESS_PIN` to the
   agent's own Foundry host: after all kits have contributed, acq drops every
   other allow rule, keeps only DNS and that host, and denies inbound
   connections. Opt-in kits are refused and the host ssh-agent is never
   forwarded. Model API keys are injected on the host into requests to that one
   host; the guest only ever sees a placeholder.
6. **Disposable workspaces.** `--clone`, a fresh empty workspace per run, no
   host repos mounted, everything destroyed on exit. Agent output is untrusted
   and is reviewed on a separate machine, never executed on the host.

## Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Host OS | RHEL 9 (latest minor), PAYG image | glibc + KVM is acq's supported Linux path; RHEL is the org standard. Not upstream-validated: see VALIDATION.md |
| VM | `Standard_D8s_v5`, Trusted Launch or Standard | Supports nested virtualization; never a Confidential VM |
| SELinux | Enforcing, targeted modules for real denials | Extra layer against an escaped guest |
| Agents | `opencode` (primary), `codex`, `claude` | One Foundry account per agent |
| Guest egress | `strict` tier + `ACQ_EGRESS_PIN` = the agent's Foundry host | `strict` alone allows every kit's hosts; the pin is applied last, so kit changes cannot widen it |
| Model auth | API keys, host-side injection | Guest never holds a key or an identity; Entra tokens expire hourly |
| Keys | One Foundry account per agent | An account has only two keys; separate accounts give each agent its own revocable key and quota |
| Quotas | Per-deployment TPM capacity | Caps token burn by a runaway agent |
| Images | Docker `sandbox-templates` with the agent prebuilt, mirrored to private ACR, pinned by digest | Host never talks to Docker Hub; images cannot change between runs; acq's default opencode base installs opencode from npm at first boot, which pinned egress blocks |
| Reset | Fresh sandbox per run, golden-image rebuild per campaign | Nothing persists between runs or campaigns |
| Logs | AMA -> DCE -> Log Analytics over AMPLS (PrivateOnly) | Evidence leaves the host before a model can touch it |
| Access | Entra ID via Bastion; standing "VM User Login", JIT "VM Administrator Login" via PIM | No SSH keys, no standing sudo |
| Cost | Budget alerts, nightly auto-shutdown, `maxSandboxes` cap | Bounds compute and spend |
| Code | `infra/` in the acq fork; the host still installs acq by pinned commit SHA | One repo to review; the deployed acq version never floats |

## Just-in-time admin (PIM)

Bicep grants only standing **Virtual Machine User Login** to the operators
group. Make **Virtual Machine Administrator Login** PIM-eligible on the VM for
named admins (requires Entra ID P2), with approval and a short activation
window, in the Azure portal under *Privileged Identity Management > Azure
resources*.

## What remains to verify

These could not be confirmed ahead of time and are covered in VALIDATION.md:

- Nested virtualization with Trusted Launch on the chosen size (fall back to
  `securityType=Standard` if `/dev/kvm` is missing).
- The Foundry model names, versions and `Anthropic` format for Claude in your
  region and subscription.
- `msb` under SELinux enforcing on RHEL (no upstream testing).
- That `acq`'s custom-provider path works with the Azure endpoints for each
  agent, including Claude Code against Foundry's Anthropic endpoint.
- That `az acr import` works with registry public access disabled; if not,
  temporarily allow the operator IP during mirroring.
