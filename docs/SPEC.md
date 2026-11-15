# BatterySoH — Product Spec

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
- Per-app battery use for iPhone / iPad (it never leaves the device).
- Daily usage / charge-level logs (an Insights tab existed briefly and was removed) and health
  history for other devices.
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
| iPhone / iPad charge without a cable | Private `Sharing.framework` (`dlopen`): `SFRemoteHotspotSession` browse, delegate `session:updatedFoundDevices:` → `SFRemoteHotspotDevice` `deviceName` (advert-truncated to ~12 UTF-8 bytes), `model`, `batteryLife`. Same Apple Account, Personal Hotspot capable. No charging state, no health. **Approximate**: the advertised level can lag the phone by hours (observed 75 % while the phone showed 91 % and charging) |
| iPhone / iPad capacity, cycles, temperature | `com.apple.mobile.diagnostics_relay` `IORegistry` request for `IOPMPowerSource` (trusted devices only) |
| Mac battery condition (Normal / Service Recommended), Apple's maximum capacity | `system_profiler SPPowerDataType -json` (`sppower_battery_health`, `sppower_battery_health_maximum_capacity`) — IOKit hides these from unentitled apps. Run in the background at launch and at most every 3 h |
| Permanent battery failure | `AppleSmartBattery.PermanentFailureStatus` (non-zero = failure) |
| iPhone / iPad maximum capacity, unexpected-shutdown record | diagnostics relay `IOPMPowerSource`: `NominalChargeCapacity` vs `DesignCapacity`; `BatteryShutdownReason` (`ShutDownTimestamp`, `ShutDownUpoReboot`, both 0 = none) |
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

### Window layout (F4, F5, F10)
Device first: every device appears once. A `NavigationSplitView` with
- **Sidebar** (~200 pt, 180–280): one row per device — This Mac first (no header), then
  "iPhone & iPad", then "Accessories" (empty sections hidden). Row: device glyph, name, percent
  on the right (green bolt when charging; `≈ 75%` for a hotspot level; the whole row at 0.55
  opacity for a not-connected or hotspot-only iPhone / iPad). Native source list (Liquid Glass on
  macOS 26+). While no iPhone / iPad is listed, the sidebar foot says how they show up.
- **Detail** (~460 pt, min 420): the selected device's page, in a ScrollView.
- **Selection** persists in `UserDefaults` (`window.selectedDevice`: `this-mac` or the device
  id). A stored device that isn't listed shows This Mac (the id is kept, so a device found a few
  seconds after launch is selected again). When the selected device leaves the list while the
  window is open: the entry that replaced it (same kind and model, new id — e.g. a hotspot-only
  iPhone now read over Wi-Fi sync), else This Mac.
- Window resizable between 600 × 480 and 1000 pt wide; SwiftUI remembers the frame. No toolbar
  tabs. About lives in Settings (F9).

### F4 — Window: This Mac page (screenshot 2, middle)
- Header: laptop glyph, model name (`MacBook Pro`), detail
  (`14-inch, Nov 2024 · M4 Pro`), device identifier (`Mac16,8`).
- Battery Charge: current mAh + bar labelled with %.
- Battery Health: bar labelled with %.
- Rows: Full Charge Capacity (mAh), Design Capacity (mAh), Charge Cycles
  (`183 of 1000` using `DesignCycleCount9C` when present), Battery Temperature,
  Charging/Discharging with (W), Power Adapter (W + description), Low Power Mode,
  Battery serial and gauge (`DeviceName`) in a collapsible "Details" section.
- Manufacture date is shown only when the registry exposes it (not on Apple Silicon).

### F5 — Window: History (This Mac page, below F4)
- The app records one sample per day (first launch, then on wake/timer):
  date, health %, cycles, full-charge mAh, design mAh.
- Stored as JSON at `~/Library/Application Support/BatterySoH/history.json`.
- "History" section on the This Mac page, under Details: Battery Health card (sample count,
  since, current health; Swift Charts line of health % over time), then a "Monthly Averages"
  disclosure, collapsed by default (state in `window.thisMac.historyTableExpanded`), that shows a
  table grouped by month (`2025-11`): average health, max cycles. Export CSV button next to the section title. Empty
  state: "No history yet". Not shown on a Mac without a battery.

