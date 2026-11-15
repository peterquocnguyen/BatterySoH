#!/usr/bin/env bash
# Fail when BatteryKit line coverage drops below the floor in .github/coverage-floor.
#
#   swift test --enable-code-coverage && scripts/ci/coverage.sh
#
# Only Sources/BatteryKit counts: the app target is SwiftUI and checked by --render.
# IOKit / private-framework readers (SMC, Readers, MobileDevices…) can't run in tests,
# which is why the floor sits well under 100. Raise the floor when coverage goes up.
set -euo pipefail
cd "$(dirname "$0")/../.."

floor="$(tr -d '[:space:]' <.github/coverage-floor)"
bin="$(swift build --show-bin-path)"
profdata="$bin/codecov/default.profdata"
test_binary="$(find "$bin/BatteryKitTests.xctest" -type f -path '*/Contents/MacOS/*' | head -1)"

[[ -f "$profdata" ]] || { echo "error: $profdata missing; run swift test --enable-code-coverage first" >&2; exit 1; }
[[ -x "$test_binary" ]] || { echo "error: no test binary in $bin/BatteryKitTests.xctest" >&2; exit 1; }

xcrun llvm-cov export -summary-only "$test_binary" -instr-profile "$profdata" |
    python3 -I scripts/ci/coverage_report.py "$floor"
