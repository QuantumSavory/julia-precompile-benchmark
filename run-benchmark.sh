#!/usr/bin/env bash

set -euo pipefail

prefix=${INPUT_ENVIRONMENT_PREFIX:-}
builds=${INPUT_BUILDS:-}
samples=${INPUT_SAMPLES:-}
scenarios=${INPUT_SCENARIOS:-}
extra_scenarios=${INPUT_EXTRA_SCENARIOS:-}

[[ $prefix =~ ^[A-Z][A-Z0-9_]*$ ]] || {
    echo "environment-prefix must start with an uppercase letter and contain only uppercase letters, digits, and underscores" >&2
    exit 2
}
[[ $builds =~ ^[1-9][0-9]*$ ]] || {
    echo "builds must be a positive integer" >&2
    exit 2
}
[[ $samples =~ ^[1-9][0-9]*$ ]] || {
    echo "samples must be a positive integer" >&2
    exit 2
}
[[ -n $scenarios ]] || {
    echo "scenarios must not be empty" >&2
    exit 2
}

benchmark="$GITHUB_WORKSPACE/head/benchmark/precompile/run.sh"
[[ -x $benchmark ]] || {
    echo "benchmark script is missing or not executable: $benchmark" >&2
    exit 2
}

benchmark_environment=(
    "${prefix}_PRECOMPILE_BUILDS=$builds"
    "${prefix}_PRECOMPILE_SAMPLES=$samples"
    "${prefix}_PRECOMPILE_SCENARIOS=$scenarios"
)
if [[ -n $extra_scenarios ]]; then
    benchmark_environment+=("${prefix}_PRECOMPILE_EXTRA_SCENARIOS=$extra_scenarios")
fi

env "${benchmark_environment[@]}" \
    "$benchmark" \
    "$GITHUB_WORKSPACE/cold-start-results" \
    "base=$GITHUB_WORKSPACE/base" \
    "head=$GITHUB_WORKSPACE/head"
