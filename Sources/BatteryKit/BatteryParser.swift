import Foundation

/// Pure conversion from an `AppleSmartBattery` registry dictionary to a `BatterySnapshot`.
/// No IOKit here, so it is unit-tested with real registry dumps.
public enum BatteryParser {
    /// Registry "unknown" sentinel for time values.
    static let unknownTime = 65535

    public static func parse(_ dict: [String: Any], now: Date = Date()) -> BatterySnapshot {
        let battery = dict["BatteryData"] as? [String: Any] ?? [:]
        let telemetry = dict["PowerTelemetryData"] as? [String: Any] ?? [:]
        let charger = dict["ChargerData"] as? [String: Any] ?? [:]

        let rawCurrent = int(dict["AppleRawCurrentCapacity"]) ?? int(battery["AppleRawCurrentCapacity"])
        let rawMax = int(dict["AppleRawMaxCapacity"]) ?? int(battery["AppleRawMaxCapacity"])
        let fullCharge = int(battery["FullChargeCapacity"]) ?? rawMax
        let percent = int(dict["CurrentCapacity"]) ?? int(battery["CurrentCapacity"]) ?? 0

        var rawPercent: Double?
        if let c = rawCurrent, let m = rawMax, m > 0 {
            rawPercent = (Double(c) / Double(m) * 1000).rounded() / 10
        }

        let isCharging = bool(dict["IsCharging"]) ?? false
        let externalConnected = bool(dict["ExternalConnected"]) ?? bool(dict["AppleRawExternalConnected"]) ?? false

        return BatterySnapshot(
            timestamp: now,
            chargePercent: percent,
            rawChargePercent: rawPercent,
            currentCapacityMAh: rawCurrent ?? int(battery["RemainingCapacity"]),
            fullChargeCapacityMAh: fullCharge,
            nominalChargeCapacityMAh: int(dict["NominalChargeCapacity"]) ?? int(battery["NominalChargeCapacity"]),
            designCapacityMAh: int(dict["DesignCapacity"]) ?? int(battery["DesignCapacity"]),
            cycleCount: int(dict["CycleCount"]),
            designCycleCount: positive(int(dict["DesignCycleCount9C"]) ?? int(dict["DesignCycleCount70"])),
            voltageMV: positive(int(dict["Voltage"]) ?? int(dict["AppleRawBatteryVoltage"])),
            amperageMA: int(dict["Amperage"]) ?? int(dict["InstantAmperage"]),
            temperatureC: temperature(dict),
            isCharging: isCharging,
            externalConnected: externalConnected,
            fullyCharged: bool(dict["FullyCharged"]) ?? false,
            notChargingReason: int(charger["NotChargingReason"]),
            minutesToEmpty: time(dict["AvgTimeToEmpty"])
                ?? time(dict["TimeRemaining"]).flatMap { isCharging || externalConnected ? nil : $0 },
            minutesToFull: time(dict["AvgTimeToFull"]),
            adapter: externalConnected ? adapter(dict["AdapterDetails"]) : nil,
            systemLoadW: milliToUnit(int(telemetry["SystemLoad"])),
            systemPowerInW: milliToUnit(int(telemetry["SystemPowerIn"])),
            serial: string(dict["Serial"]) ?? string(dict["BatterySerialNumber"]),
            gaugeName: string(dict["DeviceName"]),
            manufactureDate: manufactureDate(dict["ManufactureDate"]),
            permanentFailureStatus: int(dict["PermanentFailureStatus"])
        )
    }

    // MARK: - Pieces

    static func adapter(_ value: Any?) -> PowerAdapter? {
        guard let d = value as? [String: Any], !d.isEmpty else { return nil }
        let menu = (d["UsbHvcMenu"] as? [[String: Any]] ?? []).enumerated().compactMap { offset, p -> PDProfile? in
            guard let v = int(p["MaxVoltage"]), let a = int(p["MaxCurrent"]) else { return nil }
            return PDProfile(index: int(p["Index"]) ?? offset, voltageMV: v, currentMA: a)
        }
        let watts = positive(int(d["Watts"]))
        // Registry reports an "AdapterDetails" dict with zero watts when nothing is plugged in.
        if watts == nil && menu.isEmpty && d["Description"] == nil { return nil }
        return PowerAdapter(
            watts: watts,
            voltageMV: positive(int(d["AdapterVoltage"])),
            currentMA: positive(int(d["Current"])),
            description: string(d["Description"]),
            isWireless: bool(d["IsWireless"]) ?? false,
            profiles: menu,
            activeProfileIndex: menu.isEmpty ? nil : int(d["UsbHvcHvcIndex"])
        )
    }

    /// `Temperature` / `VirtualTemperature` are centi-degrees Celsius. 0 means "not reported".
    static func temperature(_ dict: [String: Any]) -> Double? {
        for key in ["Temperature", "VirtualTemperature"] {
            if let t = int(dict[key]), t > 0 { return Double(t) / 100 }
        }
        return nil
    }

    /// Smart Battery spec date: day | month << 5 | (year - 1980) << 9.
    static func manufactureDate(_ value: Any?) -> Date? {
        guard let raw = int(value), raw > 0 else { return nil }
        let day = raw & 0x1F
        let month = (raw >> 5) & 0x0F
        let year = 1980 + ((raw >> 9) & 0x7F)
        guard (1...31).contains(day), (1...12).contains(month), year >= 2000 else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    static func time(_ value: Any?) -> Int? {
        guard let m = int(value), m > 0, m != unknownTime else { return nil }
        return m
    }

    static func milliToUnit(_ v: Int?) -> Double? {
        guard let v, v > 0 else { return nil }
        return Double(v) / 1000
    }

    static func positive(_ v: Int?) -> Int? {
        guard let v, v > 0 else { return nil }
        return v
    }

    // MARK: - Loose typing helpers

    /// Registry values can arrive as Int, Int64 or as unsigned two's-complement (negative amperage
    /// dumped as 18446744073709551xxx). `int64Value` reinterprets those back to negatives.
    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 1 : 0 }
            return Int(truncatingIfNeeded: n.int64Value)
        case let i as Int: return i
        case let u as UInt64: return Int(truncatingIfNeeded: u)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["yes", "true", "1"].contains(s.lowercased())
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }
}
