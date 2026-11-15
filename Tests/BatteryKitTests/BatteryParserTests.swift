import Foundation
import Testing

@testable import BatteryKit

@Suite("BatteryParser: real fixture (AC, charge on hold)")
struct FixtureParseTests {
    let snap: BatterySnapshot

    init() throws {
        snap = BatteryParser.parse(try Fixture.acNotCharging(), now: Date(timeIntervalSince1970: 0))
    }

    @Test func timestampIsInjected() {
        #expect(snap.timestamp == Date(timeIntervalSince1970: 0))
    }

    @Test func charge() {
        #expect(snap.chargePercent == 80)
        #expect(snap.rawChargePercent == 79.0)
        #expect(snap.currentCapacityMAh == 4421)
        #expect(snap.fullChargeCapacityMAh == 5596)
        #expect(snap.nominalChargeCapacityMAh == 5748)
        #expect(snap.designCapacityMAh == 6249)
    }

    @Test func health() throws {
        let h = try #require(snap.healthPercent)
        #expect(abs(h - 89.55) < 0.01)
        #expect(Fmt.percent(h, decimals: 1) == "89.6%")
    }

    @Test func cycles() {
        #expect(snap.cycleCount == 183)
        #expect(snap.designCycleCount == 1000)
    }

    @Test func electrical() {
        #expect(snap.voltageMV == 12356)
        #expect(snap.amperageMA == 0)
        #expect(snap.batteryPowerW == 0)
    }

    @Test func adapter() throws {
        let a = try #require(snap.adapter)
        #expect(a.watts == 65)
        #expect(a.voltageMV == 20000)
        #expect(a.currentMA == 3250)
        #expect(a.description == "pd charger")
        #expect(a.isWireless == false)
        #expect(a.profiles.count == 5)
        #expect(a.profiles.map(\.voltageMV) == [5000, 9000, 12000, 15000, 20000])
        #expect(a.activeProfileIndex == 4)
        let active = try #require(a.activeProfile)
        #expect(active.voltageMV == 20000)
        #expect(active.currentMA == 3250)
        #expect(active.watts == 65)
        #expect(a.displayKind == "USB-C Power Delivery")
    }

    @Test func state() {
        #expect(snap.externalConnected)
        #expect(!snap.isCharging)
        #expect(!snap.fullyCharged)
        #expect(snap.powerState == .onACNotCharging)
        #expect(snap.notChargingReason == 0x0100_0000)
        #expect(snap.isChargeOnHold)
        #expect(snap.statusTitle == "Charging on hold")
        #expect(snap.timeSummary == "not charging")
    }

    @Test func temperatureAbsentIsNil() {
        #expect(snap.temperatureC == nil)
        #expect(Fmt.temperature(snap.temperatureC) == Fmt.dash)
    }

    @Test func unknownTimeSentinelIsNil() {
        #expect(snap.minutesToEmpty == nil)
        #expect(snap.minutesToFull == nil)
        #expect(snap.minutesRemaining == nil)
    }

    @Test func telemetry() {
        #expect(snap.systemLoadW == 12.235)
        #expect(snap.systemPowerInW == 12.235)
        #expect(snap.macLoadW == 12.235)
    }

    @Test func identity() {
        #expect(snap.serial == "TESTSERIAL0000000")
        #expect(snap.gaugeName == "bq40z651")
        #expect(snap.manufactureDate == nil)
    }

    @Test func snapshotJSONRoundTrip() throws {
        let data = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(BatterySnapshot.self, from: data) == snap)
    }
}

@Suite("BatteryParser: derived fixtures")
struct DerivedFixtureParseTests {
    @Test func charging() throws {
        let s = BatteryParser.parse(try Fixture.charging())
        #expect(s.powerState == .charging)
        #expect(s.amperageMA == 3770)
        #expect(s.minutesToFull == 58)
        #expect(s.minutesRemaining == 58)
        #expect(!s.isChargeOnHold)
        #expect(s.statusTitle == "Charging")
        #expect(s.timeSummary == "full in 58 min")
        let w = try #require(s.batteryPowerW)
        #expect(abs(w - 46.58) < 0.01)
        #expect(w > 0)
        #expect(Fmt.watts(w, signed: true) == "+46.6 W")
    }

    @Test func onBatteryNegativeAmperageFromUnsigned() throws {
        let s = BatteryParser.parse(try Fixture.onBattery())
        #expect(s.powerState == .onBattery)
        #expect(s.amperageMA == -1000)
        #expect(s.adapter == nil, "adapter is ignored when external power is not connected")
        #expect(s.minutesToEmpty == 248)
        #expect(s.minutesRemaining == 248)
        #expect(s.statusTitle == "On battery")
        #expect(s.timeSummary == "4h 8m left")
        #expect(!s.isChargeOnHold)
        let w = try #require(s.batteryPowerW)
        #expect(abs(w - -12.356) < 0.0001)
    }

