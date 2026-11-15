import Foundation
import Testing
@testable import BatteryKit

@Suite("Accessory power sources")
struct AccessoryParserTests {
    /// Real `IOPSCopyPowerSourcesByType` accessory entry (Logitech mouse), identifier scrubbed.
    static let mouse: [String: Any] = [
        "Accessory Category": "Mouse",
        "Accessory Identifier": "00000000-0000-0000-0000-000000000001",
        "Current Capacity": 55,
        "Low Warn Level": 20,
        "Max Capacity": 100,
        "Name": "Logi M650 L",
        "Power Source ID": 40309799,
        "Power Source State": "Battery Power",
        "Product ID": 45098,
        "Transport Type": "Bluetooth LE",
        "Type": "Accessory Source",
        "Vendor ID": 1133,
        "Vendor ID Source": 2,
    ]

    /// AirPods-style group: same group id, one source per part. Synthetic (no AirPods dump yet).
    static func bud(_ part: String, _ percent: Int, charging: Bool = false) -> [String: Any] {
        [
            "Accessory Category": "Headphone",
            "Group Identifier": "00000000-0000-0000-0000-0000000000A1",
            "Accessory Identifier": "00000000-0000-0000-0000-0000000000A1-\(part)",
            "Part Identifier": part,
            "Current Capacity": percent,
            "Max Capacity": 100,
            "Is Charging": charging,
            "Name": "AirPods Pro",
            "Power Source State": charging ? "AC Power" : "Battery Power",
            "Transport Type": "Bluetooth",
            "Type": "Accessory Source",
        ]
    }

    @Test func parsesRealMouse() throws {
        let devices = AccessoryParser.parse([Self.mouse])
        let d = try #require(devices.first)
        #expect(devices.count == 1)
        #expect(d.name == "Logi M650 L")
        #expect(d.kind == .mouse)
        #expect(d.connection == .bluetooth)
        #expect(d.percent == 55)
        #expect(d.isCharging == false)
        #expect(d.parts.isEmpty)
        #expect(d.healthPercent == nil)
    }

    @Test func groupsAirPodsPartsAndUsesLowestBud() throws {
        let devices = AccessoryParser.parse([Self.bud("Case", 88, charging: true), Self.bud("Right", 47), Self.bud("Left", 41)])
        let d = try #require(devices.first)
        #expect(devices.count == 1)
        #expect(d.kind == .airPods)
        #expect(d.parts.map(\.name) == ["Left", "Right", "Case"])
        #expect(d.percent == 41)
        #expect(d.isCharging == false) // only the case charges
        #expect(d.parts.last?.isCharging == true)
    }

    @Test func skipsInternalBattery() {
        let builtIn: [String: Any] = ["Type": "InternalBattery", "Transport Type": "Internal",
                                       "Current Capacity": 80, "Max Capacity": 100, "Name": "InternalBattery-0"]
        #expect(AccessoryParser.parse([builtIn]).isEmpty)
    }

    @Test func scalesNonPercentMaxCapacity() {
        let s: [String: Any] = ["Name": "Pad", "Current Capacity": 3, "Max Capacity": 4, "Type": "Accessory Source"]
        #expect(AccessoryParser.parse([s]).first?.percent == 75)
    }

    @Test(arguments: [
        ("Keyboard", "Magic Keyboard", DeviceBattery.Kind.keyboard),
        ("Trackpad", "Magic Trackpad", .trackpad),
        ("Game Controller", "DualSense", .gameController),
        ("Headphone", "Beats Studio Pro", .headphones),
        ("Headphone", "AirPods Max", .airPods),
        (nil, "Magic Mouse", .mouse),
        (nil, "Something", .other),
    ] as [(String?, String, DeviceBattery.Kind)])
    func kinds(_ category: String?, _ name: String, _ kind: DeviceBattery.Kind) {
        #expect(AccessoryParser.kind(category: category, name: name) == kind)
    }
}

@Suite("iPhone / iPad battery")
struct MobileBatteryParserTests {
    // Synthetic values in the shape lockdown and diagnostics_relay return.
    static let lockdown: [String: Any] = [
        "DeviceName": "Test iPhone", "DeviceClass": "iPhone", "ProductType": "iPhone18,1", "ProductVersion": "26.1",
    ]
    static let battery: [String: Any] = ["BatteryCurrentCapacity": 64, "BatteryIsCharging": true, "ExternalConnected": true]
    static let registry: [String: Any] = [
        "AppleRawMaxCapacity": 3712, "DesignCapacity": 4005, "CycleCount": 212, "Temperature": 3020,
        "CurrentCapacity": 64, "MaxCapacity": 100,
    ]

