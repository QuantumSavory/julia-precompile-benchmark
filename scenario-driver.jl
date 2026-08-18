length(ARGS) in (2, 3) || error(
    "usage: scenario-driver.jl PACKAGE SCENARIOS [SCENARIO]",
)

package_name, scenarios_path = ARGS[1:2]
occursin(r"^[A-Za-z][A-Za-z0-9_]*$", package_name) || error(
    "invalid Julia package name: $package_name",
)
isfile(scenarios_path) || error("scenario registry is not a file: $scenarios_path")

package_import = Expr(:using, Expr(:., Symbol(package_name)))
const total_started_ns = time_ns()
const import_started_ns = total_started_ns
Core.eval(Main, package_import)
const import_seconds = (time_ns() - import_started_ns) / 1.0e9

check(condition, message) = condition || error(message)
Base.include(Main, scenarios_path)
isdefined(Main, :PRECOMPILE_BENCHMARKS) || error(
    "scenarios must define PRECOMPILE_BENCHMARKS",
)
benchmarks = getfield(Main, :PRECOMPILE_BENCHMARKS)
benchmarks isa NamedTuple || error("PRECOMPILE_BENCHMARKS must be an ordered NamedTuple")
isempty(benchmarks) && error("PRECOMPILE_BENCHMARKS must not be empty")

if length(ARGS) == 2
    foreach(name -> println(String(name)), keys(benchmarks))
    exit()
end

scenario_name = only(ARGS[3:3])
occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", scenario_name) || error(
    "invalid precompile benchmark name: $scenario_name",
)
scenario_key = Symbol(scenario_name)
haskey(benchmarks, scenario_key) || error("unknown precompile benchmark: $scenario_name")
selected_scenario = benchmarks[scenario_key]
applicable(selected_scenario) || error("precompile benchmark must be callable without arguments: $scenario_name")

trace_mode = get(ENV, "PRECOMPILE_BENCHMARK_TRACE", "")
first_result = if isempty(trace_mode)
    @timed selected_scenario()
elseif trace_mode == "compile" || trace_mode == "dispatch"
    VERSION >= v"1.12" || error("PRECOMPILE_BENCHMARK_TRACE requires Julia 1.12 or later")
    Core.eval(
        Main,
        Meta.parse("@timed Base.@trace_$(trace_mode) selected_scenario()"),
    )
else
    error("PRECOMPILE_BENCHMARK_TRACE must be empty, compile, or dispatch")
end
total_seconds = (time_ns() - total_started_ns) / 1.0e9
warm_result = @timed selected_scenario()
compile_time(result) = hasproperty(result, :compile_time) ? result.compile_time : 0.0
recompile_time(result) = hasproperty(result, :recompile_time) ? result.recompile_time : 0.0

println(join((
    "RESULT",
    scenario_name,
    import_seconds,
    first_result.time,
    compile_time(first_result),
    recompile_time(first_result),
    total_seconds,
    warm_result.time,
    compile_time(warm_result),
    recompile_time(warm_result),
), '\t'))
