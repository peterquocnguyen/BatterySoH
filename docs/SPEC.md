# Battery Buddy — Product Spec

A lightweight, native macOS menu bar app that shows what the battery and the charger in
**this Mac** are doing right now, and how the battery ages over time.

Target: macOS 14+, Apple Silicon first (Intel best-effort). Swift + SwiftUI, Swift Package
Manager, no third-party dependencies, no helper tools, no root.

## Goals

- Answer at a glance: "how much charge, how fast is it moving, where does the power go?"
- Show long-term battery health (capacity vs design, cycles) with a monthly history.
- Stay tiny: < 1% CPU when idle, < 40 MB RAM, polling only while something is visible
  plus one cheap background sample for history.

## Non-goals (v1)

- iPhone/iPad batteries (needs private MobileDevice framework) — tracked as a later idea.
- Changing charging behaviour (charge limits, SMC writes). Read-only app.
- Cloud sync, accounts, analytics.

## Data sources

| Data | Source |
| --- | --- |
| Charge %, raw mAh, design/full capacity, cycles, voltage, amperage, charging flags | IORegistry `AppleSmartBattery` (`IORegistryEntryCreateCFProperties`) |
| Charger watts, voltage, current, USB-PD profile menu, active profile index | `AppleSmartBattery.AdapterDetails` (`UsbHvcMenu`, `UsbHvcHvcIndex`) |
| System load ("Mac uses N W"), power in from wall | `AppleSmartBattery.PowerTelemetryData` (`SystemLoad`, `SystemPowerIn`, `SystemVoltageIn`, `SystemCurrentIn`) — mW / mV / mA |
| Not-charging reason (e.g. optimized charging hold) | `AppleSmartBattery.ChargerData.NotChargingReason` (non-zero = on hold) |
| Time to empty / full | `IOPSCopyPowerSourcesInfo` (`kIOPSTimeToEmptyKey`, `kIOPSTimeToFullChargeKey`); fallback `AvgTimeToEmpty/Full` (65535 = unknown) |
| Live change notifications | `IOPSNotificationCreateRunLoopSource` + timer while UI visible |
| Battery temperature | `AppleSmartBattery.Temperature` (centi-°C) if present, else SMC keys `TB0T`/`TB1T`/`TB2T` via `AppleSMC` user client. **Never display 0 °C for "unknown" — show "—".** |
| Mac model name / identifier | IODeviceTree `product` `product-name`; `sysctl hw.model` |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` |

Derived values:

- `chargePercent` = `CurrentCapacity` (what macOS shows); `rawChargePercent` =
  `AppleRawCurrentCapacity / AppleRawMaxCapacity` (one decimal, used in menu bar title).
- `health` = `AppleRawMaxCapacity / DesignCapacity` (fallback `NominalChargeCapacity`).
- `batteryPowerW` = `Voltage(mV) × Amperage(mA) / 1e6`, signed: + charging, − discharging.
- `systemLoadW` = `PowerTelemetryData.SystemLoad / 1000`; fallback
  `adapterInW − batteryPowerW` on AC, `−batteryPowerW` on battery.
- Active PD profile = `UsbHvcMenu[UsbHvcHvcIndex]`.

## Features

### F1 — Menu bar item
- Battery glyph + text. Default format: `80% (4h 8m)` on battery, `80% ⚡︎` charging,
  `80%` on AC not charging.
- Settings: show/hide percent, show/hide time, show watts instead of time.
- Click opens the popover (F2). App has no Dock icon (`LSUIElement`).

**Accept:** title updates within 2 s of plugging/unplugging the charger.

### F2 — Popover: power flow (screenshot 1)
Header:
- `⚡ Charger connected` / `Charging on hold` / `On battery` + subtitle
  (`USB-C Power Delivery`, adapter description).
- Big number: watts into the battery (green) when charging, watts out of the battery
  (orange) when discharging, or system draw from the wall when on AC not charging.
- Battery glyph + `71 %` + `full in 58 min` / `4h 8m left` / `not charging`.

Flow diagram: `CHARGER (65 W)` → `MAC (uses 18 W)` → `BATTERY (71 %)`, with labels on
each arrow (`20 V · 3.25 A`, `+47.2 W / 3.77 A in`). Animated dots in the flow
direction; arrows reverse/hide when on battery (battery → Mac, charger node dimmed).

Tiles (2×2): Charger (W), Active profile (V · A), Battery (V · A), Temperature (°C).

PD profiles: chips for each `UsbHvcMenu` entry (`5V/3A` …), active one highlighted.
Hidden when no USB-PD adapter.

### F3 — Popover: battery summary (screenshot 2, right)
Compact rows under the flow: Battery Charge (bar + one-decimal %), Battery Health
(bar + %), Time until empty/full, Cycles, Temperature. Footer: settings gear,
"Open window" button, Quit.

### F4 — Window: This Mac (screenshot 2, middle)
- Header: laptop glyph, model name (`MacBook Pro`), detail
  (`14-inch, Nov 2024 · M4 Pro`), device identifier (`Mac16,8`).
- Battery Charge: current mAh + bar labelled with %.
- Battery Health: bar labelled with %.
- Rows: Full Charge Capacity (mAh), Design Capacity (mAh), Charge Cycles
  (`183 of 1000` using `DesignCycleCount9C` when present), Battery Temperature,
  Charging/Discharging with (W), Power Adapter (W + description), Low Power Mode,
  Battery serial and gauge (`DeviceName`) in a collapsible "Details" section.
- Manufacture date is shown only when the registry exposes it (not on Apple Silicon).

### F5 — Window: History (screenshot 2, left)
- The app records one sample per day (first launch, then on wake/timer):
  date, health %, cycles, full-charge mAh, design mAh.
- Stored as JSON at `~/Library/Application Support/BatteryBuddy/history.json`.
- Table grouped by month (`2025-11`): average health, max cycles.
- Small line chart (Swift Charts) of health % over time.
- Export CSV button.

### F6 — Settings
- Menu bar format options (F1), refresh interval while open (1/2/5 s),
  Launch at login (`SMAppService.mainApp`), temperature unit (°C/°F).
- Stored in `UserDefaults`.

### F7 — `bbstat` CLI (dev + power-user tool)
`swift run bbstat` prints the current snapshot as human text; `--json` prints JSON.
Used for debugging and as a fixture capture tool (`--raw` dumps the registry plist).

## Architecture

```
Sources/
  BatteryKit/     pure-Swift library: models, IOKit/SMC readers, parser, history, formatting
  BatteryBuddy/   SwiftUI app: MenuBarExtra(.window) + Window + Settings
  bbstat/         CLI over BatteryKit
Tests/BatteryKitTests/  Swift Testing; fixtures are real registry dumps (serial scrubbed)
scripts/bundle.sh       builds release + wraps into build/Battery Buddy.app (ad-hoc signed)
```

Rules:
- Parsing is pure (`BatteryParser.parse([String: Any]) -> BatterySnapshot`) so it is
  tested with fixtures; readers only fetch dictionaries.
- Every optional hardware value is `Optional` in the model; views render `—` for `nil`.
- UI polls only while popover/window is visible; background = IOPS notifications +
  one history sample per day.

## Milestones
1. M1 Core: BatteryKit models/parser/readers + bbstat + tests.
2. M2 Popover: F1, F2, F3.
3. M3 Window: F4, F5, F6.
4. M4 Ship: bundle script, app icon, README, launch-at-login, v0.1.0 tag.
