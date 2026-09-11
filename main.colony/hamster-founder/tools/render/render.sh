#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") TEMPLATE OUTPUT_FOLDER=PATH KEY=VALUE [...]" >&2
    echo "Render TEMPLATE with the supplied fields into a unique file in OUTPUT_FOLDER." >&2
}

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit $([[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]] && echo 0 || echo 2)
fi

template=$1
shift

if [[ ! -f "$template" ]]; then
    echo "Template not found: $template" >&2
    exit 1
fi

output_folder=""
fields=()
field_count=0
for field in "$@"; do
    if [[ "$field" != *=* ]]; then
        echo "Invalid field '$field'. Use KEY=VALUE." >&2
        exit 2
    fi
    key=${field%%=*}
    value=${field#*=}
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Invalid field name '$key'. Use letters, numbers, and underscores." >&2
        exit 2
    fi
    if [[ "$key" == "OUTPUT_FOLDER" ]]; then
        [[ -n "$value" ]] || { echo "OUTPUT_FOLDER cannot be empty." >&2; exit 2; }
        output_folder=$value
        continue
    fi
    export "$field"
    fields+=("$key")
    field_count=$((field_count + 1))
done

[[ -n "$output_folder" ]] || { echo "OUTPUT_FOLDER is required." >&2; exit 2; }
[[ "$field_count" -gt 0 ]] || { echo "At least one substitution field is required." >&2; exit 2; }

mkdir -p "$output_folder"
[[ -w "$output_folder" ]] || { echo "Output folder is not writable: $output_folder" >&2; exit 1; }

template_name=$(basename "$template")
template_stem=${template_name%.*}
[[ -n "$template_stem" ]] || template_stem="rendered"
run_id=$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)
output_file="$output_folder/${template_stem}-$(date +%Y%m%d-%H%M%S)-${run_id}.txt"
tmp_file="$output_file.tmp.$$"

IFS= read -r -d '' rendered < "$template" || true
for key in "${fields[@]}"; do
    value=${!key}
    placeholder="\${$key}"
    rendered=${rendered//"$placeholder"/$value}
done
printf '%s' "$rendered" > "$tmp_file"
mv "$tmp_file" "$output_file"
printf '%s\n' "$output_file"
