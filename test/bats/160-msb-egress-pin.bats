#!/usr/bin/env bats
#
# 160-msb-egress-pin.bats — ACQ_EGRESS_PIN makes a pinned host list the final
# word on msb guest egress, regardless of what the applied kits allow-list.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Provision NAME with a stub kit that allow-lists several hosts, as the real
# provider/playbook/agent kits do. PRE is extra shell run before provision.
_provision_wide_kit() { # NAME PRE_SNIPPET
  local name="$1" pre="$2"
  : > "$CALLS"
  run bash -c '
    name="$1"; pre="$2"
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    eval "$pre"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mkdir -p "'"$STUBDIR"'/widekit"
    printf "%s\n" "schemaVersion: \"hybrid/v1\"" "kind: mixin" "name: wide" \
      "displayName: Wide" "description: x" "caps:" "  network:" "    allow:" \
      "      - api.openai.com" "      - registry.npmjs.org" "      - raw.githubusercontent.com" \
      "      - pinned.openai.azure.com" > "'"$STUBDIR"'/widekit/spec.yaml"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/widekit"; }
    acq_backend_provision "$name" shell /tmp 2>&1 >/dev/null
  ' _ "$name" "$pre"
}

@test "egress pin: without a pin, strict keeps every kit host" {
  _provision_wide_kit nopin 'export ACQ_NETWORK_TIER=strict'
  local log; log=$(grep 'msb create' "$CALLS")
  assert_regex "$log" 'allow@api\.openai\.com'
  assert_regex "$log" 'allow@registry\.npmjs\.org'
  refute_regex "$log" '--net-default-ingress deny'
}

@test "egress pin: only pinned hosts and DNS survive, ingress is denied" {
  _provision_wide_kit pinned 'export ACQ_NETWORK_TIER=strict ACQ_EGRESS_PIN=pinned.openai.azure.com'
  # The stub kit stands in for every built-in kit, so each unpinned host is
  # dropped once per kit and the pinned host must still be emitted only once.
  assert_output --regexp 'egress pinned to: pinned\.openai\.azure\.com \(dropped [1-9][0-9]* kit rule\(s\)\)'
  local log; log=$(grep 'msb create' "$CALLS")
  assert_equal "$(grep -o 'allow@pinned\.openai\.azure\.com' <<<"$log" | wc -l | tr -d ' ')" 1
  assert_regex "$log" '--net-default-egress deny'
  assert_regex "$log" '--net-rule allow@dns'
  assert_regex "$log" '--net-rule allow@pinned\.openai\.azure\.com'
  assert_regex "$log" '--net-default-ingress deny'
  refute_regex "$log" 'allow@api\.openai\.com'
  refute_regex "$log" 'allow@registry\.npmjs\.org'
  refute_regex "$log" 'allow@raw\.githubusercontent\.com'
}

@test "egress pin: a pinned host no kit asked for is still allowed" {
  _provision_wide_kit extra 'export ACQ_NETWORK_TIER=strict ACQ_EGRESS_PIN=other.services.ai.azure.com'
  local log; log=$(grep 'msb create' "$CALLS")
  assert_regex "$log" '--net-rule allow@other\.services\.ai\.azure\.com'
  refute_regex "$log" 'allow@pinned\.openai\.azure\.com'
}

@test "egress pin: refuses any tier other than strict" {
  _provision_wide_kit balanced 'export ACQ_NETWORK_TIER=balanced ACQ_EGRESS_PIN=pinned.openai.azure.com'
  assert_failure
  assert_output --partial 'ACQ_EGRESS_PIN requires ACQ_NETWORK_TIER=strict'
  refute_regex "$(cat "$CALLS")" 'msb create'
}

@test "egress pin: rejects wildcards and ports" {
  _provision_wide_kit wild 'export ACQ_NETWORK_TIER=strict ACQ_EGRESS_PIN="*.openai.azure.com"'
  assert_failure
  assert_output --partial 'must be exact hostnames without ports'
  _provision_wide_kit port 'export ACQ_NETWORK_TIER=strict ACQ_EGRESS_PIN=pinned.openai.azure.com:443'
  assert_failure
  refute_regex "$(cat "$CALLS")" 'msb create'
}
