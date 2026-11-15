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
        let merged = HotspotParser.merge(cabled: [cabled], nearby: [nearby, other])
        #expect(merged.map(\.id) == ["u", "hotspot-o"])
    }
}
