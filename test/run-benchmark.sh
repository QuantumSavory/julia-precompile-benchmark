#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
capture_file=$(mktemp)
error_file=$(mktemp)
trap 'rm -f "$capture_file" "$error_file"' EXIT

export GITHUB_WORKSPACE="$repository_root/test/fixture-workspace"
export CAPTURE_FILE="$capture_file"
export INPUT_BUILDS=2
export INPUT_SAMPLES=5
export PRECOMPILE_BENCHMARK_BUILDS=99
export PRECOMPILE_BENCHMARK_SAMPLES=99

"$repository_root/run-benchmark.sh"

expected_arguments="$GITHUB_WORKSPACE/cold-start-results base=$GITHUB_WORKSPACE/base head=$GITHUB_WORKSPACE/head"
mapfile -t output < "$capture_file"
[[ ${output[0]} == 'builds=2' ]]
[[ ${output[1]} == 'samples=5' ]]
[[ ${output[2]} == "arguments=$expected_arguments" ]]

if INPUT_BUILDS=0 "$repository_root/run-benchmark.sh" 2> "$error_file"; then
    echo "invalid builds value unexpectedly succeeded" >&2
    exit 1
fi
grep -Fq 'builds must be a positive integer' "$error_file"

if INPUT_SAMPLES=invalid "$repository_root/run-benchmark.sh" 2> "$error_file"; then
    echo "invalid samples value unexpectedly succeeded" >&2
    exit 1
fi
grep -Fq 'samples must be a positive integer' "$error_file"
