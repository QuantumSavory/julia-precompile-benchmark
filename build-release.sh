#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "usage: $0 OUTPUT_DIR" >&2
    exit 2
}

[[ $# == 1 ]] || usage

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
version=$(<"$repository_root/VERSION")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "invalid VERSION: $version" >&2
    exit 2
}

output_dir=$1
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
package_name="julia-precompile-benchmark-v$version"
archive_path="$output_dir/$package_name.tar.gz"
checksum_path="$output_dir/SHA256SUMS"
for output_path in "$archive_path" "$checksum_path"; do
    [[ ! -e $output_path && ! -L $output_path ]] || {
        echo "refusing to overwrite release output: $output_path" >&2
        exit 2
    }
done

temporary_root=$(mktemp -d)
trap 'rm -rf -- "$temporary_root"' EXIT
package_root="$temporary_root/$package_name"
install -d -m 0755 -- "$package_root"

regular_files=(LICENSE README.md VERSION scenario-driver.jl summarize.jl)
executable_files=(run.sh)
for relative_path in "${regular_files[@]}" "${executable_files[@]}"; do
    [[ -f "$repository_root/$relative_path" && -r "$repository_root/$relative_path" ]] || {
        echo "release input is missing or unreadable: $relative_path" >&2
        exit 2
    }
done
for relative_path in "${regular_files[@]}"; do
    install -m 0644 -- "$repository_root/$relative_path" "$package_root/$relative_path"
done
for relative_path in "${executable_files[@]}"; do
    install -m 0755 -- "$repository_root/$relative_path" "$package_root/$relative_path"
done

tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "$temporary_root" \
    -cf - \
    "$package_name" | gzip -n > "$archive_path"

(
    cd -- "$output_dir"
    sha256sum "$package_name.tar.gz"
) > "$checksum_path"
