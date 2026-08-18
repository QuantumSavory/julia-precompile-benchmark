# Julia precompile benchmark

This composite GitHub Action compares Julia package-cache build, import, and
first-use latency between the exact base and head revisions of a pull request.
It owns the isolated consumer environment, measurement schedule, scenario
driver, result validation, summaries, and artifact upload. A package supplies
only `benchmark/precompile/scenarios.jl` with its package-specific workloads.

## Usage

Create `.github/workflows/precompile.yml` in the package repository:

```yaml
name: Cold-start latency

on:
  pull_request:
    paths:
      - ext/**
      - src/**
      - benchmark/precompile/**
      - .github/workflows/precompile.yml
      - Project.toml

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  compare:
    name: Compare base and head
    runs-on: ubuntu-latest
    timeout-minutes: 180
    steps:
      - uses: QuantumSavory/julia-precompile-benchmark@v3
```

The caller owns the trigger because an action cannot define workflow events.
The example therefore runs for every change under `ext`, `src`, or
`benchmark/precompile`, as well as dependency and workflow changes.

The action uses Julia 1.12.6. Its optional `builds` and `samples` inputs default
to two independent package-cache builds and five fresh-process measurements per
scenario and build.

## Scenario registry

The driver imports the package named by the checkout's root `Project.toml`, then
includes `benchmark/precompile/scenarios.jl`. That file defines workload
functions and an ordered, nonempty `NamedTuple` named
`PRECOMPILE_BENCHMARKS`:

```julia
exercise_api() = check(MyPackage.answer() == 42, "unexpected answer")

const PRECOMPILE_BENCHMARKS = (
    exercise_api = exercise_api,
)
```

Every registered workload runs in its own fresh Julia process. The central
driver measures package import, first use, compilation, total latency, and a
second warm call. Relative path dependencies declared in the package's root
`[sources]` table are discovered and moved between base and head together with
the package.

## Local comparisons

Download the versioned tool bundle so `run.sh`, `scenario-driver.jl`, and
`summarize.jl` stay matched:

```sh
gh release download v3.0.0 \
  --repo QuantumSavory/julia-precompile-benchmark \
  --pattern julia-precompile-benchmark-v3.0.0.tar.gz
tar -xzf julia-precompile-benchmark-v3.0.0.tar.gz
julia-precompile-benchmark-v3.0.0/run.sh \
  benchmark/precompile/scenarios.jl \
  /tmp/precompile-results \
  base=/path/to/base \
  head=/path/to/head
```

The runner requires GNU/Linux, clean committed checkouts, and Julia 1.12.6.
Its main environment controls are:

- `PRECOMPILE_BENCHMARK_BUILDS` and `PRECOMPILE_BENCHMARK_SAMPLES`
- `PRECOMPILE_BENCHMARK_BASELINES`, a comma-separated `CANDIDATE=BASELINE` map
- `PRECOMPILE_BENCHMARK_CONSUMER_PROJECT` and
  `PRECOMPILE_BENCHMARK_CONSUMER_MANIFEST`, set together to reuse a normalized
  environment from an earlier run
- `PRECOMPILE_BENCHMARK_KEEP_TMP=1` to retain the temporary environment

`PRECOMPILE_BENCHMARK_ALLOW_DIRTY=1` and
`PRECOMPILE_BENCHMARK_ALLOW_JULIA_MISMATCH=1` are available for non-reportable
smoke runs.

Each successful comparison writes `raw.tsv`, `summary.tsv`,
`build-summary.tsv`, `summary.md`, `metadata.txt`, `consumer-Project.toml`, and
`consumer-Manifest.toml`.

Use this action only from `pull_request` workflows. It executes code from the
pull request head, so callers should keep the GitHub token read-only and must
not expose secrets.
