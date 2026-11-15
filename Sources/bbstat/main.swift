import BatteryKit
import Foundation

// bbstat — print the current battery snapshot.
//   bbstat          human-readable
//   bbstat --json   JSON snapshot
//   bbstat --raw    raw AppleSmartBattery registry as XML plist (fixture capture)

let args = Set(CommandLine.arguments.dropFirst())

if args.contains("--help") || args.contains("-h") {
    print("usage: bbstat [--json | --raw]")
    exit(0)
}

if args.contains("--smc") {
    guard let smc = SMC() else { print("AppleSMC: cannot open"); exit(1) }
    for key in ["TB0T", "TB1T", "TB2T", "TB3T", "TC0P", "PSTR"] {
        print(key, smc.readDouble(key).map { String(format: "%.2f", $0) } ?? "—")
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
