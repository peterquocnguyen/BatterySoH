# Battery Buddy — Product Spec

A lightweight, native macOS menu bar app that shows what the battery and the charger in
**this Mac** are doing right now, how the battery ages over time, and the batteries of the
devices around it (iPhone, iPad, AirPods and other accessories).

Target: macOS 14+, Apple Silicon first (Intel best-effort). Swift + SwiftUI, Swift Package
Manager, no third-party dependencies, no helper tools, no root.

## Goals

- Answer at a glance: "how much charge, how fast is it moving, where does the power go?"
- Show long-term battery health (capacity vs design, cycles) with a monthly history.
- Stay tiny: ~0% CPU when idle, < 100 MB RSS (measured v0.1: 0.0% CPU, 80 MB), polling only while something is visible
  plus one cheap background sample for history.

## Non-goals (v1)

- Apple Watch battery: watchOS shares it only with the paired iPhone; a Mac has no path to it.
- History for other devices (F10 shows live values only).
- Writing SMC keys or implementing our own charge limiter. The only controls are the
  ones macOS itself offers in its Battery menu (F8), driven through macOS's own interfaces.
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
| Accessory batteries (AirPods parts, Magic Mouse/Keyboard/Trackpad, controllers, BT HID) | `IOPSCopyPowerSourcesByType(4)` (IOKit export, private header; `dlsym`) — same list as `pmset -g accps` |
| iPhone / iPad charge, charging | Private `MobileDevice.framework` (`dlopen`): `AMDeviceNotificationSubscribe…`, lockdown domain `com.apple.mobile.battery` |
| iPhone / iPad charge without a cable | Private `Sharing.framework` (`dlopen`): `SFRemoteHotspotSession` browse, delegate `session:updatedFoundDevices:` → `SFRemoteHotspotDevice` `deviceName` (advert-truncated to ~12 UTF-8 bytes), `model`, `batteryLife`. Same Apple Account, Personal Hotspot capable. No charging state, no health |
| iPhone / iPad capacity, cycles, temperature | `com.apple.mobile.diagnostics_relay` `IORegistry` request for `IOPMPowerSource` (trusted devices only) |
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

### F8 — Battery controls (mirror the native Battery menu)
- **Energy Mode**: Automatic / Low Power / High Power, for the current power source.
  Read: `pmset -g custom` (`powermode` 0/1/2 per "Battery Power"/"AC Power" section);
  capabilities from `pmset -g cap` (`lowpowermode`, `highpowermode`; hide High Power when
  absent). Write: `/usr/bin/pmset -b|-c powermode N` via an admin authorization prompt
  (`NSAppleScript` `do shell script … with administrator privileges`). Later: privileged
  helper (`SMAppService.daemon`) to avoid repeated prompts.
- **Charge limit status**: "Charged to 80% Limit" when macOS's Manual Charge Limit holds the
  charge. Read through PowerUI's `PowerUISmartChargeClient` (`isMCLCurrentlyEnabled:`,
  `getMCLLimitWithError:`, `isOBCEngaged:isMaxChargeLimited:chargingOverrideAllowed:withError:`),
  loaded at runtime with `dlopen` + ObjC runtime; every call optional and failure-tolerant.
- **Charge to Full Now**: shown on AC when the limit holds the charge and override is
  allowed; calls `temporarilyDisableMCL:` (same as the native menu item).
- Private-API use is isolated in one file so it can be dropped if macOS changes it.

### F9 — About
Tab in the main window: app icon, name, version (build), author **Peter Ng**, copyright,
one-line description, privacy statement (no network, no data collection), credits for
data sources, "Copy Diagnostics" (bbstat-style text for bug reports).

### F10 — Window: Devices
Tab between "This Mac" and "History": batteries of other devices this Mac can see.
- **iPhone & iPad** section: devices on USB, or on Wi-Fi with "Show this iPhone when on
  Wi-Fi" on. Card: device glyph, name, `iOS 26.1 · USB · iPhone18,1`, big percent (bolt when
  charging), charge bar. Trusted devices add rows: Battery Health (full/design), Full Charge
  Capacity, Design Capacity, Charge Cycles, Temperature. Untrusted: name/model only plus
  "Unlock iPhone and tap Trust to see its battery." Never initiates pairing itself.
- **Nearby** (no cable): iPhone / cellular iPad on the same Apple Account, through Instant
  Hotspot — name (marked `…` when the advert cut it), model, charge %, note "Charge only.
  Connect by cable for health and cycles." Dropped when the same device is also read by
  cable (same model, cabled name starts with the advertised name). Browses only while a
  surface is visible.
- **Accessories** section: one card per accessory; AirPods-style groups show Left / Right /
  Case bars, headline percent = lowest bud.
- Empty state when nothing is found; footnote explains the Wi-Fi/trust requirement and that
  Apple Watch battery is not available on a Mac.
- Refresh: accessories on every UI tick (cheap IOPS read); iPhone/iPad on attach and at most
  once a minute while a surface is visible. MobileDevice loads on first visible surface.
- Private-API use is isolated: MobileDevice in `MobileDevices.swift`, Sharing in
  `NearbyDevices.swift`; every symbol optional.

**Accept:** a connected Bluetooth mouse shows the same percent as `pmset -g accps`; an
iPhone on the same Apple Account shows the percent the Wi-Fi menu shows for its hotspot.

### F7 — `bbstat` CLI (dev + power-user tool)
`swift run bbstat` prints the current snapshot as human text; `--json` prints JSON.
`--devices` lists other devices (F10), `--devices --json` as JSON, `--devices --raw` dumps
the accessory power source dictionaries (fixture capture).
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
