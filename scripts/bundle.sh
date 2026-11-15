#!/usr/bin/env bash
# Build a release BatterySoH and wrap it into "build/BatterySoH.app" (ad-hoc signed).
#
#   scripts/bundle.sh          # build/BatterySoH.app
#   scripts/bundle.sh --zip    # also build/BatterySoH-<version>.zip
#
# Safe to re-run: the .app is rebuilt from scratch each time.
# Needs Xcode (not just Command Line Tools): the app uses SwiftUI macros (@State) whose
# compiler plugin ships only with Xcode.
set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd)"

make_zip=false
for arg in "$@"; do
    case "$arg" in
        --zip) make_zip=true ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

info_plist="$root/Resources/Info.plist"
icon="$root/Resources/AppIcon.icns"
app="$root/build/BatterySoH.app"

plutil -lint -s "$info_plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"

dev_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ "$dev_dir" == *CommandLineTools* ]]; then
    echo "warning: Command Line Tools selected ($dev_dir); the SwiftUI app target needs Xcode." >&2
    echo "         Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app" >&2
fi

echo "==> swift build -c release --product BatterySoH"
swift build -c release --product BatterySoH
bin_dir="$(swift build -c release --show-bin-path)"
binary="$bin_dir/BatterySoH"
[[ -x "$binary" ]] || { echo "error: no binary at $binary" >&2; exit 1; }

echo "==> assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$executable"
# SwiftPM's link step records the deployment target (14.0) as the SDK version in
# LC_BUILD_VERSION. AppKit/SwiftUI gate the macOS 26+ design on the linked SDK, so without
# this the app runs in compatibility mode: old opaque materials instead of Liquid Glass for
# the menu bar panel and title bar. Stamp the SDK we actually built against (re-signed below).
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
min_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")"
echo "==> LC_BUILD_VERSION: minos $min_os, sdk $sdk_version"
xcrun vtool -set-build-version macos "$min_os" "$sdk_version" -replace \
    -output "$app/Contents/MacOS/$executable" "$app/Contents/MacOS/$executable" 2>&1 \
    | { grep -v "code signature will be invalid" || true; } >&2
cp "$info_plist" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
if [[ -f "$icon" ]]; then
    cp "$icon" "$app/Contents/Resources/AppIcon.icns"
else
    echo "warning: $icon missing (run: swift scripts/make-icon.swift)" >&2
fi
# SwiftPM resource bundles (none today), copied so Bundle.module keeps working if added.
shopt -s nullglob
for res in "$bin_dir"/*.bundle; do
    case "$(basename "$res")" in *Tests*) continue ;; esac
    cp -R "$res" "$app/Contents/Resources/"
done
shopt -u nullglob

echo "==> codesign (ad-hoc)"
codesign --force --sign - --options runtime --timestamp=none "$app"
codesign --verify --strict "$app"

if $make_zip; then
    zip="$root/build/BatterySoH-$version.zip"
    rm -f "$zip"
    # --norsrc/--noextattr: keep local xattrs (com.apple.provenance…) out as ._ files.
    ditto -c -k --keepParent --norsrc --noextattr "$app" "$zip"
    echo "$zip"
fi

echo "$app"
