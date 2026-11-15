#!/usr/bin/env python3
"""Repository rules from CLAUDE.md that a compiler cannot check.

    python3 -I scripts/ci/hygiene.py

Runs anywhere with Python 3 (no macOS tools needed). Exits 1 and lists every
violation when a rule is broken:

  1. Fixtures carry no real battery serial numbers: every plist key containing
     "serial" holds an empty string or a TEST… placeholder.
  2. No third-party dependencies: Package.swift declares no `.package(` and
     there is no Package.resolved.
  3. SMC is read-only: SMC.swift only ever issues the read commands (5 = read
     bytes, 9 = read key info); the write command (6) never appears.
  4. Resources/Info.plist parses, and its version strings are well formed.
"""

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
errors: list[str] = []


def fail(msg: str) -> None:
    errors.append(msg)


def walk(node, path: str):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from walk(value, f"{path}.{key}")
            yield path, key, value
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from walk(value, f"{path}[{i}]")


def check_fixtures() -> None:
    fixtures = sorted((ROOT / "Tests").rglob("Fixtures/*.plist"))
    if not fixtures:
        fail("no fixtures found under Tests/**/Fixtures (path changed?)")
    for plist in fixtures:
        rel = plist.relative_to(ROOT)
        try:
            data = plistlib.loads(plist.read_bytes())
        except Exception as exc:  # noqa: BLE001 - report any parse failure
            fail(f"{rel}: not a valid plist ({exc})")
            continue
        for path, key, value in walk(data, ""):
            if "serial" not in key.lower():
                continue
            if isinstance(value, bytes):
                value = value.decode("ascii", "replace")
            if isinstance(value, str) and value and not value.startswith("TEST"):
                fail(f"{rel}: {path}.{key} = {value!r} looks like a real serial; use a TEST… placeholder")


def check_dependencies() -> None:
    manifest = (ROOT / "Package.swift").read_text()
    code = "\n".join(line.split("//", 1)[0] for line in manifest.splitlines())
    if ".package(" in code:
        fail("Package.swift declares a package dependency; the project allows none")
    if (ROOT / "Package.resolved").exists():
        fail("Package.resolved exists; the project allows no package dependencies")


def check_smc() -> None:
    smc = ROOT / "Sources/BatteryKit/SMC.swift"
    text = smc.read_text()
    commands = {int(v) for v in re.findall(r"static\s+let\s+cmd\w*\s*:\s*UInt8\s*=\s*(\d+)", text)}
    if not commands:
        fail("SMC.swift: no `static let cmd…: UInt8 = n` command constants found (rule check needs updating)")
    if commands - {5, 9}:
        fail(f"SMC.swift: unexpected SMC command(s) {sorted(commands - {5, 9})}; only reads (5, 9) are allowed")
    if re.search(r"(?i)smc\w*write|writekey|cmdwrite", text):
        fail("SMC.swift: mentions an SMC write; SMC keys must never be written (SPEC F8)")
    for path in (ROOT / "Sources").rglob("*.swift"):
        if path == smc:
            continue
        body = path.read_text()
        if "IOConnectCallStructMethod" in body and "AppleSMC" in body:
            fail(f"{path.relative_to(ROOT)}: talks to AppleSMC outside SMC.swift")


def check_info_plist() -> None:
    path = ROOT / "Resources/Info.plist"
    try:
        info = plistlib.loads(path.read_bytes())
    except Exception as exc:  # noqa: BLE001
        fail(f"Resources/Info.plist: not a valid plist ({exc})")
        return
    short = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if not re.fullmatch(r"\d+\.\d+\.\d+", short):
        fail(f"Info.plist: CFBundleShortVersionString {short!r} is not MAJOR.MINOR.PATCH")
    if not re.fullmatch(r"\d+", build):
        fail(f"Info.plist: CFBundleVersion {build!r} is not an integer")
    if info.get("CFBundleExecutable") != "BatterySoH":
        fail("Info.plist: CFBundleExecutable must be BatterySoH (scripts/bundle.sh copies that binary)")
    if info.get("LSMinimumSystemVersion") != "14.0":
        fail("Info.plist: LSMinimumSystemVersion must stay 14.0 (Package.swift targets macOS 14)")


for check in (check_fixtures, check_dependencies, check_smc, check_info_plist):
    check()

if errors:
    print(f"hygiene: {len(errors)} problem(s)")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
print("hygiene: ok (fixtures, dependencies, SMC read-only, Info.plist)")
