import BatteryKit
import Foundation

// bbstat — print the current battery snapshot.
//   bbstat          human-readable
//   bbstat --json   JSON snapshot
//   bbstat --raw    raw AppleSmartBattery registry as XML plist (fixture capture)
//   bbstat --devices          other devices: accessories + iPhone/iPad (add --json for JSON)
//   bbstat --devices --raw    raw accessory power source descriptions as XML plist

let args = Set(CommandLine.arguments.dropFirst())

if args.contains("--help") || args.contains("-h") {
    print("usage: bbstat [--json | --raw | --smc | --devices [--json | --raw]]")
    exit(0)
}

if args.contains("--smc") {
    guard let smc = SMC() else { print("AppleSMC: cannot open"); exit(1) }
    for key in ["TB0T", "TB1T", "TB2T", "TB3T", "TC0P", "PSTR"] {
        print(key, smc.readDouble(key).map { String(format: "%.2f", $0) } ?? "—")
    }
    exit(0)
}

if args.contains("--devices") {
    if args.contains("--raw") {
        let data = try PropertyListSerialization.data(
            fromPropertyList: AccessoryPowerSources.readDescriptions(), format: .xml, options: 0)
        FileHandle.standardOutput.write(data)
        exit(0)
    }
    // iPhone/iPad attach notifications and reads are asynchronous; give them a few seconds.
    var mobile: [DeviceBattery] = []
    var nearby: [DeviceBattery] = []
    let monitor = MobileDeviceMonitor { mobile = $0 }
    let hotspot = NearbyHotspotBrowser { nearby = $0 }
    monitor?.start()
    hotspot?.start()
    RunLoop.main.run(until: Date().addingTimeInterval(monitor == nil && hotspot == nil ? 0 : 4))
    hotspot?.stop()
    let devices = HotspotParser.merge(cabled: mobile, nearby: nearby) + AccessoryPowerSources.read()
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try enc.encode(devices))
        print()
        exit(0)
    }
    if monitor == nil { print("(MobileDevice.framework unavailable: cabled iPhone/iPad not scanned)") }
    if hotspot == nil { print("(Sharing.framework hotspot browser unavailable: nearby iPhone/iPad not scanned)") }
    if devices.isEmpty { print("No other devices found.") }
    for d in devices {
        let charge = d.percent.map { "\($0)%" } ?? Fmt.dash
        let state = d.isCharging ? " charging" : (d.externalConnected ? " on power" : "")
        let via = d.connection.map { " · \($0.rawValue)" } ?? ""
        print("\(d.name) [\(d.kind.rawValue)\(via)] \(charge)\(state)")
        for part in d.parts {
            print("    \(part.name): \(part.percent.map { "\($0)%" } ?? Fmt.dash)\(part.isCharging ? " charging" : "")")
        }
        if d.designCapacityMAh != nil || d.cycleCount != nil {
            print("    health \(Fmt.percent(d.healthPercent, decimals: 1)) (\(Fmt.mAh(d.fullChargeCapacityMAh)) of \(Fmt.mAh(d.designCapacityMAh))), cycles \(d.cycleCount.map(String.init) ?? Fmt.dash), \(Fmt.temperature(d.temperatureC))")
        }
        if let note = d.note { print("    \(note)") }
    }
    exit(0)
}

if args.contains("--raw") {
    guard let dict = SmartBatteryRegistry.read() else {
        FileHandle.standardError.write("No AppleSmartBattery found (desktop Mac?)\n".data(using: .utf8)!)
        exit(1)
    }
    // Drop non-plist values (IOKit objects) before serializing.
    let clean = dict.filter { PropertyListSerialization.propertyList($0.value, isValidFor: .xml) }
    let data = try PropertyListSerialization.data(fromPropertyList: clean, format: .xml, options: 0)
    FileHandle.standardOutput.write(data)
    exit(0)
}

guard let s = BatteryReader().snapshot() else {
    FileHandle.standardError.write("No battery found (desktop Mac?)\n".data(using: .utf8)!)
    exit(1)
}

if args.contains("--json") {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try enc.encode(s))
    print()
    exit(0)
}

let mac = MacInfo.current()
func row(_ k: String, _ v: String) { print(k.padding(toLength: 24, withPad: " ", startingAt: 0) + v) }

print("\(mac.name)\(mac.detail.map { " (\($0))" } ?? "") · \(mac.chip ?? "?") · \(mac.identifier)")
print(String(repeating: "─", count: 52))
row("State", "\(s.statusTitle) — \(s.timeSummary)")
row("Charge", "\(s.chargePercent)% (\(Fmt.percent(s.rawChargePercent, decimals: 1)) raw, \(Fmt.mAh(s.currentCapacityMAh)))")
row("Health", "\(Fmt.percent(s.healthPercent, decimals: 1)) (\(Fmt.mAh(s.fullChargeCapacityMAh)) of \(Fmt.mAh(s.designCapacityMAh)))")
row("Cycles", "\(s.cycleCount.map(String.init) ?? Fmt.dash)\(s.designCycleCount.map { " of \($0)" } ?? "")")
row("Battery", "\(Fmt.volts(mV: s.voltageMV)) · \(Fmt.amps(mA: s.amperageMA)) · \(Fmt.watts(s.batteryPowerW, signed: true))")
row("Temperature", Fmt.temperature(s.temperatureC))
row("Mac uses", Fmt.watts(s.macLoadW))
row("Power in", Fmt.watts(s.systemPowerInW))
if let a = s.adapter {
    row("Charger", "\(a.watts.map { "\($0) W" } ?? Fmt.dash) \(a.displayKind) (\(a.description ?? "?"))")
    if let p = a.activeProfile { row("Active profile", "\(Fmt.volts(mV: p.voltageMV)) · \(Fmt.amps(mA: p.currentMA))") }
    if !a.profiles.isEmpty { row("PD profiles", a.profiles.map(Fmt.profile).joined(separator: "  ")) }
} else {
    row("Charger", "not connected")
}
if s.isChargeOnHold { row("Not charging reason", String(format: "0x%08X", s.notChargingReason ?? 0)) }
row("Gauge / serial", "\(s.gaugeName ?? Fmt.dash) / \(s.serial ?? Fmt.dash)")
