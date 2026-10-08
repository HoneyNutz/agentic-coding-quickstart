---
title: "Multi-Provider Generative LLM Endpoints and Bring Your Own Key (BYOK)"
status: accepted
date: 2026-10-07
decision_makers: ["Alex"]
category: architecture
nist_controls: ["AC-6", "CM-6", "IA-5", "SC-7", "SC-8"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0035: Multi-Provider Generative LLM Endpoints and Bring Your Own Key (BYOK)

## Context and Problem Statement

Originally, `acq` assumed that every sandboxed coding agent connected exclusively to
the GSA-hosted USAi gateway (`api.gsa.usai.gov`). That assumption was hardcoded across
four layers of the system:

1. **OpenCode Configuration Lock (`kit-translate.sh` / `usai-provider` kit):**
   The upstream `usai-provider` kit writes `~/.config/opencode/opencode.jsonc` with
   `"enabled_providers": ["usai"]`, which instructs OpenCode to hide and disable all
   other LLM providers (`openrouter`, `openai`, `anthropic`, `google`/`gemini`, and
   custom endpoints). Additionally, its `spec.yaml` only added `api.gsa.usai.gov` to
   `caps.network.allow`.
2. **Egress Network Allowlist (`acq.backends/msb-balanced-hosts.txt`):**
   While `msb-balanced-hosts.txt` already permitted `*.openai.com:443`,
   `api.anthropic.com:443`, and `generativelanguage.googleapis.com:443`, it did not
   include `openrouter.ai:443` or `**.openrouter.ai:443`, causing the microVM firewall
   to block outbound HTTPS requests to OpenRouter under `balanced` egress.
3. **Pre-Create / Pre-Attach Key Gates & Validation (`acq.backends/common.sh`):**
   `ensure_key_present`, `ensure_valid_key`, `check_key`, and `check_fresh_sandbox_key`
   checked only the `usai` secret and probed `https://api.gsa.usai.gov/api/v1/models`
   using `Authorization: Bearer $USAI_API_KEY`. Users with an OpenRouter, OpenAI,
   Anthropic, Gemini, or custom API key were blocked at `acq create` / `acq run`
   unless they also provided a USAi key.
4. **Backend Secret Injection (`acq.backends/msb.sh` & `acq.backends/sbx.sh`):**
   `_acq_msb_service_binding` and `_acq_msb_bind_secrets_into` in `msb.sh` only had
   compiled-in bindings for `usai` and `github`, and `_acq_service_hosts_env` /
   `acq_backend_key_present` in `sbx.sh` only handled `usai` and `github`.

We need `acq` to support **Bring Your Own Key (BYOK)** for any generative LLM endpoint
(`openrouter`, `openai`, `anthropic`, `gemini`, `usai`, or any `custom`
OpenAI-compatible endpoint) while preserving the sandbox security boundary (secrets
remain host-managed and are swapped on the wire via TLS interception / proxy, never
hardcoded into the guest image) and maintaining 100% backward compatibility with USAi.

## Decision

We introduce first-class multi-provider support across all four layers:

### 1. Active Provider Resolution (`acq.backends/common.sh`)

`acq_resolve_active_provider` resolves the active LLM provider using a clear
precedence order:

1. **CLI flag / environment variable:** `--provider <id>` (on `acq`, `acq run`,
   `acq create`) or `ACQ_PROVIDER=<id>`
2. **Persisted configuration:** `provider:` in `~/.config/acq/config.yaml` (written by
   `acq configure` or `acq configure --provider <id>`)
3. **Credential auto-detection:** If no provider is explicitly configured, `acq`
   checks the secret store and host environment in order: `usai` -> `openrouter` ->
   `openai` -> `anthropic` -> `gemini`
4. **Default fallback:** `usai`

`acq_provider_apply_active_facts` populates `ACQ_ACTIVE_PROVIDER_*` globals (`HOST`,
`BASE_URL`, `MODELS_URL`, `KEY_ENV`, `KEY_MGMT_URL`, `BIND_HOSTS`) for the active
provider:

| Provider ID | Default Host | Models Probe Endpoint | Injected Env Var |
|-------------|--------------|-----------------------|------------------|
| `usai` | `api.gsa.usai.gov` | `https://api.gsa.usai.gov/api/v1/models` | `USAI_API_KEY` |
| `openrouter` | `openrouter.ai` | `https://openrouter.ai/api/v1/models` | `OPENROUTER_API_KEY` |
| `openai` | `api.openai.com` | `https://api.openai.com/v1/models` | `OPENAI_API_KEY` |
| `anthropic` | `api.anthropic.com` | `https://api.anthropic.com/v1/models` | `ANTHROPIC_API_KEY` |
| `gemini` | `generativelanguage.googleapis.com` | `https://generativelanguage.googleapis.com/v1beta/openai/models` | `GEMINI_API_KEY` |
| `custom` | User-supplied (`--host`) | `<base-url>/models` (or `--models-url`) | User-supplied (`--env`) |

### 2. Kit Upgrade at Materialization (`acq.backends/kit-translate.sh`)

When `kit_translate_fetch` materializes a kit containing
`files/home/usai-config/opencode.jsonc`, `_kit_translate_upgrade_provider_kit`
automatically transforms it before the backend applies it:

- **Removes `"enabled_providers": ["usai"]`** from `opencode.jsonc` so OpenCode can
  use any configured provider (`openrouter`, `openai`, `anthropic`, `google`/`gemini`,
  `usai`, or `custom`).
- **Patches `merge-global-config.mjs`** so existing sandboxes that previously merged
  `enabled_providers: ["usai"]` into `~/.config/opencode/opencode.jsonc` have that
  single-provider lock removed on heal/startup.
- **Injects `"openrouter"` (and optional `"custom"`) provider definitions** into
  `opencode.jsonc` using `@ai-sdk/openai-compatible` and `{env:OPENROUTER_API_KEY}` /
  `{env:<CUSTOM_ENV>}`.
- **Extends `spec.yaml` `caps.network.allow`** with `openrouter.ai`,
  `api.openai.com`, `api.anthropic.com`, `generativelanguage.googleapis.com`, and any
  configured custom host.

### 3. Balanced Egress Allowlist (`acq.backends/msb-balanced-hosts.txt`)

Added `openrouter.ai:443` and `**.openrouter.ai:443` under `# --- AI services ---` in
`acq.backends/msb-balanced-hosts.txt`.

### 4. Backend Secret Bindings & Key Validation (`msb.sh`, `sbx.sh`, `common.sh`)

- **MSB (`acq.backends/msb.sh`):**
  - `_acq_msb_service_binding` maps `openrouter`, `openai`, `anthropic`, `gemini`, and
    `custom` (via sidecar or `ACQ_PROVIDER_HOST` + `ACQ_PROVIDER_KEY_ENV`) to their
    `ENV@HOST` bindings.
  - `_acq_msb_bind_secrets_into` (via `_acq_msb_bind_builtin_provider`) binds every
    provider secret present in the `acq` secret store or pre-exported in the host
    environment into the sandbox via `--secret ENV@HOST` at both `msb create` and
    `msb start`.
- **SBX (`acq.backends/sbx.sh`):**
  - `_acq_service_hosts_env` and `acq_backend_key_present` support `openrouter`,
    `gemini`, `openai`, `anthropic`, and `custom` (routing `openai` and `anthropic`
    through `sbx`'s native service secret table unless `--host` is overridden, and
    routing `openrouter`, `gemini`, `usai`, and `custom` through `sbx secret set-custom`).
- **Protocol-Aware Key Validation (`acq.backends/common.sh`):**
  - `check_key` and `check_fresh_sandbox_key` use
    `-H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01"` when
    validating `anthropic`, and `-H "Authorization: Bearer $<ENV>"` for OpenAI-compatible
    endpoints (`usai`, `openrouter`, `openai`, `gemini`, `custom`).
- **CLI Ergonomics (`acq`):**
  - Added `--provider <id>` global and `run`/`create` flag.
  - Extended `acq configure` with non-interactive `--provider <id> [--host ... --base-url ... --models-url ... --env ...]` flags and an interactive provider prompt.
  - Added `acq rotate-api-key [PROVIDER]` alongside `acq usai-rotate-api-key`.
  - Extended `acq secret import` (`ACQ_MANAGED_SECRET_SERVICES`) to import
    `OPENROUTER_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and
    `GEMINI_API_KEY` / `GOOGLE_API_KEY` from the host environment.

## Consequences

- **Positive:** Users can bring their own API keys for OpenRouter, OpenAI, Anthropic,
  Gemini, or any custom OpenAI-compatible gateway without losing `acq`'s microVM/container
  isolation or host-side secret substitution.
- **Positive:** Existing USAi workflows, CLI commands, and Bats tests remain 100%
  backward-compatible.
- **Neutral:** Because `_kit_translate_upgrade_provider_kit` upgrades the fetched
  `usai-provider` kit on the fly during `kit_translate_fetch`, `acq` does not need to
  fork or unpin the upstream `agentic-coding-patterns` repository to unlock multi-provider
  support in OpenCode.
