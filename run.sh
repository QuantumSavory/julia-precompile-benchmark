#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "usage: $0 SCENARIOS OUTPUT_DIR LABEL=CHECKOUT [LABEL=CHECKOUT ...]" >&2
    echo "environment: PRECOMPILE_BENCHMARK_BUILDS, PRECOMPILE_BENCHMARK_SAMPLES, PRECOMPILE_BENCHMARK_BASELINES, PRECOMPILE_BENCHMARK_CONSUMER_PROJECT, PRECOMPILE_BENCHMARK_CONSUMER_MANIFEST, PRECOMPILE_BENCHMARK_ALLOW_DIRTY, PRECOMPILE_BENCHMARK_ALLOW_JULIA_MISMATCH" >&2
    exit 2
}

manifest_entry_path() {
    local manifest_path=$1
    local package_name=$2
    awk -v package_header="[[deps.$package_name]]" '
        $0 == package_header { stanzas += 1; in_package = 1; next }
        in_package && /^\[\[deps\./ { in_package = 0 }
        in_package && /^path = / {
            paths += 1
            value = $0
            sub(/^path = "/, "", value)
            sub(/"$/, "", value)
        }
        END {
            if (stanzas != 1 || paths != 1)
                exit 42
            print value
        }
    ' "$manifest_path"
}

rewrite_manifest_path() {
    local input_path=$1
    local output_path=$2
    local package_name=$3
    local old_path=$4
    local new_path=$5
    if ! awk \
        -v package_header="[[deps.$package_name]]" \
        -v old_line="path = \"$old_path\"" \
        -v new_line="path = \"$new_path\"" '
        BEGIN {
            in_package = 0
        }
        {
            if ($0 == package_header) {
                package_stanzas += 1
                in_package = 1
            } else if ($0 ~ /^\[\[deps\./) {
                in_package = 0
            }
            if ($0 == old_line) {
                path_lines += 1
                in_package || misplaced_path = 1
                print new_line
            } else {
                print
            }
        }
        END {
            if (package_stanzas != 1 || path_lines != 1 || misplaced_path)
                exit 42
        }
    ' "$input_path" > "$output_path"; then
        rm -f -- "$output_path"
        return 1
    fi
}

validate_consumer_project() {
    local project_path=$1
    local package_name=$2
    local package_uuid=$3
    cmp -s -- <(printf '%s\n' \
        '[deps]' \
        "$package_name = \"$package_uuid\"") "$project_path"
}

[[ $# -ge 4 ]] || usage

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for tool_path in "$script_dir/VERSION" "$script_dir/scenario-driver.jl" "$script_dir/summarize.jl"; do
    [[ -f $tool_path && -r $tool_path ]] || {
        echo "central benchmark tool is missing or unreadable: $tool_path" >&2
        exit 2
    }
done
harness_version=$(<"$script_dir/VERSION")
[[ $harness_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "invalid central benchmark VERSION: $harness_version" >&2
    exit 2
}

scenario_source_path=$1
shift
[[ -f $scenario_source_path && -r $scenario_source_path ]] || {
    echo "scenario registry is not a readable regular file: $scenario_source_path" >&2
    exit 2
}
scenario_source_path=$(realpath -e -- "$scenario_source_path")

harness_run_sha256=$(sha256sum "$script_dir/run.sh" | awk '{print $1}')
harness_driver_sha256=$(sha256sum "$script_dir/scenario-driver.jl" | awk '{print $1}')
harness_scenarios_sha256=$(sha256sum "$scenario_source_path" | awk '{print $1}')
harness_summarize_sha256=$(sha256sum "$script_dir/summarize.jl" | awk '{print $1}')

verify_tool_files() {
    [[ $(sha256sum "$script_dir/run.sh" | awk '{print $1}') == "$harness_run_sha256" ]] || {
        echo "central run.sh changed during measurement" >&2
        exit 1
    }
    [[ $(sha256sum "$script_dir/scenario-driver.jl" | awk '{print $1}') == "$harness_driver_sha256" ]] || {
        echo "central scenario-driver.jl changed during measurement" >&2
        exit 1
    }
    [[ $(sha256sum "$scenario_source_path" | awk '{print $1}') == "$harness_scenarios_sha256" ]] || {
        echo "scenario registry changed during measurement" >&2
        exit 1
    }
    [[ $(sha256sum "$script_dir/summarize.jl" | awk '{print $1}') == "$harness_summarize_sha256" ]] || {
        echo "central summarize.jl changed during measurement" >&2
        exit 1
    }
}

verify_tool_files
output_dir=$1
shift
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)

raw_path="$output_dir/raw.tsv"
summary_path="$output_dir/summary.tsv"
build_summary_path="$output_dir/build-summary.tsv"
markdown_path="$output_dir/summary.md"
metadata_path="$output_dir/metadata.txt"
consumer_project_path="$output_dir/consumer-Project.toml"
consumer_manifest_path="$output_dir/consumer-Manifest.toml"
for path in "$raw_path" "$summary_path" "$build_summary_path" "$markdown_path" "$metadata_path" "$consumer_project_path" "$consumer_manifest_path"; do
    [[ ! -e "$path" && ! -L "$path" ]] || {
        echo "refusing to overwrite existing result file: $path" >&2
        exit 2
    }
done

builds=${PRECOMPILE_BENCHMARK_BUILDS:-1}
samples=${PRECOMPILE_BENCHMARK_SAMPLES:-2}
baseline_map_list=${PRECOMPILE_BENCHMARK_BASELINES:-}
reuse_consumer_project=${PRECOMPILE_BENCHMARK_CONSUMER_PROJECT:-}
reuse_consumer_manifest=${PRECOMPILE_BENCHMARK_CONSUMER_MANIFEST:-}
allow_dirty=${PRECOMPILE_BENCHMARK_ALLOW_DIRTY:-0}
allow_julia_mismatch=${PRECOMPILE_BENCHMARK_ALLOW_JULIA_MISMATCH:-0}
julia=${JULIA:-julia}
expected_julia='julia version 1.12.6'
token_pattern='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
mapping_list_pattern='^[A-Za-z0-9][A-Za-z0-9_.-]*=[A-Za-z0-9][A-Za-z0-9_.-]*(,[A-Za-z0-9][A-Za-z0-9_.-]*=[A-Za-z0-9][A-Za-z0-9_.-]*)*$'

[[ $builds =~ ^[1-9][0-9]*$ ]] || { echo "PRECOMPILE_BENCHMARK_BUILDS must be a positive integer" >&2; exit 2; }
[[ $samples =~ ^[1-9][0-9]*$ ]] || { echo "PRECOMPILE_BENCHMARK_SAMPLES must be a positive integer" >&2; exit 2; }
[[ $allow_dirty == 0 || $allow_dirty == 1 ]] || { echo "PRECOMPILE_BENCHMARK_ALLOW_DIRTY must be 0 or 1" >&2; exit 2; }
[[ $allow_julia_mismatch == 0 || $allow_julia_mismatch == 1 ]] || { echo "PRECOMPILE_BENCHMARK_ALLOW_JULIA_MISMATCH must be 0 or 1" >&2; exit 2; }
[[ -z $baseline_map_list || $baseline_map_list =~ $mapping_list_pattern ]] || {
    echo "PRECOMPILE_BENCHMARK_BASELINES must be a comma-separated CANDIDATE=BASELINE list" >&2
    exit 2
}
if [[ -n $reuse_consumer_project || -n $reuse_consumer_manifest ]]; then
    [[ -n $reuse_consumer_project && -n $reuse_consumer_manifest ]] || {
        echo "PRECOMPILE_BENCHMARK_CONSUMER_PROJECT and PRECOMPILE_BENCHMARK_CONSUMER_MANIFEST must be set together" >&2
        exit 2
    }
    for source_path in "$reuse_consumer_project" "$reuse_consumer_manifest"; do
        [[ $source_path != *$'\t'* && $source_path != *$'\n'* && $source_path != *$'\r'* ]] || {
            echo "consumer environment paths must not contain tabs or line endings" >&2
            exit 2
        }
        [[ -f $source_path && -r $source_path ]] || {
            echo "consumer environment input is not a readable regular file: $source_path" >&2
            exit 2
        }
    done
    if ! IFS= read -r -d '' reuse_consumer_project < <(realpath -ze -- "$reuse_consumer_project"); then
        echo "failed to canonicalize consumer Project input" >&2
        exit 2
    fi
    if ! IFS= read -r -d '' reuse_consumer_manifest < <(realpath -ze -- "$reuse_consumer_manifest"); then
        echo "failed to canonicalize consumer Manifest input" >&2
        exit 2
    fi
    for source_path in "$reuse_consumer_project" "$reuse_consumer_manifest"; do
        [[ $source_path != *$'\t'* && $source_path != *$'\n'* && $source_path != *$'\r'* ]] || {
            echo "canonical consumer environment paths must not contain tabs or line endings" >&2
            exit 2
        }
    done
    [[ ! $reuse_consumer_project -ef $reuse_consumer_manifest ]] || {
        echo "consumer Project and Manifest inputs must be distinct files" >&2
        exit 2
    }
fi
command -v "$julia" >/dev/null 2>&1 || { echo "Julia executable not found: $julia" >&2; exit 2; }
julia_version=$("$julia" --version)
if [[ $julia_version != "$expected_julia" && $allow_julia_mismatch != 1 ]]; then
    echo "cold-start comparisons require $expected_julia (found $julia_version)" >&2
    echo "set PRECOMPILE_BENCHMARK_ALLOW_JULIA_MISMATCH=1 only for a non-reportable smoke run" >&2
    exit 2
fi

baseline_candidates=()
baseline_labels=()
if [[ -n $baseline_map_list ]]; then
    IFS=',' read -r -a baseline_specifications <<< "$baseline_map_list"
    for specification in "${baseline_specifications[@]}"; do
        [[ $specification == *=* ]] || {
            echo "PRECOMPILE_BENCHMARK_BASELINES entries must have CANDIDATE=BASELINE form" >&2
            exit 2
        }
        baseline_candidate=${specification%%=*}
        baseline_label=${specification#*=}
        [[ -n $baseline_candidate && -n $baseline_label ]] || {
            echo "invalid baseline entry: $specification" >&2
            exit 2
        }
        baseline_candidates+=("$baseline_candidate")
        baseline_labels+=("$baseline_label")
    done
fi
[[ $(uname -s) == Linux ]] || {
    echo "the cold-start harness currently requires GNU/Linux" >&2
    exit 2
}
labels=()
checkouts=()
for specification in "$@"; do
    [[ $specification == *=* ]] || usage
    label=${specification%%=*}
    checkout=${specification#*=}
    [[ $label =~ $token_pattern ]] || {
        echo "variant labels must start with an ASCII letter or digit and contain only letters, digits, dots, underscores, or hyphens" >&2
        exit 2
    }
    [[ -n $checkout && $checkout != *$'\t'* && $checkout != *$'\n'* ]] || {
        echo "variant checkouts must be nonempty and must not contain tabs or newlines" >&2
        exit 2
    }
    [[ -f "$checkout/Project.toml" && -d "$checkout/src" ]] || {
        echo "not a Julia package checkout: $checkout" >&2
        exit 2
    }
    checkout=$(cd -- "$checkout" && pwd -P)
    [[ $checkout != *$'\t'* && $checkout != *$'\n'* ]] || {
        echo "canonical variant checkout paths must not contain tabs or newlines" >&2
        exit 2
    }
    for existing_label in "${labels[@]}"; do
        [[ $label != "$existing_label" ]] || { echo "duplicate variant label: $label" >&2; exit 2; }
    done
    labels+=("$label")
    checkouts+=("$checkout")
done

definition_index=$((${#checkouts[@]} - 1))
definition_checkout=${checkouts[$definition_index]}
expected_scenario_path="$definition_checkout/benchmark/precompile/scenarios.jl"
[[ -f $expected_scenario_path && $scenario_source_path -ef $expected_scenario_path ]] || {
    echo "SCENARIOS must be the final variant's benchmark/precompile/scenarios.jl" >&2
    exit 2
}

package_name=
package_uuid=
source_names=()
source_uuids=()
source_paths=()
while IFS=$'\t' read -r record first second third; do
    case "$record" in
        package)
            [[ -z $package_name && -n $first && -n $second && -z $third ]] || {
                echo "invalid package identity from $definition_checkout/Project.toml" >&2
                exit 2
            }
            package_name=$first
            package_uuid=$second
            ;;
        source)
            [[ -n $first && -n $second && -n $third ]] || {
                echo "invalid path source from $definition_checkout/Project.toml" >&2
                exit 2
            }
            source_names+=("$first")
            source_uuids+=("$second")
            source_paths+=("$third")
            ;;
        *)
            echo "invalid package metadata record: $record" >&2
            exit 2
            ;;
    esac
done < <("$julia" --startup-file=no --history-file=no -e '
    using TOML
    project = TOML.parsefile(ARGS[1])
    name = get(project, "name", nothing)
    uuid = get(project, "uuid", nothing)
    name isa String && uuid isa String || error("Project.toml must define string name and uuid fields")
    println("package\t", name, "\t", uuid)
    dependencies = get(project, "deps", Dict{String,Any}())
    sources = get(project, "sources", Dict{String,Any}())
    dependencies isa AbstractDict && sources isa AbstractDict || error("Project.toml deps and sources must be tables")
    for source_name in sort!(collect(keys(sources)))
        source = sources[source_name]
        source isa AbstractDict || continue
        source_path = get(source, "path", nothing)
        source_path isa String || continue
        source_uuid = get(dependencies, source_name, nothing)
        source_uuid isa String || error("path source $source_name must also be a dependency")
        println("source\t", source_name, "\t", source_uuid, "\t", source_path)
    end
' "$definition_checkout/Project.toml")

[[ $package_name =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || {
    echo "invalid Julia package name: $package_name" >&2
    exit 2
}
[[ $package_uuid =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
    echo "invalid Julia package UUID: $package_uuid" >&2
    exit 2
}
for source_index in "${!source_names[@]}"; do
    source_name=${source_names[$source_index]}
    source_uuid=${source_uuids[$source_index]}
    source_path=${source_paths[$source_index]}
    [[ $source_name =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || {
        echo "invalid path-source package name: $source_name" >&2
        exit 2
    }
    [[ $source_uuid =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
        echo "invalid path-source UUID for $source_name: $source_uuid" >&2
        exit 2
    }
    [[ -n $source_path && $source_path != /* && $source_path != *$'\t'* && $source_path != *$'\n'* && $source_path != *$'\r'* ]] || {
        echo "path source must be a safe relative path: $source_name=$source_path" >&2
        exit 2
    }
    IFS='/' read -r -a source_components <<< "$source_path"
    for component in "${source_components[@]}"; do
        [[ -n $component && $component != . && $component != .. ]] || {
            echo "path source contains an unsafe component: $source_name=$source_path" >&2
            exit 2
        }
    done
done

for checkout in "${checkouts[@]}"; do
    if [[ $output_dir == "$checkout" || $output_dir == "$checkout/"* ]]; then
        echo "output directory must be outside every measured checkout: $output_dir" >&2
        exit 2
    fi
done

checkout_state_sha256() {
    local checkout=$1
    local file_path file_sha256 file_state link_target relative_path
    (
        printf 'status\0'
        git -C "$checkout" status --porcelain=v1 -z --untracked-files=all
        printf 'tracked-diff\0'
        git -C "$checkout" diff --no-ext-diff --no-textconv --binary HEAD --
        printf '\0untracked\0'
        while IFS= read -r -d '' relative_path; do
            file_path="$checkout/$relative_path"
            printf 'path\0%s\0' "$relative_path"
            if [[ -L $file_path ]]; then
                link_target=$(readlink -- "$file_path")
                printf 'symlink\0%s\0' "$link_target"
            elif [[ -f $file_path ]]; then
                file_state=$(stat -c '%a:%s' -- "$file_path")
                file_sha256=$(sha256sum < "$file_path" | awk '{print $1}')
                printf 'file\0%s\0%s\0' "$file_state" "$file_sha256"
            elif [[ -d $file_path ]]; then
                file_state=$(stat -c '%a' -- "$file_path")
                printf 'directory\0%s\0' "$file_state"
            elif [[ -e $file_path ]]; then
                file_state=$(stat -c '%F:%a:%s' -- "$file_path")
                printf 'other\0%s\0' "$file_state"
            else
                printf 'missing\0'
            fi
        done < <(git -C "$checkout" ls-files -z --others --exclude-standard)
    ) | sha256sum | awk '{print $1}'
}

source_state_sha256() {
    local checkout=$1
    local source_path=$2
    local file_path file_sha256 file_state link_target relative_path
    (
        printf 'head-tree\0'
        git -C "$checkout" rev-parse "HEAD:$source_path"
        printf 'status\0'
        git -C "$checkout" status --porcelain=v1 -z --untracked-files=all -- "$source_path"
        printf 'tracked-diff\0'
        git -C "$checkout" diff --no-ext-diff --no-textconv --binary HEAD -- "$source_path"
        printf '\0untracked\0'
        while IFS= read -r -d '' relative_path; do
            file_path="$checkout/$relative_path"
            printf 'path\0%s\0' "$relative_path"
            if [[ -L $file_path ]]; then
                link_target=$(readlink -- "$file_path")
                printf 'symlink\0%s\0' "$link_target"
            elif [[ -f $file_path ]]; then
                file_state=$(stat -c '%a:%s' -- "$file_path")
                file_sha256=$(sha256sum < "$file_path" | awk '{print $1}')
                printf 'file\0%s\0%s\0' "$file_state" "$file_sha256"
            elif [[ -d $file_path ]]; then
                file_state=$(stat -c '%a' -- "$file_path")
                printf 'directory\0%s\0' "$file_state"
            elif [[ -e $file_path ]]; then
                file_state=$(stat -c '%F:%a:%s' -- "$file_path")
                printf 'other\0%s\0' "$file_state"
            else
                printf 'missing\0'
            fi
        done < <(git -C "$checkout" ls-files -z --others --exclude-standard -- "$source_path")
    ) | sha256sum | awk '{print $1}'
}

copy_checkout_snapshot() {
    local checkout=$1
    local destination=$2
    local destination_path relative_path source_path
    while IFS= read -r -d '' relative_path; do
        source_path="$checkout/$relative_path"
        [[ -e $source_path || -L $source_path ]] || continue
        destination_path="$destination/$relative_path"
        mkdir -p -- "$(dirname -- "$destination_path")"
        cp -a --reflink=never -- "$source_path" "$destination_path"
    done < <(git -C "$checkout" ls-files -z --cached --others --exclude-standard)
}

commits=()
checkout_initial_dirty=()
checkout_state_sha256s=()
source_head_trees=()
source_state_sha256s=()

project_identity() {
    "$julia" --startup-file=no --history-file=no -e '
        using TOML
        project = TOML.parsefile(ARGS[1])
        name = get(project, "name", nothing)
        uuid = get(project, "uuid", nothing)
        name isa String && uuid isa String || error("Project.toml must define string name and uuid fields")
        print(name, "\t", uuid)
    ' "$1"
}

for index in "${!labels[@]}"; do
    checkout=${checkouts[$index]}
    [[ $(project_identity "$checkout/Project.toml") == "$package_name"$'\t'"$package_uuid" ]] || {
        echo "variant package identity does not match $package_name $package_uuid: ${labels[$index]}" >&2
        exit 1
    }
    commits+=("$(git -C "$checkout" rev-parse HEAD)")
    if [[ -n $(git -C "$checkout" status --porcelain=v1 --untracked-files=all) ]]; then
        checkout_initial_dirty+=(true)
    else
        checkout_initial_dirty+=(false)
    fi
    if [[ ${checkout_initial_dirty[$index]} == true && $allow_dirty != 1 ]]; then
        echo "variant checkout is dirty; commit it or set PRECOMPILE_BENCHMARK_ALLOW_DIRTY=1 for a non-reportable smoke run: ${labels[$index]}" >&2
        exit 1
    fi
    checkout_state_sha256s+=("$(checkout_state_sha256 "$checkout")")
    for source_index in "${!source_names[@]}"; do
        source_name=${source_names[$source_index]}
        source_uuid=${source_uuids[$source_index]}
        source_path=${source_paths[$source_index]}
        source_root=$(realpath -e -- "$checkout/$source_path")
        [[ -d $source_root && $source_root == "$checkout/"* && -f "$source_root/Project.toml" ]] || {
            echo "path source escapes or is not a Julia package: $source_name=$source_path in ${labels[$index]}" >&2
            exit 1
        }
        [[ $(project_identity "$source_root/Project.toml") == "$source_name"$'\t'"$source_uuid" ]] || {
            echo "path-source identity does not match $source_name $source_uuid: ${labels[$index]}" >&2
            exit 1
        }
        flat_source_index=$((source_index * ${#labels[@]} + index))
        source_head_trees[$flat_source_index]=$(git -C "$checkout" rev-parse "HEAD:$source_path")
        source_state_sha256s[$flat_source_index]=$(source_state_sha256 "$checkout" "$source_path")
    done
done

verify_checkout() {
    local index=$1
    local checkout=${checkouts[$index]}
    local expected_commit=${commits[$index]}
    [[ $(git -C "$checkout" rev-parse HEAD) == "$expected_commit" ]] || {
        echo "variant HEAD changed during measurement: ${labels[$index]}" >&2
        exit 1
    }
    [[ $(checkout_state_sha256 "$checkout") == "${checkout_state_sha256s[$index]}" ]] || {
        echo "variant checkout contents changed during measurement: ${labels[$index]}" >&2
        exit 1
    }
    for source_index in "${!source_names[@]}"; do
        source_path=${source_paths[$source_index]}
        flat_source_index=$((source_index * ${#labels[@]} + index))
        [[ $(git -C "$checkout" rev-parse "HEAD:$source_path") == "${source_head_trees[$flat_source_index]}" &&
           $(source_state_sha256 "$checkout" "$source_path") == "${source_state_sha256s[$flat_source_index]}" ]] || {
            echo "variant path source changed during measurement: ${source_names[$source_index]} in ${labels[$index]}" >&2
            exit 1
        }
    done
}

for checkout in "${checkouts[@]:1}"; do
    cmp -s -- \
        <(sed '1,/^\[/ { /^version = /d; }' "${checkouts[0]}/Project.toml") \
        <(sed '1,/^\[/ { /^version = /d; }' "$checkout/Project.toml") || {
        echo "all variants must use identical Project.toml dependency metadata" >&2
        exit 1
    }
    for source_index in "${!source_names[@]}"; do
        source_path=${source_paths[$source_index]}
        cmp -s -- \
            <(sed '1,/^\[/ { /^version = /d; }' "${checkouts[0]}/$source_path/Project.toml") \
            <(sed '1,/^\[/ { /^version = /d; }' "$checkout/$source_path/Project.toml") || {
            echo "all variants must use identical $source_path/Project.toml dependency metadata" >&2
            exit 1
        }
    done
done
for mapping_index in "${!baseline_candidates[@]}"; do
    baseline_candidate=${baseline_candidates[$mapping_index]}
    baseline_label=${baseline_labels[$mapping_index]}
    candidate_known=false
    baseline_known=false
    for label in "${labels[@]}"; do
        [[ $label == "$baseline_candidate" ]] && candidate_known=true
        [[ $label == "$baseline_label" ]] && baseline_known=true
    done
    $candidate_known || {
        echo "baseline map refers to an unknown candidate label: $baseline_candidate" >&2
        exit 2
    }
    $baseline_known || {
        echo "baseline map refers to an unknown baseline label: $baseline_label" >&2
        exit 2
    }
    [[ $baseline_candidate != "${labels[0]}" ]] || {
        echo "the first variant cannot be a mapped candidate: $baseline_candidate" >&2
        exit 2
    }
    [[ $baseline_candidate != "$baseline_label" ]] || {
        echo "a candidate cannot be its own baseline: $baseline_candidate" >&2
        exit 2
    }
    for previous_index in "${!baseline_candidates[@]}"; do
        [[ $previous_index -ge $mapping_index ]] && break
        [[ ${baseline_candidates[$previous_index]} != "$baseline_candidate" ]] || {
            echo "duplicate baseline map for candidate: $baseline_candidate" >&2
            exit 2
        }
    done
done

candidate_baseline_indices=()
for ((candidate_index = 1; candidate_index < ${#labels[@]}; candidate_index++)); do
    baseline_index=0
    for mapping_index in "${!baseline_candidates[@]}"; do
        [[ ${baseline_candidates[$mapping_index]} == "${labels[$candidate_index]}" ]] || continue
        for label_index in "${!labels[@]}"; do
            if [[ ${labels[$label_index]} == "${baseline_labels[$mapping_index]}" ]]; then
                baseline_index=$label_index
                break
            fi
        done
        break
    done
    candidate_baseline_indices[$candidate_index]=$baseline_index
done

set_comparison_order() {
    local build_number=$1
    local candidate_index
    comparison_indices=()
    if ((build_number % 2 == 1)); then
        for ((candidate_index = 1; candidate_index < ${#labels[@]}; candidate_index++)); do
            comparison_indices+=("$candidate_index")
        done
    else
        for ((candidate_index = ${#labels[@]} - 1; candidate_index >= 1; candidate_index--)); do
            comparison_indices+=("$candidate_index")
        done
    fi
}

set_pair_order() {
    local build_number=$1
    local candidate_index=$2
    local baseline_index=${candidate_baseline_indices[$candidate_index]}
    if (((build_number + candidate_index) % 2 == 1)); then
        pair_indices=("$baseline_index" "$candidate_index")
    else
        pair_indices=("$candidate_index" "$baseline_index")
    fi
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/julia-precompile-benchmark.XXXXXX")
cleanup() {
    if [[ ${PRECOMPILE_BENCHMARK_KEEP_TMP:-0} == 1 ]]; then
        echo "kept temporary benchmark data at $temporary_root" >&2
    else
        rm -rf -- "$temporary_root"
    fi
}
trap cleanup EXIT

environment_dir="$temporary_root/environment"
seed_depot="$temporary_root/seed-depot"
checkout_link="$temporary_root/checkout"
seed_checkout="$temporary_root/seed-checkout"
harness_snapshot_dir="$temporary_root/harness"
scenario_script="$harness_snapshot_dir/scenarios.jl"
driver_script="$harness_snapshot_dir/scenario-driver.jl"
summarize_script="$harness_snapshot_dir/summarize.jl"
verify_harness_snapshots() {
    [[ $(sha256sum "$scenario_script" | awk '{print $1}') == "$harness_scenarios_sha256" ]] || {
        echo "recorded scenario harness snapshot changed during measurement" >&2
        exit 1
    }
    [[ $(sha256sum "$driver_script" | awk '{print $1}') == "$harness_driver_sha256" ]] || {
        echo "scenario driver snapshot changed during measurement" >&2
        exit 1
    }
    [[ $(sha256sum "$summarize_script" | awk '{print $1}') == "$harness_summarize_sha256" ]] || {
        echo "summary harness snapshot changed during measurement" >&2
        exit 1
    }
}
mkdir -p -- "$environment_dir" "$seed_depot" "$seed_checkout" "$harness_snapshot_dir"
cp -- "$scenario_source_path" "$scenario_script"
cp -- "$script_dir/scenario-driver.jl" "$driver_script"
cp -- "$script_dir/summarize.jl" "$summarize_script"
chmod 0444 "$scenario_script" "$driver_script" "$summarize_script"
verify_harness_snapshots
verify_tool_files
# Seed dependency caches through separate inodes so setup cannot page-warm a measured checkout.
verify_checkout 0
if [[ ${checkout_initial_dirty[0]} == true ]]; then
    seed_checkout_mode=dirty_working_tree_copy
    # A non-reportable dirty run still uses its fixed working source rather than HEAD.
    copy_checkout_snapshot "${checkouts[0]}" "$seed_checkout"
else
    seed_checkout_mode=committed_git_archive
    git -C "${checkouts[0]}" archive --format=tar "${commits[0]}" | tar -xf - -C "$seed_checkout"
fi
verify_checkout 0
[[ -f "$seed_checkout/Project.toml" && -d "$seed_checkout/src" ]] || {
    echo "failed to create the detached seed checkout" >&2
    exit 1
}
ln -s -- "$seed_checkout" "$checkout_link"
[[ $checkout_link != *$'\t'* && $checkout_link != *$'\n'* && $checkout_link != *$'\r'* && $checkout_link != *'"'* && $checkout_link != *'\'* ]] || {
    echo "temporary checkout link cannot be represented safely in the consumer Manifest: $checkout_link" >&2
    exit 1
}

export JULIA_NUM_THREADS=1
export JULIA_NUM_PRECOMPILE_TASKS=1
export JULIA_PKG_PRECOMPILE_AUTO=0
export JULIA_LOAD_PATH='@:@stdlib'
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export LC_ALL=C
unset JULIA_CPU_TARGET JULIA_PROJECT JULIA_DEPOT_PATH
unset PRECOMPILE_BENCHMARK_TRACE
unset JULIA_PKG_OFFLINE
julia_flags=(--startup-file=no --history-file=no --threads=1)

echo "Preparing one consumer manifest and seed depot..." >&2
consumer_environment_mode=resolved
consumer_environment_source_project=
consumer_environment_source_manifest=
consumer_environment_source_project_sha256=
consumer_environment_source_manifest_sha256=
manifest_path="$environment_dir/Manifest.toml"
manifest_placeholder=__JULIA_PRECOMPILE_BENCHMARK_CHECKOUT__

rewrite_manifest_path_in_place() {
    local manifest=$1
    local entry_name=$2
    local old_path=$3
    local new_path=$4
    local rewritten
    rewritten=$(mktemp "$temporary_root/manifest-rewrite.XXXXXX")
    if ! rewrite_manifest_path "$manifest" "$rewritten" "$entry_name" "$old_path" "$new_path"; then
        rm -f -- "$rewritten"
        return 1
    fi
    mv -- "$rewritten" "$manifest"
}

rewrite_all_checkout_paths() {
    local input_path=$1
    local output_path=$2
    local old_root=$3
    local new_root=$4
    cp -- "$input_path" "$output_path"
    rewrite_manifest_path_in_place "$output_path" "$package_name" "$old_root" "$new_root" || return 1
    for source_index in "${!source_names[@]}"; do
        source_path=${source_paths[$source_index]}
        rewrite_manifest_path_in_place \
            "$output_path" "${source_names[$source_index]}" \
            "$old_root/$source_path" "$new_root/$source_path" || return 1
    done
}

validate_stable_manifest_paths() {
    local checked_manifest=$1
    local actual_path
    actual_path=$(manifest_entry_path "$checked_manifest" "$package_name") || return 1
    [[ $actual_path == "$checkout_link" ]] || return 1
    for source_index in "${!source_names[@]}"; do
        source_path=${source_paths[$source_index]}
        actual_path=$(manifest_entry_path "$checked_manifest" "${source_names[$source_index]}") || return 1
        [[ $actual_path == "$checkout_link/$source_path" ]] || return 1
    done
}

stabilize_resolved_manifest_paths() {
    local actual_path actual_source expected_source entry_name source_path
    actual_path=$(manifest_entry_path "$manifest_path" "$package_name") || {
        echo "consumer Manifest must contain one path entry for $package_name" >&2
        return 1
    }
    if [[ $actual_path = /* ]]; then
        actual_source=$(realpath -e -- "$actual_path")
    else
        actual_source=$(realpath -e -- "$environment_dir/$actual_path")
    fi
    [[ $actual_source == "$(realpath -e -- "$seed_checkout")" ]] || {
        echo "consumer Manifest $package_name path does not resolve to the detached seed checkout: $actual_path" >&2
        return 1
    }
    rewrite_manifest_path_in_place "$manifest_path" "$package_name" "$actual_path" "$checkout_link" || return 1

    for source_index in "${!source_names[@]}"; do
        entry_name=${source_names[$source_index]}
        source_path=${source_paths[$source_index]}
        actual_path=$(manifest_entry_path "$manifest_path" "$entry_name") || {
            echo "consumer Manifest must contain one path entry for $entry_name" >&2
            return 1
        }
        if [[ $actual_path = /* ]]; then
            actual_source=$(realpath -e -- "$actual_path")
        else
            actual_source=$(realpath -e -- "$environment_dir/$actual_path")
        fi
        expected_source=$(realpath -e -- "$seed_checkout/$source_path")
        [[ $actual_source == "$expected_source" ]] || {
            echo "consumer Manifest $entry_name path does not resolve to the detached path source: $actual_path" >&2
            return 1
        }
        rewrite_manifest_path_in_place \
            "$manifest_path" "$entry_name" "$actual_path" "$checkout_link/$source_path" || return 1
    done
}

if [[ -n $reuse_consumer_project ]]; then
    consumer_environment_mode=reused
    consumer_environment_source_project=$reuse_consumer_project
    consumer_environment_source_manifest=$reuse_consumer_manifest
    validate_consumer_project "$reuse_consumer_project" "$package_name" "$package_uuid" || {
        echo "reused consumer Project does not match the harness-generated Project" >&2
        exit 2
    }
    cp -- "$reuse_consumer_project" "$environment_dir/Project.toml"
    rewrite_all_checkout_paths \
        "$reuse_consumer_manifest" "$environment_dir/Manifest.toml" \
        "$manifest_placeholder" "$checkout_link" || {
        echo "reused consumer Manifest does not contain the expected normalized checkout paths" >&2
        exit 2
    }
    consumer_environment_source_project_sha256=$(sha256sum "$reuse_consumer_project" | awk '{print $1}')
    consumer_environment_source_manifest_sha256=$(sha256sum "$reuse_consumer_manifest" | awk '{print $1}')
    validate_stable_manifest_paths "$manifest_path" || {
        echo "reused consumer Manifest paths failed validation" >&2
        exit 2
    }
    if ! JULIA_PKG_OFFLINE=true JULIA_DEPOT_PATH="$seed_depot" "$julia" "${julia_flags[@]}" -e '
        using Pkg
        Pkg.is_manifest_current(ARGS[1]) === true || error("consumer Manifest was not resolved from the consumer Project")
    ' "$environment_dir"; then
        echo "reused consumer Project and Manifest failed semantic validation" >&2
        exit 2
    fi
    JULIA_DEPOT_PATH="$seed_depot" "$julia" "${julia_flags[@]}" -e '
        using Pkg
        Pkg.activate(ARGS[1])
        Pkg.instantiate()
    ' "$environment_dir"
    cmp -s -- "$reuse_consumer_project" "$environment_dir/Project.toml" || {
        echo "Pkg.instantiate changed the reused consumer Project" >&2
        exit 1
    }
    validate_stable_manifest_paths "$manifest_path" || {
        echo "Pkg.instantiate changed the reused consumer Manifest paths" >&2
        exit 1
    }
    reused_normalized_manifest="$temporary_root/reused-normalized-Manifest.toml"
    rewrite_all_checkout_paths \
        "$manifest_path" "$reused_normalized_manifest" \
        "$checkout_link" "$manifest_placeholder" || {
        echo "failed to renormalize the reused consumer Manifest paths" >&2
        exit 1
    }
    cmp -s -- "$reuse_consumer_manifest" "$reused_normalized_manifest" || {
        echo "Pkg.instantiate changed the reused consumer Manifest" >&2
        exit 1
    }
else
    JULIA_DEPOT_PATH="$seed_depot" "$julia" "${julia_flags[@]}" -e '
        using Pkg
        Pkg.activate(ARGS[1])
        Pkg.develop(path=ARGS[2])
        Pkg.instantiate()
    ' "$environment_dir" "$checkout_link"
    stabilize_resolved_manifest_paths || exit 1
fi

[[ -f $manifest_path ]] || { echo "consumer manifest was not created" >&2; exit 1; }
resolved_manifest_sha256=$(sha256sum "$manifest_path" | awk '{print $1}')
if ! validate_stable_manifest_paths "$manifest_path"; then
    echo "consumer Manifest did not preserve the stable checkout paths" >&2
    exit 1
fi

if ! scenario_output=$(JULIA_DEPOT_PATH="$seed_depot" "$julia" "${julia_flags[@]}" --project="$environment_dir" "$driver_script" "$package_name" "$scenario_script"); then
    echo "failed to discover PRECOMPILE_BENCHMARKS" >&2
    exit 1
fi
[[ -n $scenario_output ]] || {
    echo "PRECOMPILE_BENCHMARKS must not be empty" >&2
    exit 2
}
mapfile -t scenarios <<< "$scenario_output"
for scenario_index in "${!scenarios[@]}"; do
    scenario=${scenarios[$scenario_index]}
    [[ $scenario =~ $token_pattern ]] || {
        echo "invalid PRECOMPILE_BENCHMARKS key: $scenario" >&2
        exit 2
    }
    for previous_index in "${!scenarios[@]}"; do
        [[ $previous_index -ge $scenario_index ]] && break
        [[ ${scenarios[$previous_index]} != "$scenario" ]] || {
            echo "duplicate PRECOMPILE_BENCHMARKS key: $scenario" >&2
            exit 2
        }
    done
done
scenario_list=$(IFS=,; printf '%s' "${scenarios[*]}")
find "$seed_depot/compiled" -type f -path "*/$package_name/*" -delete 2>/dev/null || true
find "$seed_depot/compiled" -type d -path "*/$package_name" -empty -delete 2>/dev/null || true

# Give every measured source tree one equivalent discarded cache build. Content-hash
# order is independent of baseline/candidate role; equal source states retain input order.
discarded_cache_warmup_indices=()
while IFS=$'\t' read -r _ warmup_index; do
    discarded_cache_warmup_indices+=("$warmup_index")
done < <(
    for index in "${!labels[@]}"; do
        warmup_key=$(printf '%s\0%s\0' "${commits[$index]}" "${checkout_state_sha256s[$index]}" | sha256sum | awk '{print $1}')
        printf '%s\t%s\n' "$warmup_key" "$index"
    done | sort -k1,1 -k2,2n
)
discarded_cache_warmup_order=
for warmup_position in "${!discarded_cache_warmup_indices[@]}"; do
    index=${discarded_cache_warmup_indices[$warmup_position]}
    verify_checkout "$index"
    label=${labels[$index]}
    checkout=${checkouts[$index]}
    ln -sfn -- "$checkout" "$checkout_link"
    warmup_depot="$temporary_root/discarded-cache-warmup-$warmup_position"
    mkdir -p -- "$warmup_depot"
    echo "Discarding cache warm-up for $label..." >&2
    JULIA_PKG_OFFLINE=true JULIA_DEPOT_PATH="$warmup_depot:$seed_depot" \
        "$julia" "${julia_flags[@]}" --project="$environment_dir" -e '
            name = Symbol(only(ARGS))
            Core.eval(Main, Expr(:using, Expr(:., name)))
        ' "$package_name"
    warmup_cache_bytes=$(find "$warmup_depot/compiled" -type f -path "*/$package_name/*" -printf '%s\n' | awk '{ total += $1 } END { print total + 0 }')
    [[ $warmup_cache_bytes -gt 0 ]] || {
        echo "discarded $package_name cache warm-up wrote no cache bytes: $label" >&2
        exit 1
    }
    [[ -z $discarded_cache_warmup_order ]] || discarded_cache_warmup_order+=,
    discarded_cache_warmup_order+="$label"
done

validate_consumer_project "$environment_dir/Project.toml" "$package_name" "$package_uuid" || {
    echo "consumer Project does not match the expected $package_name environment" >&2
    exit 1
}
cp -- "$environment_dir/Project.toml" "$consumer_project_path"
rewrite_all_checkout_paths \
    "$manifest_path" "$consumer_manifest_path" \
    "$checkout_link" "$manifest_placeholder" || {
    echo "failed to normalize the consumer Manifest checkout paths" >&2
    exit 1
}
if [[ $consumer_environment_mode == reused ]]; then
    cmp -s -- "$reuse_consumer_project" "$consumer_project_path" || {
        echo "copied consumer Project differs from the reused input" >&2
        exit 1
    }
    cmp -s -- "$reuse_consumer_manifest" "$consumer_manifest_path" || {
        echo "copied consumer Manifest differs from the reused input" >&2
        exit 1
    }
fi
consumer_project_sha256=$(sha256sum "$consumer_project_path" | awk '{print $1}')
normalized_manifest_sha256=$(sha256sum "$consumer_manifest_path" | awk '{print $1}')

non_reportable_reasons=()
[[ $allow_dirty == 0 ]] || non_reportable_reasons+=(allow_dirty_override_enabled)
[[ $allow_julia_mismatch == 0 ]] || non_reportable_reasons+=(julia_mismatch_override_enabled)
[[ $builds -ge 5 ]] || non_reportable_reasons+=(fewer_than_five_builds)
[[ $samples -ge 4 ]] || non_reportable_reasons+=(fewer_than_four_samples_per_build)
if [[ ${#non_reportable_reasons[@]} -eq 0 ]]; then
    reportable=true
    non_reportable_reason_list=
else
    reportable=false
    non_reportable_reason_list=$(IFS=,; echo "${non_reportable_reasons[*]}")
fi

{
    printf '%s\n' "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "julia=$julia_version"
    printf '%s\n' "kernel=$(uname -srvmo)"
    if [[ -r /etc/os-release ]]; then
        os_name=$(awk '$0 ~ /^PRETTY_NAME=/ { sub(/^[^=]*=/, ""); sub(/^"/, ""); sub(/"$/, ""); print; exit }' /etc/os-release)
        printf '%s\n' "os=$os_name"
    fi
    if command -v lscpu >/dev/null 2>&1; then
        printf '%s\n' "cpu=$(lscpu | awk -F: '/Model name/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }')"
    fi
    printf '%s\n' "julia_num_threads=$JULIA_NUM_THREADS"
    printf '%s\n' "julia_num_precompile_tasks=$JULIA_NUM_PRECOMPILE_TASKS"
    printf '%s\n' "openblas_num_threads=$OPENBLAS_NUM_THREADS"
    printf '%s\n' "omp_num_threads=$OMP_NUM_THREADS"
    printf '%s\n' "julia_load_path=$JULIA_LOAD_PATH"
    printf '%s\n' "pkg_auto_precompile=$JULIA_PKG_PRECOMPILE_AUTO"
    printf '%s\n' "pkg_offline_during_measurement=true"
    printf '%s\n' "builds=$builds"
    printf '%s\n' "recorded_samples_per_build=$samples"
    printf '%s\n' "discarded_cache_warmups_per_variant=1"
    printf '%s\n' "discarded_cache_warmup_order_policy=sha256_of_commit_and_state_then_argument_index"
    printf '%s\n' "discarded_cache_warmup_order=$discarded_cache_warmup_order"
    printf '%s\n' "discarded_warmups_per_build_and_scenario=1"
    printf '%s\n' "reportable=$reportable"
    printf '%s\n' "nonreportable_reasons=$non_reportable_reason_list"
    printf '%s\n' "allow_dirty=$allow_dirty"
    printf '%s\n' "allow_julia_mismatch=$allow_julia_mismatch"
    printf '%s\n' "package=$package_name"
    printf '%s\n' "package_uuid=$package_uuid"
    printf '%s\n' "total_metric=wall_import_start_to_first_task_end"
    printf '%s\n' "scenarios=$scenario_list"
    printf '%s\n' "candidate_baselines=$baseline_map_list"
    printf '%s\n' "schedule_policy=counterbalanced-v1"
    printf '%s\n' "schedule_candidate_index=one_based_candidate_argument_position"
    printf '%s\n' "schedule_comparison_policy=ascending_candidate_index_on_odd_builds_descending_candidate_index_on_even_builds"
    printf '%s\n' "schedule_pair_policy=baseline_then_candidate_when_build_plus_candidate_index_is_odd_candidate_then_baseline_when_even"
    for ((schedule_candidate_index = 1; schedule_candidate_index < ${#labels[@]}; schedule_candidate_index++)); do
        printf '%s\n' "schedule.candidate_index.${labels[$schedule_candidate_index]}=$schedule_candidate_index"
    done
    for ((schedule_build = 1; schedule_build <= builds; schedule_build++)); do
        set_comparison_order "$schedule_build"
        schedule_value=
        for schedule_candidate_index in "${comparison_indices[@]}"; do
            set_pair_order "$schedule_build" "$schedule_candidate_index"
            baseline_index=${candidate_baseline_indices[$schedule_candidate_index]}
            pair_value=
            for schedule_variant_index in "${pair_indices[@]}"; do
                if [[ $schedule_variant_index -eq $baseline_index ]]; then
                    schedule_role=baseline
                else
                    schedule_role=candidate
                fi
                [[ -z $pair_value ]] || pair_value+=,
                pair_value+="$schedule_role:${labels[$schedule_variant_index]}"
            done
            [[ -z $schedule_value ]] || schedule_value+=';'
            schedule_value+="comparison:${labels[$schedule_candidate_index]},$pair_value"
        done
        printf '%s\n' "schedule.build.$schedule_build=$schedule_value"
    done
    printf '%s\n' "consumer_environment_mode=$consumer_environment_mode"
    printf '%s\n' "seed_checkout_mode=$seed_checkout_mode"
    printf '%s\n' "consumer_project_sha256=$consumer_project_sha256"
    if [[ $consumer_environment_mode == reused ]]; then
        printf '%s\n' "consumer_environment_source_project=$consumer_environment_source_project"
        printf '%s\n' "consumer_environment_source_manifest=$consumer_environment_source_manifest"
        printf '%s\n' "consumer_environment_source_project_sha256=$consumer_environment_source_project_sha256"
        printf '%s\n' "consumer_environment_source_manifest_sha256=$consumer_environment_source_manifest_sha256"
    fi
    printf '%s\n' "manifest_sha256=$normalized_manifest_sha256"
    printf '%s\n' "resolved_manifest_sha256=$resolved_manifest_sha256"
    printf '%s\n' "harness_version=$harness_version"
    printf '%s\n' "harness_repository=${PRECOMPILE_BENCHMARK_HARNESS_REPOSITORY:-local}"
    printf '%s\n' "harness_ref=${PRECOMPILE_BENCHMARK_HARNESS_REF:-local}"
    printf '%s\n' "harness_run_sha256=$harness_run_sha256"
    printf '%s\n' "harness_driver_sha256=$harness_driver_sha256"
    printf '%s\n' "harness_scenarios_sha256=$harness_scenarios_sha256"
    printf '%s\n' "harness_summarize_sha256=$harness_summarize_sha256"
    for index in "${!labels[@]}"; do
        printf '%s\n' "variant.${labels[$index]}.checkout=${checkouts[$index]}"
        printf '%s\n' "variant.${labels[$index]}.commit=${commits[$index]}"
        printf '%s\n' "variant.${labels[$index]}.initial_dirty=${checkout_initial_dirty[$index]}"
        printf '%s\n' "variant.${labels[$index]}.state_sha256=${checkout_state_sha256s[$index]}"
        for source_index in "${!source_names[@]}"; do
            flat_source_index=$((source_index * ${#labels[@]} + index))
            printf '%s\n' "variant.${labels[$index]}.source.${source_names[$source_index]}.path=${source_paths[$source_index]}"
            printf '%s\n' "variant.${labels[$index]}.source.${source_names[$source_index]}.head_tree=${source_head_trees[$flat_source_index]}"
            printf '%s\n' "variant.${labels[$index]}.source.${source_names[$source_index]}.state_sha256=${source_state_sha256s[$flat_source_index]}"
        done
    done
} > "$metadata_path"

printf '%s\n' $'comparison\tlabel\tcheckout\tcommit\tbuild\tsample\tscenario\tbuild_seconds\tcache_bytes\timport_seconds\tfirst_seconds\tfirst_compile_seconds\tfirst_recompile_seconds\ttotal_seconds\twarm_seconds\twarm_compile_seconds\twarm_recompile_seconds' > "$raw_path"

export JULIA_PKG_OFFLINE=true
for build in $(seq 1 "$builds"); do
    set_comparison_order "$build"
    for candidate_index in "${comparison_indices[@]}"; do
        comparison=${labels[$candidate_index]}
        baseline_index=${candidate_baseline_indices[$candidate_index]}
        set_pair_order "$build" "$candidate_index"
        for index in "${pair_indices[@]}"; do
            verify_checkout "$index"
            label=${labels[$index]}
            checkout=${checkouts[$index]}
            commit=${commits[$index]}
            ln -sfn -- "$checkout" "$checkout_link"

            if [[ $index -eq $baseline_index ]]; then
                role=baseline
            else
                role=candidate
            fi
            run_depot="$temporary_root/run-$candidate_index-$role-$build"
            mkdir -p -- "$run_depot"
            echo "Building cache for $comparison: $label ($build/$builds)..." >&2
            build_started=$(date +%s.%N)
            JULIA_DEPOT_PATH="$run_depot:$seed_depot" "$julia" "${julia_flags[@]}" --project="$environment_dir" -e '
                name = Symbol(only(ARGS))
                Core.eval(Main, Expr(:using, Expr(:., name)))
            ' "$package_name"
            build_finished=$(date +%s.%N)
            build_seconds=$(awk -v started="$build_started" -v finished="$build_finished" 'BEGIN { printf "%.9f", finished - started }')
            cache_bytes=$(find "$run_depot/compiled" -type f -path "*/$package_name/*" -printf '%s\n' | awk '{ total += $1 } END { print total + 0 }')
            [[ $cache_bytes -gt 0 ]] || { echo "$package_name cache was not written to the run depot" >&2; exit 1; }

            for scenario in "${scenarios[@]}"; do
                [[ -n $scenario && $scenario != *[[:space:]]* ]] || {
                    echo "scenario names must be nonempty and contain no whitespace: $scenario" >&2
                    exit 2
                }
                echo "Discarding filesystem warm-up for $comparison: $label/$scenario build $build..." >&2
                JULIA_DEPOT_PATH="$run_depot:$seed_depot" "$julia" "${julia_flags[@]}" --project="$environment_dir" \
                    "$driver_script" "$package_name" "$scenario_script" "$scenario" >/dev/null

                for sample in $(seq 1 "$samples"); do
                    echo "Sampling $comparison: $label/$scenario build $build ($sample/$samples)..." >&2
                    scenario_output=$(JULIA_DEPOT_PATH="$run_depot:$seed_depot" "$julia" "${julia_flags[@]}" --project="$environment_dir" \
                        "$driver_script" "$package_name" "$scenario_script" "$scenario")
                    result=$(printf '%s\n' "$scenario_output" | awk -F '\t' '$1 == "RESULT" { print; count += 1 } END { if (count != 1) exit 1 }') || {
                        echo "scenario did not emit exactly one RESULT row: $label/$scenario" >&2
                        exit 1
                    }
                    IFS=$'\t' read -r marker measured_scenario import_seconds first_seconds first_compile first_recompile total_seconds warm_seconds warm_compile warm_recompile <<< "$result"
                    [[ $marker == RESULT && $measured_scenario == "$scenario" ]] || {
                        echo "malformed scenario result: $result" >&2
                        exit 1
                    }
                    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                        "$comparison" "$label" "$checkout" "$commit" "$build" "$sample" "$scenario" \
                        "$build_seconds" "$cache_bytes" "$import_seconds" "$first_seconds" \
                        "$first_compile" "$first_recompile" "$total_seconds" "$warm_seconds" \
                        "$warm_compile" "$warm_recompile" >> "$raw_path"
                done
            done
        done
    done
done

for index in "${!labels[@]}"; do
    verify_checkout "$index"
done
verify_tool_files
verify_harness_snapshots

JULIA_DEPOT_PATH="$seed_depot" "$julia" "${julia_flags[@]}" "$summarize_script" \
    "$raw_path" "$summary_path" "$build_summary_path" "$markdown_path"
echo "Wrote $raw_path, $summary_path, $build_summary_path, and $markdown_path" >&2
