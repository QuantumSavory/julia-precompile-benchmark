#!/usr/bin/env bash

set -euo pipefail

{
    printf 'builds=%s\n' "${TEST_PRECOMPILE_BUILDS-unset}"
    printf 'samples=%s\n' "${TEST_PRECOMPILE_SAMPLES-unset}"
    printf 'scenarios=%s\n' "${TEST_PRECOMPILE_SCENARIOS-unset}"
    printf 'extra_scenarios=%s\n' "${TEST_PRECOMPILE_EXTRA_SCENARIOS-unset}"
    printf 'arguments=%s\n' "$*"
} > "$CAPTURE_FILE"
