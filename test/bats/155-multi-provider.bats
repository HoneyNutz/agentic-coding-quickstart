#!/usr/bin/env bats
#
# 155-multi-provider.bats — multi-provider generative LLM endpoint support
# (usai, openrouter, openai, anthropic, gemini, custom)
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "provider: default active provider is usai when nothing is configured or stored" {
  load_acq
  run acq_resolve_active_provider
  assert_success
  assert_output "usai"
}

@test "provider: ACQ_PROVIDER overrides default and config.yaml" {
  load_acq
  _acq_config_write_field provider "openai"
  ACQ_PROVIDER=openrouter run acq_resolve_active_provider
  assert_success
  assert_output "openrouter"
}

@test "provider: config.yaml provider is honored when ACQ_PROVIDER is unset" {
  load_acq
  _acq_config_write_field provider "anthropic"
  run acq_resolve_active_provider
  assert_success
  assert_output "anthropic"
}

@test "provider: auto-detects stored openrouter key when usai is absent" {
  load_acq
  mkdir -p "$STUBDIR/secrets"
  printf 'sk-or-test\n' > "$STUBDIR/secrets/acq.openrouter"
  run acq_resolve_active_provider
  assert_success
  assert_output "openrouter"
}

@test "provider: acq_provider_apply_active_facts populates openrouter, openai, anthropic, gemini, custom" {
  load_acq
  acq_provider_apply_active_facts openrouter
  assert_equal "$ACQ_ACTIVE_PROVIDER" "openrouter"
  assert_equal "$ACQ_ACTIVE_PROVIDER_HOST" "openrouter.ai"
  assert_equal "$ACQ_ACTIVE_PROVIDER_BASE_URL" "https://openrouter.ai/api/v1"
  assert_equal "$ACQ_ACTIVE_PROVIDER_MODELS_URL" "https://openrouter.ai/api/v1/models"
  assert_equal "$ACQ_ACTIVE_PROVIDER_KEY_ENV" "OPENROUTER_API_KEY"

  acq_provider_apply_active_facts openai
  assert_equal "$ACQ_ACTIVE_PROVIDER_HOST" "api.openai.com"
  assert_equal "$ACQ_ACTIVE_PROVIDER_KEY_ENV" "OPENAI_API_KEY"

  acq_provider_apply_active_facts anthropic
  assert_equal "$ACQ_ACTIVE_PROVIDER_HOST" "api.anthropic.com"
  assert_equal "$ACQ_ACTIVE_PROVIDER_KEY_ENV" "ANTHROPIC_API_KEY"

  acq_provider_apply_active_facts gemini
  assert_equal "$ACQ_ACTIVE_PROVIDER_HOST" "generativelanguage.googleapis.com"
  assert_equal "$ACQ_ACTIVE_PROVIDER_KEY_ENV" "GEMINI_API_KEY"

  ACQ_PROVIDER_HOST="llm.internal.example.org" \
  ACQ_PROVIDER_BASE_URL="https://llm.internal.example.org/v1" \
  ACQ_PROVIDER_KEY_ENV="INTERNAL_LLM_KEY" \
    acq_provider_apply_active_facts custom
  assert_equal "$ACQ_ACTIVE_PROVIDER" "custom"
  assert_equal "$ACQ_ACTIVE_PROVIDER_HOST" "llm.internal.example.org"
  assert_equal "$ACQ_ACTIVE_PROVIDER_MODELS_URL" "https://llm.internal.example.org/v1/models"
  assert_equal "$ACQ_ACTIVE_PROVIDER_KEY_ENV" "INTERNAL_LLM_KEY"
}

@test "kit-translate: upgrades usai-provider kit to multi-provider (removes enabled_providers lock, adds openrouter + egress)" {
  load_acq
  local kitdir="$STUBDIR/mock-usai-kit"
  mkdir -p "$kitdir/files/home/usai-config"
  cat > "$kitdir/spec.yaml" <<'YAML'
schemaVersion: "hybrid/v1"
kind: mixin
name: usai-provider
displayName: USAi Provider
description: test
caps:
  network:
    mode: balanced
    allow:
      - api.gsa.usai.gov
YAML
  cat > "$kitdir/files/home/usai-config/opencode.jsonc" <<'JSONC'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "usai/claude-haiku-4-5",
  "enabled_providers": ["usai"],
  "provider": {
    "usai": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "USAi",
      "options": {
        "baseURL": "https://api.gsa.usai.gov/api/v1",
        "apiKey": "{env:USAI_API_KEY}"
      }
    }
  }
}
JSONC
  cat > "$kitdir/files/home/usai-config/merge-global-config.mjs" <<'MJS'
