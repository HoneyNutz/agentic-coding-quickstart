# Validation checklist

Run every check after lockdown (`setupEgressOpen=false`) and before the first
adversarial test. Record the output; a check that is not run counts as failed.
Re-run after every rebuild and every acq or msb version change.

## Host

- [ ] `test -c /dev/kvm && cat /var/lib/ai-sandbox/READY` prints a timestamp.
- [ ] `sudo -u ai-sandbox -H ~ai-sandbox/.local/bin/msb doctor` passes.
- [ ] `getenforce` prints `Enforcing`.
- [ ] `sudo ausearch -m AVC -ts boot` is empty, or every denial has a reviewed
      policy module (`audit2allow -M`); never switch to permissive.
- [ ] `sudo -l` as an operator shows only `(ai-sandbox) NOPASSWD: /usr/local/bin/sandbox-run`.
- [ ] `sudo passwd -S breakglass` shows the account locked (`LK`).
- [ ] `git -C /opt/ai-sandbox/acq-src rev-parse HEAD` equals the pinned `acqCommitSha`.

## Network (from the host)

- [ ] `curl -sS -m 5 https://example.com` **fails**.
- [ ] `curl -sS -m 5 https://registry-1.docker.io` **fails**.
- [ ] `getent hosts SUB.openai.azure.com` resolves to a `10.42.0.32/27` address
      for each Foundry account; same for the ACR login server.
- [ ] `curl -sS -m 5 -o /dev/null -w '%{http_code}' https://SUB.openai.azure.com/` returns an HTTP code (reachable privately).

## Sandbox (inside a `sandbox-run shell`-style session)

For each agent, start `sudo -u ai-sandbox sandbox-run AGENT` and from inside
the guest:

- [ ] The agent completes a prompt against its Foundry deployment.
- [ ] `printenv` shows a placeholder, not the real key, for the key variable.
- [ ] `curl -m 5 https://example.com` fails.
- [ ] `curl -m 5 https://OTHER_SUB.openai.azure.com` (another agent's account) fails.
- [ ] `curl -m 5 http://168.63.129.16` and `http://169.254.169.254` fail
      (no Azure wireserver or IMDS from the guest).
- [ ] After exit, `acq ls` no longer lists the sandbox and the workspace under
      `/var/lib/ai-sandbox/work/` is gone.
- [ ] A transcript exists in `/var/log/ai-sandbox/runs/`.

## Logs (in Log Analytics)

- [ ] `Syslog | where SyslogMessage has "ai-sandbox" | take 20` shows the
      START/END lines for the runs above.
- [ ] `Syslog | where Facility == "local6" | take 20` shows auditd events.
- [ ] Touching `/etc/ai-sandbox/sandbox.conf` as admin produces a
      `sandbox-config` audit event within a few minutes.

## Limits

- [ ] Starting `maxSandboxes + 1` concurrent runs: the extra one is refused.
- [ ] A Foundry deployment returns HTTP 429 once its TPM quota is exceeded.
- [ ] The budget and the auto-shutdown schedule exist in the portal.

When everything passes, deallocate the VM and snapshot its OS disk as the
golden image.