    @Test func trustedDeviceHasHealth() {
        let d = MobileBatteryParser.parse(id: "x", lockdown: Self.lockdown, battery: Self.battery,
                                          registry: Self.registry, connection: .usb)
        #expect(d.kind == .iPhone)
        #expect(d.name == "Test iPhone")
        #expect(d.osVersion == "iOS 26.1")
        #expect(d.percent == 64)
        #expect(d.isCharging)
        #expect(d.fullChargeCapacityMAh == 3712)
        #expect(d.designCapacityMAh == 4005)
        #expect(d.healthPercent == 92.7)
        #expect(d.cycleCount == 212)
        #expect(d.temperatureC == 30.2)
    }

    @Test func untrustedDeviceKeepsUnknownsNil() {
        let d = MobileBatteryParser.parse(id: "x", lockdown: ["DeviceClass": "iPad", "ProductType": "iPad16,3"],
                                          battery: [:], registry: nil, connection: .wifi, note: "Trust")
        #expect(d.kind == .iPad)
        #expect(d.name == "iPad")
        #expect(d.percent == nil)
        #expect(d.healthPercent == nil)
        #expect(d.temperatureC == nil)
        #expect(d.cycleCount == nil)
        #expect(d.note == "Trust")
    }

    @Test func fallsBackToNominalCapacityAndRegistryPercent() {
        let reg: [String: Any] = ["NominalChargeCapacity": 7000, "DesignCapacity": 7600, "CurrentCapacity": 50]
        let d = MobileBatteryParser.parse(id: "x", lockdown: ["DeviceClass": "iPad", "ProductVersion": "26.0"],
                                          battery: [:], registry: reg, connection: .usb)
        #expect(d.percent == 50)
        #expect(d.fullChargeCapacityMAh == 7000)
        #expect(d.osVersion == "iPadOS 26.0")
    }
}

@Suite("Nearby iPhone (Instant Hotspot)")
struct HotspotParserTests {
    @Test func parsesAdvertisementAndMarksTruncatedName() throws {
        // Shape observed live: name cut to 12 UTF-8 bytes, model, batteryLife as NSNumber.
        let d = try #require(HotspotParser.parse(identifier: "ID-1", name: "Alice’s iP", model: "iPhone14,8",
                                                 batteryLife: NSNumber(value: 75)))
        #expect(d.name == "Alice’s iP…")
        #expect(d.kind == .iPhone)
        #expect(d.connection == .nearby)
        #expect(d.percent == 75)
        #expect(d.isCharging == false)
        #expect(d.healthPercent == nil)
    }

    @Test func shortNameKeptAndZeroIsUnknown() throws {
        let d = try #require(HotspotParser.parse(identifier: "ID-2", name: "iPad", model: "iPad16,3", batteryLife: 0))
        #expect(d.name == "iPad")
        #expect(d.kind == .iPad)
        #expect(d.percent == nil)
    }

    @Test func cabledReadWinsOverNearbyDuplicate() throws {
        let nearby = try #require(HotspotParser.parse(identifier: "n", name: "Alice’s iP", model: "iPhone14,8", batteryLife: 75))
        let other = try #require(HotspotParser.parse(identifier: "o", name: "Kid", model: "iPhone12,1", batteryLife: 40))
        let cabled = DeviceBattery(id: "u", name: "Alice’s iPhone", kind: .iPhone, connection: .usb,
                                   model: "iPhone14,8", percent: 76)
        let merged = HotspotParser.merge(connected: [cabled], nearby: [nearby, other])
        #expect(merged.map(\.id) == ["u", "hotspot-o"])
    }
}

@Suite("Last exact reading")
struct LastExactReadingTests {
    static let t0 = utcDate(2026, 11, 15, 12, 40)
    static let wifi = DeviceBattery(id: "udid-1", name: "Peter’s iP", kind: .iPhone, connection: .wifi,
                                    model: "iPhone14,8", osVersion: "iOS 27.1", percent: 91, isCharging: true,
                                    externalConnected: true, fullChargeCapacityMAh: 4012, designCapacityMAh: 4325,
                                    cycleCount: 388, updatedAt: t0)

