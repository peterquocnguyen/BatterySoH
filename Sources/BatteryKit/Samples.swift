import Foundation

/// Canned snapshots for previews, render checks and tests. Values mirror the design mockups.
public extension BatterySnapshot {
    static let usbPDProfiles: [PDProfile] = [
        PDProfile(index: 0, voltageMV: 5000, currentMA: 3000),
        PDProfile(index: 1, voltageMV: 9000, currentMA: 3000),
        PDProfile(index: 2, voltageMV: 12000, currentMA: 3000),
        PDProfile(index: 3, voltageMV: 15000, currentMA: 3000),
        PDProfile(index: 4, voltageMV: 20000, currentMA: 3250),
    ]

    static let sampleAdapter = PowerAdapter(watts: 65, voltageMV: 20000, currentMA: 3250,
                                            description: "pd charger", profiles: usbPDProfiles,
                                            activeProfileIndex: 4)

    /// Plugged into a 65 W USB-C PD charger, charging at +47.2 W.
    static let sampleCharging = BatterySnapshot(
        chargePercent: 71, rawChargePercent: 71.3, currentCapacityMAh: 4245,
        fullChargeCapacityMAh: 5955, nominalChargeCapacityMAh: 6010, designCapacityMAh: 6249,
        cycleCount: 75, designCycleCount: 1000, voltageMV: 12520, amperageMA: 3770, temperatureC: 31.5,
        isCharging: true, externalConnected: true, minutesToFull: 58,
        adapter: sampleAdapter, systemLoadW: 18.0, systemPowerInW: 65.0,
        serial: "SAMPLE", gaugeName: "bq40z651")

    /// Unplugged, discharging at 12.1 W.
    static let sampleOnBattery = BatterySnapshot(
        chargePercent: 67, rawChargePercent: 67.5, currentCapacityMAh: 4406,
        fullChargeCapacityMAh: 5955, nominalChargeCapacityMAh: 6010, designCapacityMAh: 6249,
        cycleCount: 102, designCycleCount: 1000, voltageMV: 12100, amperageMA: -1000, temperatureC: 26.4,
        isCharging: false, externalConnected: false, minutesToEmpty: 248,
        systemLoadW: 12.1, serial: "SAMPLE", gaugeName: "bq40z651")

    /// On AC at 80 %, macOS holding the charge (optimized charging / charge limit).
    static let sampleOnHold = BatterySnapshot(
        chargePercent: 80, rawChargePercent: 79.0, currentCapacityMAh: 4421,
        fullChargeCapacityMAh: 5596, nominalChargeCapacityMAh: 5748, designCapacityMAh: 6249,
        cycleCount: 183, designCycleCount: 1000, voltageMV: 12356, amperageMA: 0, temperatureC: 35.0,
        isCharging: false, externalConnected: true, notChargingReason: 0x0100_0000,
        adapter: sampleAdapter, systemLoadW: 6.7, systemPowerInW: 6.7,
        serial: "SAMPLE", gaugeName: "bq40z651")

    /// On a 65 W charger while the Mac pulls ~74 W: battery drains at 8.8 W anyway.
    static let sampleDraining = BatterySnapshot(
        chargePercent: 80, rawChargePercent: 79.6, currentCapacityMAh: 4455,
        fullChargeCapacityMAh: 5596, nominalChargeCapacityMAh: 5748, designCapacityMAh: 6249,
        cycleCount: 183, designCycleCount: 1000, voltageMV: 12230, amperageMA: -720, temperatureC: 38.2,
        isCharging: false, externalConnected: true, minutesToEmpty: 372,
        adapter: sampleAdapter, systemLoadW: 73.8, systemPowerInW: 65.0,
        serial: "SAMPLE", gaugeName: "bq40z651")

    /// Seconds after unplugging: amperage not updated yet (0 A), no time estimate.
    static let sampleJustUnplugged = BatterySnapshot(
        chargePercent: 80, rawChargePercent: 79.0, currentCapacityMAh: 4421,
        fullChargeCapacityMAh: 5596, nominalChargeCapacityMAh: 5748, designCapacityMAh: 6249,
        cycleCount: 183, designCycleCount: 1000, voltageMV: 12340, amperageMA: 0, temperatureC: 35.4,
        isCharging: false, externalConnected: false,
        systemLoadW: 7.4, serial: "SAMPLE", gaugeName: "bq40z651")

