#!/usr/bin/env bash
# Formatting and repository rules, the same checks CI runs before building.
#
#   scripts/lint.sh          # check only (fails on any finding)
#   scripts/lint.sh --fix    # rewrite files with swift format, then check
#
# Config: .swift-format. scripts/make-icon.swift is left out: swift format would
# fold its comment onto the `#!` line and break the shebang.
set -euo pipefail
cd "$(dirname "$0")/.."

paths=(Package.swift Sources Tests)

if [[ "${1:-}" == "--fix" ]]; then
    swift format format --in-place --recursive "${paths[@]}"
fi

echo "==> swift format lint --strict"
swift format lint --strict --recursive "${paths[@]}"
echo "==> hygiene"
python3 -I scripts/ci/hygiene.py
