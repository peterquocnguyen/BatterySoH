#!/usr/bin/env python3
"""Read `llvm-cov export -summary-only` JSON on stdin; gate Sources/BatteryKit line coverage.

    xcrun llvm-cov export -summary-only <test-binary> -instr-profile <profdata> \
        | python3 -I scripts/ci/coverage_report.py <floor-percent>

Called by scripts/ci/coverage.sh.
"""

import json
import sys

floor = float(sys.argv[1])
report = json.load(sys.stdin)
files = [f for f in report["data"][0]["files"] if "/Sources/BatteryKit/" in f["filename"]]
if not files:
    sys.exit("error: no Sources/BatteryKit files in the coverage report")

for f in sorted(files, key=lambda f: f["summary"]["lines"]["percent"]):
    name = f["filename"].split("/Sources/", 1)[1]
    print(f"{f['summary']['lines']['percent']:6.1f}%  {name}")

covered = sum(f["summary"]["lines"]["covered"] for f in files)
total = sum(f["summary"]["lines"]["count"] for f in files)
pct = 100 * covered / total
print(f"BatteryKit line coverage: {pct:.1f}% ({covered}/{total}), floor {floor:g}%")
if pct < floor:
    sys.exit(f"error: coverage {pct:.1f}% is below the floor {floor:g}% (.github/coverage-floor)")
