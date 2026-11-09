#!/bin/bash
set -euo pipefail
base=$(cd "$(dirname "$0")" && pwd)
repo="$1";pmt="$2";before="${3:-55ca70579861954a21cfbd22d96e12059fec68db}"
scratch=$(mktemp -d /tmp/fastra-path-regression.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
for variant in before after; do
    mkdir "$scratch/$variant"
    if [[ "$variant" == before ]]; then
        git -C "$repo" show "$before:app/Sources/Fastra/MarkdownImport.swift" > "$scratch/$variant/MarkdownImport.swift"
        git -C "$repo" show "$before:app/Sources/Fastra/MarkdownImportService.swift" > "$scratch/service.swift"
    else
        cp "$repo/app/Sources/Fastra/MarkdownImport.swift" "$scratch/$variant/MarkdownImport.swift"
        cp "$repo/app/Sources/Fastra/MarkdownImportService.swift" "$scratch/service.swift"
    fi
    sed '/\/\/ Eigene Erweiterung/,$d' "$scratch/service.swift" | sed '/^import AppKit$/d' > "$scratch/$variant/MarkdownImportService.swift"
    sed -n '/^\/\/\/ Sichtbarer Zustand der Umwandlung\./,$p' "$scratch/service.swift" >> "$scratch/$variant/MarkdownImportService.swift"
    swiftc "$scratch/$variant/MarkdownImport.swift" "$scratch/$variant/MarkdownImportService.swift" "$repo/app/Sources/Fastra/MarkdownImportProgress.swift" "$pmt/scripts/linux-probes/contract/service-stubs.swift" "$base/path-regression.swift" -o "$scratch/$variant/probe"
    result=0
    "$scratch/$variant/probe" || result=$?
    if [[ "$variant" == before ]]; then [[ "$result" == 1 ]] || exit 1
    else [[ "$result" == 0 ]] || exit 1
    fi
done
echo 'PASS regression fails before the fix and succeeds after it; framework/process stubs only'