    func hotspot(_ name: String = "Peter’s iP", percent: Int = 75) throws -> DeviceBattery {
        try #require(HotspotParser.parse(identifier: "h", name: name, model: "iPhone14,8", batteryLife: percent))
    }

    @Test func connectedBeatsRememberedBeatsHotspot() throws {
        let nearby = try hotspot()
        var live = Self.wifi
        live.percent = 93
        // Connected: the live read; the remembered copy of the same device is dropped.
        let connected = HotspotParser.merge(connected: [live], remembered: [Self.wifi], nearby: [nearby])
        #expect(connected.count == 1)
        #expect(connected[0].percent == 93)
        #expect(!connected[0].isLastKnown)
        #expect(connected[0].isCharging)

        // Disconnected: the last exact reading, marked not connected, beats the hotspot level.
        let remembered = HotspotParser.merge(connected: [], remembered: [Self.wifi], nearby: [nearby])
        #expect(remembered.count == 1)
        let d = remembered[0]
        #expect(d.isLastKnown)
        #expect(!d.isApproximate)
        #expect(d.percent == 91)
        #expect(d.updatedAt == Self.t0)
        #expect(d.connection == nil)
        #expect(!d.isCharging) // no charging claim for a device that isn't there
        #expect(d.cycleCount == 388) // health stays

        // Never read exactly: the hotspot level.
        let hotspotOnly = HotspotParser.merge(connected: [], remembered: [], nearby: [nearby])
        #expect(hotspotOnly.map(\.isApproximate) == [true])
        #expect(hotspotOnly[0].percent == 75)
    }

    @Test func hotspotOfAnotherPhoneStays() throws {
        let kid = try #require(HotspotParser.parse(identifier: "k", name: "Kid", model: "iPhone12,1", batteryLife: 40))
        let other = try hotspot("Work iPhone")
        let merged = HotspotParser.merge(connected: [], remembered: [Self.wifi], nearby: [kid, other])
        #expect(merged.map(\.name) == ["Peter’s iP", "Kid", "Work iPhone"])
    }

    @Test func rememberedApproximateOrLevelessReadingsAreIgnored() throws {
        let merged = HotspotParser.merge(connected: [], remembered: [try hotspot(), .sampleIPadUntrusted], nearby: [])
        #expect(merged.isEmpty)
    }

    @Test func twelveByteNameThatIsAKnownExactNameHasNoEllipsis() throws {
        // "Peter’s iP" is exactly 12 UTF-8 bytes: the advertisement may not have cut it.
        #expect("Peter’s iP".utf8.count == 12)
        let nearby = try hotspot()
        #expect(nearby.name == "Peter’s iP…") // unknown on its own
        let fixed = HotspotParser.merge(connected: [], nearby: [nearby], knownNames: ["Peter’s iP"])
        #expect(fixed.map(\.name) == ["Peter’s iP"])
        // A longer exact name means the advert really was cut.
        let cut = HotspotParser.merge(connected: [], nearby: [nearby], knownNames: ["Peter’s iPhone"])
        #expect(cut.map(\.name) == ["Peter’s iP…"])
        // Shorter names never get the marker.
        #expect(try hotspot("iPad").name == "iPad")
    }

    @Test func storeRoundTripsAndKeepsOnlyExactReadings() throws {
        let tmp = try TempDir()
        let url = tmp.url.appendingPathComponent("BatteryBuddy/last-exact-readings.json")
        let store = LastExactReadingStore(fileURL: url, now: Self.t0)
        #expect(store.devices.isEmpty)
        #expect(try store.remember([Self.wifi, try hotspot(), .sampleIPadUntrusted, .sampleMouse], now: Self.t0))
        #expect(store.devices.map(\.id) == ["udid-1"])

        let reloaded = LastExactReadingStore(fileURL: url, now: Self.t0)
        #expect(reloaded.devices == [Self.wifi])
        #expect(reloaded.readings["udid-1"]?.updatedAt == Self.t0)
    }