### F6 — Settings
- `TabView`: **General** (everything below) and **About** (F9); both 440 pt wide, the window
  sizes to the tab.
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
Settings › About tab: app icon, name, version (build), author **Peter Quoc**, copyright,
one-line description, privacy statement (no network, no data collection), credits for
data sources, "Copy Diagnostics" (sohstat-style text for bug reports).

### F10 — Window: other devices (one sidebar row and page each)
Batteries of other devices this Mac can see.
- **iPhone & iPad** pages: devices on USB, or on Wi-Fi with "Show this iPhone when on
  Wi-Fi" on. Header like This Mac's: device glyph, name, `iOS 26.1 · USB`, model identifier
  capsule (`iPhone18,1`). Battery Charge card: charge bar, then "Charging · Updated 3 min ago" /
  "Updated 3 min ago". Trusted devices add a rows card: Battery Health (full/design), Full Charge
  Capacity, Design Capacity, Charge Cycles, Temperature. Untrusted: no bar, just
  "Unlock iPhone and tap Trust to see its battery." Never initiates pairing itself. Every
  iPhone / iPad page ends with the footnotes: how iPhone / iPad show up (cable, Wi-Fi sync,
  trust, last reading), what a Personal Hotspot level is, and that Apple Watch battery is not
  available on a Mac.
- **Freshness**: every iPhone / iPad page says how current its number is
  (`DeviceBattery.updatedAt`: when the exact read was taken; for a hotspot level, when this app
  first saw the current value). Exact pages: "Updated just now" (< 1 min), "Updated 3 min ago"
  (< 1 h), then the time ("Updated 12:40"), then the date ("Updated 14 Nov") — `Fmt.freshness`.
  Redrawn at least every 30 s while visible (`TimelineView(.periodic)`). Accessories: none.
- **Not connected** (last exact reading): when a cabled / Wi-Fi-synced device disconnects
  (phone asleep, off the network), its last exact reading stays (`DeviceBattery.isLastKnown`,
  `LastExactReadingStore`: one JSON file
  `~/Library/Application Support/BatterySoH/last-exact-readings.json`, written atomically when
  the reading changes, at most every 5 min otherwise, on disconnect and on quit; survives
  relaunch). The page is faded (0.55 opacity on its values), grey bar, no charging bolt, no
  connection in the subtitle, caption "Last updated 12:40 · not connected" (relative when
  recent, the date when not today). Health / cycles rows stay, also faded. A hotspot level for
  the same phone is not shown.
- **Nearby** (no cable, never read exactly): iPhone / cellular iPad on the same Apple Account,
  through Instant Hotspot — name (marked `…` when the advert may have cut it: ≥ 12 UTF-8 bytes,
  unless it is exactly 12 bytes and equals a known exact device name), model and the level the
  device last advertised. That level is **approximate** (`DeviceBattery.isApproximate`): it can
  lag well behind the phone and carries no charging state. The page is faded like a
  not-connected one, with a "Not live" capsule badge next to the name, `≈ 75%`, a grey bar, no
  bolt, "since 12:03" (`DeviceBattery.updatedAt`) next to "Battery Charge", and the note "Last level the iPhone shared
  over Personal Hotspot. It can lag well behind the phone."
- **Setup card** on every nearby-only iPhone / iPad page, at full strength as the page's primary
  element (accent-tinted, filled button): "For the live level, charging state, health
  and cycles: connect the iPhone by cable once, unlock it and tap Trust, then in Finder select
  it and turn on ‘Show this iPhone when on Wi-Fi’. After that BatterySoH reads it wirelessly
  whenever both are on the same Wi-Fi." plus an **Open Finder** button.
- Precedence (`HotspotParser.merge(connected:remembered:nearby:knownNames:)`): exact connected
  read > last exact reading of a disconnected device > hotspot level. A nearby entry is dropped
  when a connected or remembered device has the same model and a name that starts with the
  advertised name stem. Browsing runs while a
  surface is visible and is restarted (stop + start) every ~60 s in case the phone
  re-advertises; an empty result within 15 s of a restart is ignored.
- **Accessories**: one page per accessory (glyph, name, `Bluetooth`, Battery Charge card with
  one bar, or Left / Right / Case bars for AirPods-style groups; sidebar percent = lowest bud).