    static let allSamples: [(name: String, snapshot: BatterySnapshot)] = [
        ("charging", sampleCharging), ("on-battery", sampleOnBattery), ("on-hold", sampleOnHold),
        ("draining", sampleDraining), ("just-unplugged", sampleJustUnplugged),
    ]
}

public extension HistorySample {
    /// ~2 years of monthly samples with slowly declining health.
    static func sampleSeries(endingAt end: Date = Date(), months: Int = 22) -> [HistorySample] {
        let cal = Calendar(identifier: .gregorian)
        return (0..<months).compactMap { i -> HistorySample? in
            guard let d = cal.date(byAdding: .month, value: -(months - 1 - i), to: end) else { return nil }
            let health = 100 - Double(i) * 0.5
            return HistorySample(date: d, healthPercent: min(100, health), cycleCount: 8 + i * 8,
                                 fullChargeCapacityMAh: Int(6249 * health / 100), designCapacityMAh: 6249)
        }
    }
}

/// Canned other-device batteries for previews and render checks.
public extension DeviceBattery {
    /// A time on the sample day (2026-11-15, local), for `updatedAt` in render entries.
    private static func sampleTime(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date? {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: hour, minute: minute, second: second))
    }

    /// 2026-11-15 12:07 local time: the "now" of the window render entries.
    static var sampleNow: Date { sampleTime(12, 7) ?? Date() }

    static let sampleIPhone = DeviceBattery(
        id: "sample-iphone", name: "Work iPhone", kind: .iPhone, connection: .usb,
        model: "iPhone18,1", osVersion: "iOS 26.1", percent: 64, isCharging: true, externalConnected: true,
        fullChargeCapacityMAh: 3712, designCapacityMAh: 4005, cycleCount: 212, temperatureC: 30.2,
        updatedAt: sampleTime(12, 4))

    /// Read over Wi-Fi sync seconds before `sampleNow`: "Updated just now".
    static let sampleWiFiIPhone = DeviceBattery(
        id: "sample-wifi-iphone", name: "Peter’s iP", kind: .iPhone, connection: .wifi,
        model: "iPhone14,8", osVersion: "iOS 27.1", percent: 91, isCharging: true, externalConnected: true,
        fullChargeCapacityMAh: 4012, designCapacityMAh: 4325, cycleCount: 388,
        updatedAt: sampleTime(12, 6, 40))

    /// The same phone's last exact reading at 10:40, before it went to sleep (pass it to
    /// `HotspotParser.merge` as `remembered`).
    static let sampleRememberedIPhone: DeviceBattery = {
        var d = sampleWiFiIPhone
        d.percent = 88
        d.isCharging = false
        d.externalConnected = false
        d.updatedAt = sampleTime(10, 40)
        return d
    }()

    static let sampleIPadUntrusted = DeviceBattery(
        id: "sample-ipad", name: "iPad", kind: .iPad, connection: .wifi, model: "iPad16,3",
        percent: nil, note: "Unlock iPad and tap Trust to see its battery.")

    static let sampleAirPods = DeviceBattery(
        id: "sample-airpods", name: "AirPods Pro", kind: .airPods, connection: .bluetooth, percent: 41,
        parts: [Part(name: "Left", percent: 41), Part(name: "Right", percent: 47),
                Part(name: "Case", percent: 88, isCharging: true)])

    static let sampleMouse = DeviceBattery(
        id: "sample-mouse", name: "Magic Mouse", kind: .mouse, connection: .bluetooth, percent: 12)

    static let sampleKeyboard = DeviceBattery(
        id: "sample-keyboard", name: "Magic Keyboard", kind: .keyboard, connection: .usb, percent: 96,
        isCharging: true, externalConnected: true)

    static let sampleNearbyIPhone = DeviceBattery(
        id: "sample-nearby", name: "Peter’s iP…", kind: .iPhone, connection: .nearby,
        model: "iPhone14,8", percent: 75, note: HotspotParser.approximateNote(kind: .iPhone),
        isApproximate: true, updatedAt: sampleTime(12, 3))

    static let samples: [DeviceBattery] = [sampleIPhone, sampleIPadUntrusted, sampleNearbyIPhone,
                                           sampleAirPods, sampleMouse, sampleKeyboard]
}