    /// Same encoding but arriving via an XML plist (how `sohstat --raw` fixtures store it).
    @Test func unsignedAmperageViaXMLPlist() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Amperage</key><integer>18446744073709550616</integer>
              <key>CurrentCapacity</key><integer>50</integer>
            </dict></plist>
            """
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])
        #expect(BatteryParser.parse(dict).amperageMA == -1000)
    }

    @Test func unsignedAmperageAsNSNumber() {
        let s = BatteryParser.parse(["Amperage": NSNumber(value: UInt64(18_446_744_073_709_550_616))])
        #expect(s.amperageMA == -1000)
    }

    @Test func temperatureCentiCelsius() {
        var d = (try? Fixture.acNotCharging()) ?? [:]
        d["Temperature"] = 3150
        #expect(BatteryParser.parse(d).temperatureC == 31.5)
    }

    @Test func virtualTemperatureFallback() {
        #expect(BatteryParser.parse(["VirtualTemperature": 2987]).temperatureC == 29.87)
    }

    @Test func zeroTemperatureIsUnknown() {
        #expect(BatteryParser.parse(["Temperature": 0]).temperatureC == nil)
    }

    @Test func manufactureDatePacked() throws {
        // 2023-05-17: day | month << 5 | (year - 1980) << 9
        let packed = 17 | 5 << 5 | (2023 - 1980) << 9
        var d = try Fixture.acNotCharging()
        d["ManufactureDate"] = packed
        let date = try #require(BatteryParser.parse(d).manufactureDate)
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        #expect(c.year == 2023)
        #expect(c.month == 5)
        #expect(c.day == 17)
    }

    @Test(arguments: [0, 0x1F, 1 | 13 << 5 | 40 << 9, 1 | 1 << 5 | 10 << 9])
    func implausibleManufactureDateIsNil(_ raw: Int) {
        // 0, day 31 / month 0, month 13, year 1990
        #expect(BatteryParser.manufactureDate(raw) == nil)
    }

    @Test func missingBatteryData() throws {
        var d = try Fixture.acNotCharging()
        d.removeValue(forKey: "BatteryData")
        let s = BatteryParser.parse(d)
        #expect(s.chargePercent == 80, "top-level CurrentCapacity still used")
        #expect(s.rawChargePercent == nil)
        #expect(s.currentCapacityMAh == nil)
        #expect(s.fullChargeCapacityMAh == nil)
        #expect(s.designCapacityMAh == nil)
        #expect(s.healthPercent == nil)
        #expect(s.cycleCount == 183)
    }

    @Test func emptyDictionary() {
        let s = BatteryParser.parse([:])
        #expect(s.chargePercent == 0)
        #expect(s.powerState == .onBattery)
        #expect(s.adapter == nil)
        #expect(s.voltageMV == nil)
        #expect(s.batteryPowerW == nil)
        #expect(s.macLoadW == nil)
        #expect(s.temperatureC == nil)
        #expect(s.timeSummary == "calculating…")
    }

    @Test func emptyAdapterDetailsIsNil() throws {
        var d = try Fixture.acNotCharging()
        d["AdapterDetails"] = [String: Any]()
        #expect(BatteryParser.parse(d).adapter == nil)
    }

    @Test func zeroWattAdapterDetailsIsNil() throws {
        var d = try Fixture.acNotCharging()
        d["AdapterDetails"] = ["Watts": 0, "FamilyCode": 0, "AdapterID": 0, "IsWireless": false] as [String: Any]
        #expect(BatteryParser.parse(d).adapter == nil)
    }

    @Test func nonPDAdapter() throws {
        let a = try #require(BatteryParser.adapter(["Watts": 30, "Description": "magsafe"] as [String: Any]))
        #expect(a.profiles.isEmpty)
        #expect(a.activeProfileIndex == nil)
        #expect(a.activeProfile == nil)
        #expect(a.displayKind == "Magsafe")
    }

    @Test func fullyChargedOnAC() throws {
        var d = try Fixture.acNotCharging()
        d["FullyCharged"] = true
        d["ChargerData"] = Fixture.setting(d["ChargerData"], "NotChargingReason", to: 0)
        let s = BatteryParser.parse(d)
        #expect(s.powerState == .full)
        #expect(!s.isChargeOnHold)
        #expect(s.statusTitle == "Fully charged")
        #expect(s.timeSummary == "fully charged")
        #expect(s.minutesRemaining == nil)
    }

    @Test func acNotChargingWithoutReason() throws {
        var d = try Fixture.acNotCharging()
        d["ChargerData"] = Fixture.setting(d["ChargerData"], "NotChargingReason", to: 0)
        let s = BatteryParser.parse(d)
        #expect(s.powerState == .onACNotCharging)
        #expect(!s.isChargeOnHold)
        #expect(s.statusTitle == "Charger connected")
    }

    @Test func timeRemainingIgnoredOnAC() throws {
        var d = try Fixture.acNotCharging()
        d["TimeRemaining"] = 120
        #expect(BatteryParser.parse(d).minutesToEmpty == nil)
    }
}

@Suite("BatteryParser: loose typing helpers")
struct LooseTypingTests {
    @Test func int() {
        #expect(BatteryParser.int(42) == 42)
        #expect(BatteryParser.int(NSNumber(value: 42)) == 42)
        #expect(BatteryParser.int(Int64(-5)) == -5)
        #expect(BatteryParser.int(UInt64.max) == -1)
        #expect(BatteryParser.int("17") == 17)
        #expect(BatteryParser.int(true) == 1)
        #expect(BatteryParser.int(nil) == nil)
        #expect(BatteryParser.int([1]) == nil)
    }

    @Test func bool() {
        #expect(BatteryParser.bool(true) == true)
        #expect(BatteryParser.bool(NSNumber(value: 0)) == false)
        #expect(BatteryParser.bool("Yes") == true)
        #expect(BatteryParser.bool("no") == false)
        #expect(BatteryParser.bool(nil) == nil)
    }

    @Test func string() {
        #expect(BatteryParser.string("  bq40z651\0") == "bq40z651")
        #expect(BatteryParser.string("   ") == nil)
        #expect(BatteryParser.string(5) == nil)
    }
}