- Refresh: accessories on every UI tick (cheap IOPS read); iPhone/iPad on attach and at most
  once a minute while a surface is visible. MobileDevice loads on first visible surface.
- Private-API use is isolated: MobileDevice in `MobileDevices.swift`, Sharing in
  `NearbyDevices.swift`; every symbol optional.

**Accept:** a connected Bluetooth mouse shows the same percent as `pmset -g accps`; an
iPhone on the same Apple Account shows the percent the Wi-Fi menu shows for its hotspot,
marked approximate (`sohstat --devices`: `≈75% (hotspot, may lag)`). `sohstat --devices` adds
`· updated just now` to exact iPhone / iPad lines and `· not connected (last exact reading)` to a
remembered one (it reads the app's last-exact file, never writes it).

### F11 — Battery condition (service and peak performance)
When a battery needs service, for This Mac and every exactly-read iPhone / iPad
(`BatteryCondition`).
- **Status**: Normal / Service Recommended. Service when maximum capacity is below 80 % (Apple's
  service level) or a permanent failure is reported.
- **Maximum capacity** = `NominalChargeCapacity / DesignCapacity`, rounded down (falls back to
  full-charge capacity) — what Settings shows (this Mac: 5,744 of 6,249 mAh → 91 %, same as
  System Information).
- **Mac**: macOS's own verdict when `system_profiler` gives one (`Good` → Normal, anything else
  → Service Recommended; its maximum capacity is used as is). Caption "as macOS reports them".
  Without it: estimated from capacity, captioned so.
- **iPhone / iPad**: always an estimate — iOS doesn't share its Battery Health verdict with a
  Mac. Caption says so and points to Settings › Battery › Battery Health.
- **Peak performance** (iPhone only; Mac and iPad don't manage performance for battery wear):
  Normal; May Be Limited after a recorded unexpected shutdown (`unexpectedShutdown`); May Be
  Limited with a worn battery (`worn`, wins over the shutdown record).
- **Rated cycles**: Mac from the gauge (`DesignCycleCount9C`); iPhone 15 and later 1000, earlier
  iPhone 500, iPad 1000 (Apple's published figures). Device pages show "746 of 500".
- UI: a "Battery Condition" card (status capsule, one-line summary with points above the
  service level, rows Maximum Capacity / Service Level / Peak Performance, source caption) on the
  This Mac page under the charge/health card and on iPhone / iPad pages under Battery Charge
  (faded for a last-known reading; none for hotspot levels, untrusted devices, accessories).
  Popover summary: a "Condition" row, orange when service is recommended.
- `sohstat` prints `Condition` for the Mac and a `condition …, peak performance …, rated N
  cycles` line per device; Copy Diagnostics adds `Condition`.

### F7 — `sohstat` CLI (dev + power-user tool)
`swift run sohstat` prints the current snapshot as human text; `--json` prints JSON.
`--devices` lists other devices (F10), `--devices --json` as JSON, `--devices --raw` dumps
the accessory power source dictionaries (fixture capture).
Used for debugging and as a fixture capture tool (`--raw` dumps the registry plist).

## Architecture

```
Sources/
  BatteryKit/     pure-Swift library: models, IOKit/SMC readers, parser, history, formatting
  BatterySoH/   SwiftUI app: MenuBarExtra(.window) + Window + Settings
  sohstat/         CLI over BatteryKit
Tests/BatteryKitTests/  Swift Testing; fixtures are real registry dumps (serial scrubbed)
scripts/bundle.sh       builds release + wraps into build/BatterySoH.app (ad-hoc signed)
```

Rules:
- Parsing is pure (`BatteryParser.parse([String: Any]) -> BatterySnapshot`) so it is
  tested with fixtures; readers only fetch dictionaries.
- Every optional hardware value is `Optional` in the model; views render `—` for `nil`.
- UI polls only while popover/window is visible; background = IOPS notifications +
  a 5-minute timer (menu bar title, one history sample per day).

## Milestones
1. M1 Core: BatteryKit models/parser/readers + sohstat + tests.
2. M2 Popover: F1, F2, F3.
3. M3 Window: F4, F5, F6 (device-first split view since 0.1.x; F10 pages in the same window).
4. M4 Ship: bundle script, app icon, README, launch-at-login, v0.1.0 tag.
