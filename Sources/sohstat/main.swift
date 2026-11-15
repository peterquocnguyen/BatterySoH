import BatteryKit
import Foundation

// sohstat — print the current battery snapshot.
//   sohstat          human-readable
//   sohstat --json   JSON snapshot
//   sohstat --raw    raw AppleSmartBattery registry as XML plist (fixture capture)
//   sohstat --devices          other devices: accessories + iPhone/iPad (add --json for JSON);
//                             a disconnected iPhone/iPad shows the app's last exact reading
//   sohstat --devices --raw    raw accessory power source descriptions as XML plist

let args = Set(CommandLine.arguments.dropFirst())

if args.contains("--help") || args.contains("-h") {
    print("usage: sohstat [--json | --raw | --smc | --devices [--json | --raw] [--wait seconds]]")
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
    // `--wait N` (seconds): Wi-Fi-synced devices can take longer than cabled ones to attach.
    let argv = CommandLine.arguments
    let wait = argv.firstIndex(of: "--wait").flatMap { i in i + 1 < argv.count ? Double(argv[i + 1]) : nil } ?? 4
    RunLoop.main.run(until: Date().addingTimeInterval(monitor == nil && hotspot == nil ? 0 : wait))
    hotspot?.stop()
    // The app's last exact reading per iPhone / iPad (read only; the app owns the file).
    let remembered = LastExactReadingStore().devices
    let devices = HotspotParser.merge(connected: mobile, remembered: remembered, nearby: nearby)
        + AccessoryPowerSources.read()
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try enc.encode(devices))
        print()
        exit(0)
    }
    if monitor == nil { print("(MobileDevice.framework unavailable: cabled iPhone/iPad not scanned)") }
    if hotspot == nil { print("(Sharing.framework hotspot browser unavailable: nearby iPhone/iPad not scanned)") }
    if devices.isEmpty { print("No other devices found.") }
    for d in devices {
        let charge = d.percent.map { d.isApproximate ? "≈\($0)% (hotspot, may lag)" : "\($0)%" } ?? Fmt.dash
        let state = d.isCharging ? " charging" : (d.externalConnected ? " on power" : "")
        let via = d.connection.map { " · \($0.rawValue)" } ?? ""
        var status = ""
        if d.isLastKnown { status += " · not connected (last exact reading)" }
        if d.isIOSDevice, !d.isApproximate, let updated = d.updatedAt {
            status += " · updated \(Fmt.freshness(updated, now: Date()))"
        }
        print("\(d.name) [\(d.kind.rawValue)\(via)] \(charge)\(state)\(status)")
        for part in d.parts {
            print("    \(part.name): \(part.percent.map { "\($0)%" } ?? Fmt.dash)\(part.isCharging ? " charging" : "")")
        }
        if d.designCapacityMAh != nil || d.cycleCount != nil {
            print("    health \(Fmt.percent(d.healthPercent, decimals: 1)) (\(Fmt.mAh(d.fullChargeCapacityMAh)) of \(Fmt.mAh(d.designCapacityMAh))), cycles \(d.cycleCount.map(String.init) ?? Fmt.dash), \(Fmt.temperature(d.temperatureC))")
        }
        if let c = BatteryCondition.device(d) {
            var line = "    condition \(c.cliText)"
            if let peak = c.peakPerformance { line += ", peak performance \(peak.cliText)" }
            if let rated = BatteryCondition.ratedCycles(kind: d.kind, model: d.model) { line += ", rated \(rated) cycles" }
            print(line)
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
row("Condition", BatteryCondition.mac(s, reported: MacReportedHealth.read())?.cliText ?? Fmt.dash)
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

// F8 controls (read-only here).
let currentSource: PowerSourceKind = s.externalConnected ? .ac : .battery
if let energy = EnergyModeControl.read() {
    let perSource = PowerSourceKind.allCases.map { source -> String in
        let mode = energy.modes[source]?.title ?? Fmt.dash
        return "\(source.title): \(mode)\(source == currentSource ? " (now)" : "")"
    }
    row("Energy mode", perSource.joined(separator: " · "))
    row("Energy modes offered", energy.supportedModes(for: currentSource).map(\.title).joined(separator: ", ")
        + " (\(currentSource.title.lowercased()))")
} else {
    row("Energy mode", "unavailable (no powermode in pmset)")
}
if let limit = ChargeLimit.shared.status() {
    var parts = [limit.isEnabled ? "on" : "off"]
    parts.append(limit.limitPercent.map { "\($0)%" } ?? "limit \(Fmt.dash)")
    parts.append(limit.isHoldingCharge ? "holding charge" : "not holding")
    parts.append(limit.overrideAllowed ? "override allowed" : "no override")
    row("Charge limit", parts.joined(separator: " · "))
} else {
    row("Charge limit", "unavailable (PowerUI)")
}
row("Gauge / serial", "\(s.gaugeName ?? Fmt.dash) / \(s.serial ?? Fmt.dash)")


extension BatteryCondition {
    /// "Normal (macOS, max capacity 91%)", "Service Recommended (estimated, max capacity 74%)".
    var cliText: String {
        let state = needsService ? "Service Recommended" : "Normal"
        var detail = [source == .macOS ? "macOS" : "estimated"]
        if let m = maximumCapacityPercent { detail.append("max capacity \(m)%") }
        if permanentFailure { detail.append("permanent failure") }
        return "\(state) (\(detail.joined(separator: ", ")))"
    }
}

extension BatteryCondition.PeakPerformance {
    var cliText: String {
        switch self {
        case .normal: return "normal"
        case .unexpectedShutdown: return "may be limited (unexpected shutdown recorded)"
        case .worn: return "may be limited (worn battery)"
        }
    }
}
