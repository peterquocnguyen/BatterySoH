# BatterySoH — agent guide

Native macOS menu bar battery monitor. Spec: `docs/SPEC.md` (features F1–F10). Read it first.

## Build / run / test

- Toolchain: Swift 6.x via SwiftPM. The app target needs Xcode (SwiftUI `@State` is a macro
  in the macOS 27 SDK and CLT has no SwiftUIMacros plugin). BatteryKit, sohstat and the tests
  build with Command Line Tools alone via `scripts/test.sh`.
- `swift build` — builds everything. `swift run sohstat` — prints live battery data
  (`--json`, `--raw` registry dump, `--smc` temperature probe, `--devices` other devices).
- `swift test` — Swift Testing (`import Testing`), not XCTest. `scripts/test.sh` does the
  same and also works when only Command Line Tools are selected.
- `.build/debug/BatterySoH --render <dir>` — headless render of every `RenderEntry`
  (popover states, window sidebar, each window page, Settings › About) in light + dark to PNG, then exits. Use it to look at UI
  changes: render, then open the PNGs with the Read tool.
- `scripts/bundle.sh` — release build wrapped into `build/BatterySoH.app`. It re-stamps
  the binary's LC_BUILD_VERSION with the real SDK version (SwiftPM records 14.0); without it
  macOS 26+ runs the app in compatibility mode with no Liquid Glass. So glass only shows in the
  bundle, not in a raw `.build/debug/BatterySoH` run.
- `SOH_DEBUG_WINDOWS=1 "build/BatterySoH.app/Contents/MacOS/BatterySoH"` logs the popover and
  window view hierarchies to stderr once.

## Layout

- `Sources/BatteryKit` — pure library. Models (`BatterySnapshot`, `PowerAdapter`), pure
  `BatteryParser`, IOKit readers (`SmartBatteryRegistry`, `PowerSources`, `MacInfo`),
  `SMC` (temperature), `HistoryStore`/`HistoryAggregator`, `Fmt` formatting, `Samples`.
  Other devices (F10): `DeviceBattery` + pure `AccessoryParser`/`MobileBatteryParser` in
  `Devices.swift`, `AccessoryPowerSources` in `Readers.swift`, private MobileDevice code only in
  `MobileDevices.swift`, private Sharing (Instant Hotspot) code only in `NearbyDevices.swift`
  (its levels are `isApproximate`); `LastExactReadingStore` (Devices.swift) keeps each
  iPhone / iPad's last exact reading for when it disconnects; `HotspotParser.merge` orders
  connected > remembered > hotspot. `BatteryCondition` (F11): Normal / Service Recommended,
  maximum capacity, iPhone peak performance, rated cycles; `MacReportedHealth` runs
  `system_profiler` for macOS's own verdict.
- `Sources/BatterySoH` — SwiftUI app. `BatteryModel` (@Observable, owns refresh policy),
  `Views/Popover/*` (F1–F3), `Views/Window/*`, `RenderHarness`. The window is device first:
  `MainWindowView` (NavigationSplitView, selection in `window.selectedDevice`, `WindowSelection`
  fallback rules), `WindowSidebar` (rows + `WindowSidebarRendering` for `--render`),
  `WindowThisMacView` (`WindowMacPage` = F4 content + `WindowHistorySection` from
  `HistoryView`), `WindowDevicePage` (iPhone / iPad / accessory page, F10). `SettingsView` is a
  TabView: General (F6) + About (`AboutView`, F9). ImageRenderer can't draw List / ScrollView /
  NavigationSplitView / TabView / Form, so pages and sidebar rows stay custom-drawn and only the
  outer layer uses those containers.
- `Sources/sohstat` — CLI.
- `Tests/BatteryKitTests` — fixtures are real `AppleSmartBattery` dumps with serial scrubbed.

## Rules

- Never write SMC keys. The only controls are macOS's own (Energy Mode via `pmset`, charge-limit
  override via PowerUI) — see SPEC F8.
- Unknown hardware values are `nil` and render as `Fmt.dash` ("—"). Never show 0 °C / 0 W
  for "unknown".
- Light appearance is the primary design; dark must also look right (system setting).
- No third-party dependencies. Target macOS 14+.
- UI polls only while visible (`model.surfaceAppeared()/surfaceDisappeared()`).
- Never commit real battery serial numbers in fixtures.
