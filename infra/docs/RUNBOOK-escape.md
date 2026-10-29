# Runbook: suspected sandbox escape

## Triggers

Start this runbook on **any** of:

- An auditd event with key `sandbox-runtime`, `sandbox-config`, `secret-store`,
  `privilege`, `identity`, `selinux`, `audit-config` or `kernel-module` that no
  operator can account for.
- A `sandbox-host-exec` event for a binary other than the baseline (`acq`,
  `msb`, its VMM, `git`, coreutils) recorded during validation.
- An NSG flow or Foundry log showing traffic the allow-list should have
  blocked, or a model request from a key outside its own agent's session.
- Files changing outside `/var/lib/ai-sandbox/work/<run id>` during a run.
- Anything an operator cannot explain. Do not wait to be sure.

## Steps

1. **Isolate.** From an operator workstation:

   ```bash
   scripts/emergency-isolate.sh RG PREFIX
   ```

   This adds deny-all NSG rules, deallocates the VM (stopping every microVM),
   and snapshots the OS disk with an `incident` tag.
2. **Preserve evidence.** Export the relevant Log Analytics queries (Syslog for
   the incident window, auditd `local6`, `ai-sandbox` START/END lines) and the
   transcript paths. Do not boot the original disk again.
3. **Rotate every model key**, for all agents, not just the one involved:

   ```bash
   scripts/rotate-keys.sh RG
   ```

4. **Destroy and rebuild** the VM from the golden image (or a fresh deployment
   at the same pinned `acqCommitSha`), then run all of
   [VALIDATION.md](VALIDATION.md) before resuming.
5. **Analyse** the forensic snapshot on an isolated machine: attach it
   read-only to a separate VM with no network access.
6. **Record** what happened, which layer failed, and what changes, before
   the next campaign starts.