const kit = JSON.parse('{}');
const merged = {
  ...existing,
  model: existing.model ?? kit.model,
  enabled_providers: existing.enabled_providers ?? kit.enabled_providers,
  provider: {},
};
MJS

  _kit_translate_upgrade_provider_kit "$kitdir"

  # 1) enabled_providers lock removed from opencode.jsonc; openrouter provider added
  run grep -c '"enabled_providers"' "$kitdir/files/home/usai-config/opencode.jsonc"
  assert_output "0"
  run grep -c '"openrouter"' "$kitdir/files/home/usai-config/opencode.jsonc"
  assert_output "1"
  run grep -c 'https://openrouter.ai/api/v1' "$kitdir/files/home/usai-config/opencode.jsonc"
  assert_output "1"

  # 2) merge-global-config.mjs deletes legacy enabled_providers lock
  run grep -c 'delete merged.enabled_providers' "$kitdir/files/home/usai-config/merge-global-config.mjs"
  assert_output "1"

  # 3) spec.yaml network allowlist includes openrouter.ai, api.openai.com, api.anthropic.com, generativelanguage.googleapis.com
  run grep -c 'openrouter.ai' "$kitdir/spec.yaml"
  assert_output "1"
  run grep -c 'api.openai.com' "$kitdir/spec.yaml"
  assert_output "1"
  run grep -c 'api.anthropic.com' "$kitdir/spec.yaml"
  assert_output "1"
  run grep -c 'generativelanguage.googleapis.com' "$kitdir/spec.yaml"
  assert_output "1"
}

@test "msb: balanced hosts allowlist includes openrouter.ai" {
  run grep -E '^(\*\*\.)?openrouter\.ai:443$' "$REPO_ROOT/acq.backends/msb-balanced-hosts.txt"
  assert_success
  assert_line "openrouter.ai:443"
  assert_line "**.openrouter.ai:443"
}

@test "msb: secret set and provision bind openrouter, openai, anthropic, and gemini" {
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/mp-secrets"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    printf "OR-VAL\n"  | acq_secret_store "$(_acq_secret_key openrouter)"
    printf "OA-VAL\n"  | acq_secret_store "$(_acq_secret_key openai)"
    printf "AN-VAL\n"  | acq_secret_store "$(_acq_secret_key anthropic)"
    printf "GM-VAL\n"  | acq_secret_store "$(_acq_secret_key gemini)"
    arr=(); names=()
    _acq_msb_bind_secrets_into arr names mpbox
    printf "%s\n" "${arr[@]}"
  '
  assert_success
  assert_line "OPENROUTER_API_KEY@openrouter.ai"
  assert_line "OPENAI_API_KEY@api.openai.com"
  assert_line "ANTHROPIC_API_KEY@api.anthropic.com"
  assert_line "GEMINI_API_KEY@generativelanguage.googleapis.com"
  refute_output --partial "OR-VAL"
}

@test "sbx: secret set -g openrouter routes to set-custom with openrouter.ai and OPENROUTER_API_KEY" {
  run bash -c 'printf "sk-or-123\n" | ACQ_BACKEND=sbx "$1" secret set -g openrouter' _ "$ACQ"
  assert_success
  assert_output --partial 'sbx secret set-custom --host openrouter.ai --env OPENROUTER_API_KEY'
  assert [ -f "$STUBDIR/secrets/acq.openrouter" ]
}

@test "configure: --provider openrouter and --provider custom persist to config.yaml" {
  run env ACQ_BACKEND=msb "$ACQ" configure --provider openrouter
  assert_success
  assert_output --partial "configured LLM provider 'openrouter'"

  run env ACQ_BACKEND=msb "$ACQ" configure --provider custom \
    --host llm.example.com --base-url https://llm.example.com/v1 --env LLM_KEY
  assert_success
  assert_output --partial "configured LLM provider 'custom'"

  load_acq
  assert_equal "$(_acq_config_read_field provider)" "custom"
  assert_equal "$(_acq_config_read_field provider_host)" "llm.example.com"
  assert_equal "$(_acq_config_read_field provider_base_url)" "https://llm.example.com/v1"
  assert_equal "$(_acq_config_read_field provider_key_env)" "LLM_KEY"
}

@test "check_key: uses x-api-key and anthropic-version for anthropic, Bearer for openrouter" {
  load_acq
  export SBX_EXEC_CURL_STATUS=200
  run check_key mybox openrouter
  assert_success
  assert_output "200"
  assert_regex "$(cat "$CALLS")" 'Authorization: Bearer \$OPENROUTER_API_KEY.*https://openrouter\.ai/api/v1/models'

  : > "$CALLS"
  run check_key mybox anthropic
  assert_success
  assert_output "200"
  assert_regex "$(cat "$CALLS")" 'x-api-key: \$ANTHROPIC_API_KEY.*anthropic-version: 2023-06-01.*https://api\.anthropic\.com/v1/models'
}
