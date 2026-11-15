#!/usr/bin/env bash
# Decide whether a change needs the full CI run, or only touches documentation.
#
#   scripts/ci/changes.sh <base-ref> [head-ref]    # prints code=true|false
#
# Documentation = Markdown anywhere, everything under docs/, LICENSE*. Anything else
# (sources, tests, scripts, Package.swift, Resources, the workflow itself) is "code".
# In GitHub Actions the result is also written to $GITHUB_OUTPUT.
# With no usable base (first push, force push, manual run) it answers code=true.
set -euo pipefail

base="${1:-}"
head="${2:-HEAD}"

emit() {
    echo "code=$1"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "code=$1" >>"$GITHUB_OUTPUT"
    fi
    exit 0
}

if [[ -z "$base" || "$base" =~ ^0+$ ]] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    echo "no usable base ($base): running everything" >&2
    emit true
fi

files="$(git diff --name-only "$base...$head")"
if [[ -z "$files" ]]; then
    emit true
fi

echo "changed files:" >&2
echo "$files" | sed 's/^/  /' >&2

while IFS= read -r f; do
    case "$f" in
        *.md | docs/* | LICENSE*) ;;
        *) emit true ;;
    esac
done <<<"$files"

echo "documentation only: skipping build and test jobs" >&2
emit false
