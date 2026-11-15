# Battery Buddy

A small, native macOS menu bar app that shows what the battery and charger in your Mac are
doing right now, and how the battery ages over time. SwiftUI, no dependencies, read-only.

Version 0.1.1 (build 2) · by Peter Quoc

## Features

- **Menu bar item**: charge percent plus time left, a charging bolt, or watts.
- **Power flow popover**: charger → Mac → battery, with live watts on each arrow; adapter
  wattage, active USB-C PD profile and every profile the charger offers; battery voltage,
  current and temperature.
- **Battery summary**: precise charge, health (full-charge vs design capacity), cycles
  (`183 of 1000`), time to full or empty, and "charging on hold" when macOS is holding the
  charge (optimized charging / charge limit).
- **This Mac window**: model, capacities in mAh, cycles, temperature, adapter, Low Power
  Mode, and battery gauge details.
- **History**: one sample per day, a monthly table (average health, max cycles), a health
  chart, and CSV export.
- **About**: version, author, privacy note, data-source credits, and **Copy Diagnostics**,
  which puts a plain-text report (app and macOS version, Mac model, current battery and
  charger readings) on the clipboard for bug reports.
- **`bbstat` CLI**: the same data in the terminal, as text or JSON.

## Screenshots

_Coming soon._ <!-- popover (charging), popover (on battery), window: This Mac, window: History -->

## Requirements

- macOS 14 Sonoma or later, on a Mac with a battery. Apple Silicon is the primary target;
  Intel is best effort.
- To build the app: **Xcode** (Swift 6). The app uses SwiftUI macros such as `@State`, and
  their compiler plugin ships only with Xcode, not with the Command Line Tools.
- To build and test `BatteryKit` and `bbstat`, the Command Line Tools are enough
  (see [Testing](#testing)).

## Build and run

```sh
swift build                      # debug build of everything
swift run bbstat                 # print the current battery snapshot
swift run bbstat --json          # same, as JSON
swift run bbstat --raw           # raw AppleSmartBattery registry as an XML plist
swift run BatteryBuddy           # run the menu bar app from the build folder
```

## Testing

```sh
swift test                       # with Xcode selected
scripts/test.sh                  # works with Xcode or Command Line Tools only
```

Tests use Swift Testing (`import Testing`) and live in `Tests/BatteryKitTests`. Parser
tests run against real `AppleSmartBattery` registry dumps in `Tests/BatteryKitTests/Fixtures`
(serial numbers scrubbed) plus variants derived from them in code.

With only the Command Line Tools installed, plain `swift test` fails for two reasons:
SwiftPM doesn't pass the Swift Testing macro plugin path (`plugin for module
'TestingMacros' not found`), and the app target can't compile without Xcode's
SwiftUI macro plugin. `scripts/test.sh` handles both by building only the test target with
`-plugin-path <CLT>/usr/lib/swift/host/plugins/testing`.

## Bundle the app

```sh
scripts/bundle.sh                # build/Battery Buddy.app (release, ad-hoc signed)
scripts/bundle.sh --zip          # also build/BatteryBuddy-<version>.zip
```

The bundle is ad-hoc signed, not notarized. Gatekeeper will block it on other Macs the
first time. Right-click the app and choose **Open**, or run
`xattr -dr com.apple.quarantine "Battery Buddy.app"`.

The app icon is generated in code. To redraw it:

```sh
swift scripts/make-icon.swift build/AppIcon.iconset   # writes Resources/AppIcon.icns
```

Version, build number, copyright and bundle id live in `Resources/Info.plist`. The About tab
reads them from the bundle; unbundled runs (`swift run`, `--render`) fall back to constants in
`AboutInfo` (`Sources/BatteryBuddy/Views/Window/AboutView.swift`), so bump both together.

## Where the data comes from

| Data | Source |
| --- | --- |
| Charge, capacities, cycles, voltage, current, charging flags | IORegistry `AppleSmartBattery` |
| Charger watts and USB-C PD profiles | `AppleSmartBattery` → `AdapterDetails` (`UsbHvcMenu`, `UsbHvcHvcIndex`) |
| Mac power draw, power from the wall | `AppleSmartBattery` → `PowerTelemetryData` |
| "Charging on hold" | `AppleSmartBattery` → `ChargerData.NotChargingReason` |
| Time to empty or full | IOPowerSources (`IOPSCopyPowerSourcesInfo`) |
| Battery temperature | `AppleSmartBattery.Temperature`, else SMC keys `TB0T`–`TB2T` |
| Mac model | IODeviceTree `product-name`, `sysctl hw.model` |

Values the hardware doesn't report are shown as "—", never as 0.

## Privacy

Battery Buddy only reads. It never writes SMC keys or changes how the Mac charges, needs no
root or helper tool, and makes no network connections. Apart from its settings (in
`UserDefaults`), the only thing it writes is its daily history at
`~/Library/Application Support/BatteryBuddy/history.json`.

## About

Battery Buddy is written by Peter Quoc. © 2026 Peter Quoc.

The diagnostics report leaves out the battery serial number. Website, support and license
links are not set yet.

## Project layout

```
Sources/BatteryKit/     models, parser, IOKit/SMC readers, history, formatting
Sources/BatteryBuddy/   SwiftUI app (menu bar popover, window, settings)
Sources/bbstat/         CLI
Tests/BatteryKitTests/  Swift Testing suite and registry fixtures
scripts/                bundle.sh, test.sh, make-icon.swift
docs/SPEC.md            product spec
```
