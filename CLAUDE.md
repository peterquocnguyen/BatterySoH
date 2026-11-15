# Battery Buddy — agent guide

Native macOS menu bar battery monitor. Spec: `docs/SPEC.md` (features F1–F7). Read it first.

## Build / run / test

- Toolchain: Swift 6.x via SwiftPM. Xcode is optional; Command Line Tools are enough.
- `swift build` — builds everything. `swift run bbstat` — prints live battery data
  (`--json`, `--raw` registry dump, `--smc` temperature probe).
- `swift test` — Swift Testing (`import Testing`), not XCTest.
- `.build/debug/BatteryBuddy --render <dir>` — headless render of every `RenderEntry`
  (popover states, window tabs) in light + dark to PNG, then exits. Use it to look at UI
  changes: render, then open the PNGs with the Read tool.
- `scripts/bundle.sh` — release build wrapped into `build/Battery Buddy.app`.

## Layout

- `Sources/BatteryKit` — pure library. Models (`BatterySnapshot`, `PowerAdapter`), pure
  `BatteryParser`, IOKit readers (`SmartBatteryRegistry`, `PowerSources`, `MacInfo`),
  `SMC` (temperature), `HistoryStore`/`HistoryAggregator`, `Fmt` formatting, `Samples`.
- `Sources/BatteryBuddy` — SwiftUI app. `BatteryModel` (@Observable, owns refresh policy),
  `Views/Popover/*` (F1–F3), `Views/Window/*` (F4–F6), `RenderHarness`.
- `Sources/bbstat` — CLI.
- `Tests/BatteryKitTests` — fixtures are real `AppleSmartBattery` dumps with serial scrubbed.

## Rules

- Read-only app: never write SMC keys or change charging.
- Unknown hardware values are `nil` and render as `Fmt.dash` ("—"). Never show 0 °C / 0 W
  for "unknown".
- Light appearance is the primary design; dark must also look right (system setting).
- No third-party dependencies. Target macOS 14+.
- UI polls only while visible (`model.surfaceAppeared()/surfaceDisappeared()`).
- Never commit real battery serial numbers in fixtures.
