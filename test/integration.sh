#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary_root=$(mktemp -d)
trap 'rm -rf -- "$temporary_root"' EXIT

checkout="$temporary_root/checkout"
cp -a -- "$repository_root/test/fixture" "$checkout"
git -C "$checkout" init --quiet
git -C "$checkout" config user.email benchmark@example.invalid
git -C "$checkout" config user.name "Benchmark test"
git -C "$checkout" add .
git -C "$checkout" -c commit.gpgsign=false commit --quiet -m "Add fixture package"

assert_results() {
    local output_dir=$1
    local expected_mode=$2
    local expected_files actual_files
    expected_files=$(printf '%s\n' \
        build-summary.tsv \
        consumer-Manifest.toml \
        consumer-Project.toml \
        metadata.txt \
        raw.tsv \
        summary.md \
        summary.tsv)
    actual_files=$(find "$output_dir" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
    [[ $actual_files == "$expected_files" ]]
    [[ $(wc -l < "$output_dir/raw.tsv") == 3 ]]
    [[ $(awk -F '\t' 'NR > 1 && $7 == "exercise_api" { rows += 1 } END { print rows + 0 }' "$output_dir/raw.tsv") == 2 ]]
    grep -Fxq 'package=PrecompileBenchmarkFixture' "$output_dir/metadata.txt"
    grep -Fxq 'scenarios=exercise_api' "$output_dir/metadata.txt"
    grep -Fxq 'builds=1' "$output_dir/metadata.txt"
    grep -Fxq 'recorded_samples_per_build=1' "$output_dir/metadata.txt"
    grep -Fxq "consumer_environment_mode=$expected_mode" "$output_dir/metadata.txt"
    grep -Fxq 'variant.base.source.FixtureSupport.path=lib/FixtureSupport' "$output_dir/metadata.txt"
    grep -Fxq 'variant.head.source.FixtureSupport.path=lib/FixtureSupport' "$output_dir/metadata.txt"
    grep -Fxq '# PrecompileBenchmarkFixture cold-start summary' "$output_dir/summary.md"
    [[ $(grep -Fc 'path = "__JULIA_PRECOMPILE_BENCHMARK_CHECKOUT__"' "$output_dir/consumer-Manifest.toml") == 1 ]]
    [[ $(grep -Fc 'path = "__JULIA_PRECOMPILE_BENCHMARK_CHECKOUT__/lib/FixtureSupport"' "$output_dir/consumer-Manifest.toml") == 1 ]]
    ! grep -Eq 'path = "/(home|tmp)/' "$output_dir/consumer-Manifest.toml"
}

export PRECOMPILE_BENCHMARK_BUILDS=1
export PRECOMPILE_BENCHMARK_SAMPLES=1
first_results="$temporary_root/first-results"
"$repository_root/run.sh" \
    "$checkout/benchmark/precompile/scenarios.jl" \
    "$first_results" \
    "base=$checkout" \
    "head=$checkout"
assert_results "$first_results" resolved

second_results="$temporary_root/second-results"
PRECOMPILE_BENCHMARK_CONSUMER_PROJECT="$first_results/consumer-Project.toml" \
PRECOMPILE_BENCHMARK_CONSUMER_MANIFEST="$first_results/consumer-Manifest.toml" \
    "$repository_root/run.sh" \
        "$checkout/benchmark/precompile/scenarios.jl" \
        "$second_results" \
        "base=$checkout" \
        "head=$checkout"
assert_results "$second_results" reused

error_path="$temporary_root/error.txt"
if PRECOMPILE_BENCHMARK_BUILDS=0 \
    "$repository_root/run.sh" \
        "$checkout/benchmark/precompile/scenarios.jl" \
        "$temporary_root/invalid-results" \
        "base=$checkout" \
        "head=$checkout" 2> "$error_path"; then
    echo "invalid build count unexpectedly succeeded" >&2
    exit 1
fi
grep -Fq 'PRECOMPILE_BENCHMARK_BUILDS must be a positive integer' "$error_path"

first_release="$temporary_root/release-one"
second_release="$temporary_root/release-two"
(umask 0022; "$repository_root/build-release.sh" "$first_release")
(umask 0077; "$repository_root/build-release.sh" "$second_release")
archive_name="julia-precompile-benchmark-v$(<"$repository_root/VERSION").tar.gz"
cmp -- "$first_release/$archive_name" "$second_release/$archive_name"
(
    cd -- "$first_release"
    sha256sum --check SHA256SUMS
)

extraction_root="$temporary_root/extracted"
mkdir -- "$extraction_root"
tar -xzf "$first_release/$archive_name" -C "$extraction_root"
bundle_root="$extraction_root/${archive_name%.tar.gz}"
for relative_path in LICENSE README.md VERSION run.sh scenario-driver.jl summarize.jl; do
    cmp -- "$repository_root/$relative_path" "$bundle_root/$relative_path"
done
[[ -x "$bundle_root/run.sh" ]]
bash -n "$bundle_root/run.sh"
julia --startup-file=no --history-file=no -e '
    for path in ARGS
        Meta.parseall(read(path, String); filename = path)
    end
' "$bundle_root/scenario-driver.jl" "$bundle_root/summarize.jl"
