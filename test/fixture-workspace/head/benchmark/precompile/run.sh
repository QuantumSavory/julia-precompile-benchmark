#!/usr/bin/env bash

set -euo pipefail

{
    printf 'builds=%s\n' "${PRECOMPILE_BENCHMARK_BUILDS-unset}"
    printf 'samples=%s\n' "${PRECOMPILE_BENCHMARK_SAMPLES-unset}"
    printf 'arguments=%s\n' "$*"
} > "$CAPTURE_FILE"
