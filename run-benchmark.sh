#!/usr/bin/env bash

set -euo pipefail

builds=${INPUT_BUILDS:-}
samples=${INPUT_SAMPLES:-}

[[ $builds =~ ^[1-9][0-9]*$ ]] || {
    echo "builds must be a positive integer" >&2
    exit 2
}
[[ $samples =~ ^[1-9][0-9]*$ ]] || {
    echo "samples must be a positive integer" >&2
    exit 2
}
benchmark="$GITHUB_WORKSPACE/head/benchmark/precompile/run.sh"
[[ -x $benchmark ]] || {
    echo "benchmark script is missing or not executable: $benchmark" >&2
    exit 2
}

benchmark_environment=(
    "PRECOMPILE_BENCHMARK_BUILDS=$builds"
    "PRECOMPILE_BENCHMARK_SAMPLES=$samples"
)

env "${benchmark_environment[@]}" \
    "$benchmark" \
    "$GITHUB_WORKSPACE/cold-start-results" \
    "base=$GITHUB_WORKSPACE/base" \
    "head=$GITHUB_WORKSPACE/head"
