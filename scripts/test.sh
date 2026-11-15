#!/usr/bin/env bash
# Run the BatteryKit test suite with either Xcode or Command Line Tools.
#
#   scripts/test.sh                 # all tests
#   scripts/test.sh --filter Fmt    # extra args go to `swift test`
#
# With Xcode selected this is just `swift test`.
# With Command Line Tools only, two things differ:
#   1. SwiftPM's swiftbuild engine doesn't pass the Swift Testing macro plugin path, so
#      `@Test` / `#expect` fail with "plugin for module 'TestingMacros' not found". We add
#      `-plugin-path <CLT>/usr/lib/swift/host/plugins/testing`.
#   2. CLT ships no SwiftUIMacros plugin, and the macOS 27 SDK declares `@State` as a macro,
#      so the BatterySoH app target cannot compile. We build only the BatteryKitTests
#      target and run with --skip-build.
set -euo pipefail
cd "$(dirname "$0")/.."

dev_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"

if [[ "$dev_dir" == *CommandLineTools* ]]; then
    plugins="$dev_dir/usr/lib/swift/host/plugins/testing"
    echo "Command Line Tools toolchain ($dev_dir): building BatteryKitTests only." >&2
    swift build --target BatteryKitTests -Xswiftc -plugin-path -Xswiftc "$plugins"
    exec swift test --skip-build "$@"
fi

exec swift test "$@"
