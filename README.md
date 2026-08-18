# Julia precompile benchmark

A composite GitHub Action that compares Julia package-cache build, import, and
first-use latency between the exact base and head of a pull request.

The package owns the benchmark scenarios and measurement logic in
`benchmark/precompile/run.sh`. This action provides the shared CI orchestration:
it checks out both revisions, installs Julia, runs the head revision's harness,
writes its Markdown comparison to the job summary, and uploads all raw results.

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
    timeout-minutes: 120
    steps:
      - uses: QuantumSavory/julia-precompile-benchmark@v2
```

The path filter belongs to the caller because GitHub Actions cannot define the
events that invoke a consumer workflow. The example runs for every change under
`ext`, `src`, or `benchmark/precompile`; dependency and workflow changes also
run it.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `julia-version` | no | `1.12.6` | Julia version used for the comparison |
| `builds` | no | `2` | Independent package-cache builds |
| `samples` | no | `5` | Fresh-process samples per scenario and build |

The action invokes the head checkout as follows:

```text
benchmark/precompile/run.sh RESULTS BASE=CHECKOUT HEAD=CHECKOUT
```

The harness must be executable. It must write `summary.md` and any raw data
under the supplied results directory. The action passes repetition controls as
`PRECOMPILE_BENCHMARK_BUILDS` and `PRECOMPILE_BENCHMARK_SAMPLES`. The package
harness owns its ordered `PRECOMPILE_BENCHMARKS` registry and runs every
registered benchmark; callers do not select scenarios through the action.

Use this action only from `pull_request` workflows. The action executes the
head revision's benchmark script, so callers should grant only read access to
the GitHub token.