    @Test func storeWritesOnChangeAndBatchesTimeOnlyUpdates() throws {
        let tmp = try TempDir()
        let url = tmp.url.appendingPathComponent("last.json")
        let store = LastExactReadingStore(fileURL: url, now: Self.t0)
        #expect(try store.remember([Self.wifi], now: Self.t0))
        // Same reading a minute later: memory only.
        var later = Self.wifi
        later.updatedAt = Self.t0.addingTimeInterval(60)
        #expect(try !store.remember([later], now: Self.t0.addingTimeInterval(60)))
        #expect(store.readings["udid-1"]?.updatedAt == later.updatedAt)
        #expect(LastExactReadingStore(fileURL: url, now: Self.t0).readings["udid-1"]?.updatedAt == Self.t0)
        // flush (disconnect / quit) writes it.
        try store.flush(now: Self.t0.addingTimeInterval(61))
        #expect(LastExactReadingStore(fileURL: url, now: Self.t0).readings["udid-1"]?.updatedAt == later.updatedAt)
        // A new level is written right away.
        var dropped = later
        dropped.percent = 90
        dropped.updatedAt = Self.t0.addingTimeInterval(120)
        #expect(try store.remember([dropped], now: Self.t0.addingTimeInterval(120)))
        #expect(LastExactReadingStore(fileURL: url, now: Self.t0).readings["udid-1"]?.percent == 90)
    }

    @Test func readingsExpireAfter30Days() throws {
        let tmp = try TempDir()
        let url = tmp.url.appendingPathComponent("last.json")
        let store = LastExactReadingStore(fileURL: url, now: Self.t0)
        #expect(try store.remember([Self.wifi], now: Self.t0))
        let day: TimeInterval = 24 * 60 * 60
        // 29 days later: still shown.
        #expect(store.devices(now: Self.t0.addingTimeInterval(29 * day)).map(\.id) == ["udid-1"])
        #expect(LastExactReadingStore(fileURL: url, now: Self.t0.addingTimeInterval(29 * day)).devices(now: Self.t0.addingTimeInterval(29 * day)).count == 1)
        // 31 days later: hidden, and dropped from disk on load.
        let later = Self.t0.addingTimeInterval(31 * day)
        #expect(store.devices(now: later).isEmpty)
        let reloaded = LastExactReadingStore(fileURL: url, now: later)
        #expect(reloaded.readings.isEmpty)
        #expect(LastExactReadingStore(fileURL: url, now: Self.t0).readings.isEmpty)
    }

    @Test func unreadableFileStartsEmpty() throws {
        let tmp = try TempDir()
        let url = tmp.url.appendingPathComponent("last.json")
        try Data("not json".utf8).write(to: url)
        #expect(LastExactReadingStore(fileURL: url, now: Self.t0).devices.isEmpty)
    }

    @Test func mobileReadCarriesItsTime() {
        let d = MobileBatteryParser.parse(id: "u", lockdown: ["DeviceClass": "iPhone"],
                                          battery: ["BatteryCurrentCapacity": 91], registry: nil,
                                          connection: .wifi, updatedAt: Self.t0)
        #expect(d.updatedAt == Self.t0)
        #expect(d.isExactReading)
    }
}

@Suite("Freshness")
struct FreshnessTests {
    let now = utcDate(2026, 11, 15, 12, 40)
    let locale = Locale(identifier: "en_GB")

    func fresh(_ seconds: TimeInterval) -> String {
        Fmt.freshness(now.addingTimeInterval(-seconds), now: now, calendar: utcCalendar, locale: locale)
    }

    @Test func relativeWhenRecent() {
        #expect(fresh(0) == "just now")
        #expect(fresh(59) == "just now")
        #expect(fresh(-30) == "just now") // clock skew
        #expect(fresh(60) == "1 min ago")
        #expect(fresh(3 * 60 + 20) == "3 min ago")
        #expect(fresh(59 * 60 + 59) == "59 min ago")
    }

    @Test func timeEarlierToday() {
        #expect(fresh(3600) == "11:40")
        #expect(Fmt.freshness(utcDate(2026, 11, 15, 0, 5), now: now, calendar: utcCalendar, locale: locale) == "00:05")
    }

    @Test func dateOnOtherDays() {
        #expect(Fmt.freshness(utcDate(2026, 11, 14, 23, 50), now: now, calendar: utcCalendar, locale: locale) == "14 Nov")
        #expect(Fmt.freshness(utcDate(2025, 12, 31, 9), now: now, calendar: utcCalendar, locale: locale) == "31 Dec 2025")
    }
}
