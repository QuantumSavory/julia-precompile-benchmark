exercise_api() = check(
    PrecompileBenchmarkFixture.increment(41) == 42,
    "fixture API returned an unexpected value",
)

const PRECOMPILE_BENCHMARKS = (
    exercise_api = exercise_api,
)
