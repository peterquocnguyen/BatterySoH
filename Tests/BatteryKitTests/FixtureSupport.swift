import Foundation
@testable import BatteryKit

/// Loads registry dumps from `Fixtures/` and builds derived variants in code.
enum Fixture {
    /// Real `AppleSmartBattery` dump: MacBook Pro on a 65 W USB-C PD charger, charge held at 80 %.
    static func acNotCharging() throws -> [String: Any] {
        try load("ac-not-charging")
    }

    static func load(_ name: String) throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "plist", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        let data = try Data(contentsOf: url)
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw FixtureError.notADictionary(name)
        }
        return dict
    }

    /// The fixture, plugged in and actively charging at +3.77 A, 58 min to full.
    static func charging() throws -> [String: Any] {
        var d = try acNotCharging()
        d["IsCharging"] = true
        d["Amperage"] = 3770
        d["InstantAmperage"] = 3770
        d["AvgTimeToFull"] = 58
        d["ChargerData"] = setting(d["ChargerData"], "NotChargingReason", to: 0)
        return d
    }

    /// The fixture, unplugged, discharging. Amperage is the registry's unsigned two's-complement
    /// encoding of −1000 mA.
    static func onBattery() throws -> [String: Any] {
        var d = try acNotCharging()
        d["ExternalConnected"] = false
        d["AppleRawExternalConnected"] = false
        d["IsCharging"] = false
        d["Amperage"] = UInt64(18446744073709550616) // == UInt64(bitPattern: -1000)
        d["InstantAmperage"] = UInt64(18446744073709550616)
        d["AvgTimeToEmpty"] = 248
        d["TimeRemaining"] = 248
        d["ChargerData"] = setting(d["ChargerData"], "NotChargingReason", to: 0)
        return d
    }

    static func setting(_ nested: Any?, _ key: String, to value: Any?) -> [String: Any] {
        var n = nested as? [String: Any] ?? [:]
        n[key] = value
        return n
    }
}

enum FixtureError: Error {
    case missing(String)
    case notADictionary(String)
}

/// Gregorian calendar pinned to UTC so date tests don't depend on the machine's zone.
let utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    utcCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
