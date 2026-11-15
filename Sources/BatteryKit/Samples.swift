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
    static let sampleIPhone = DeviceBattery(
        id: "sample-iphone", name: "Work iPhone", kind: .iPhone, connection: .usb,
        model: "iPhone18,1", osVersion: "iOS 26.1", percent: 64, isCharging: true, externalConnected: true,
        fullChargeCapacityMAh: 3712, designCapacityMAh: 4005, cycleCount: 212, temperatureC: 30.2)

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
        isApproximate: true,
        levelSince: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12, minute: 3)))

    static let samples: [DeviceBattery] = [sampleIPhone, sampleIPadUntrusted, sampleNearbyIPhone,
                                           sampleAirPods, sampleMouse, sampleKeyboard]
}

/// Synthetic charge logs for previews and render checks: a realistic week, deterministic.
public extension ChargeLog {
    /// 2026-11-15 12:07 local time: the "now" of the Insights render entries.
    static var sampleNow: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12, minute: 7)) ?? Date()
    }

    /// This Mac: on battery 8:45–12:30 and 13:15–18:30, charging over lunch, asleep at night
    /// (no readings). Readings every 5 minutes; today runs lighter than usual.
    static func sampleMacWeek(now: Date = sampleNow, calendar: Calendar = .current) -> ChargeLog {
        var log = ChargeLog(id: thisMacID, name: "MacBook Pro")
        simulate(&log, now: now, calendar: calendar, factors: [1.0, 0.85, 1.25, 0.7, 1.1, 0.95, 1.15, 0.55],
                 step: 5, hours: 8.75...18.5, drainPerHour: 9, charging: 12.5..<13.25, chargePerHour: 40,
                 approximate: false)
        return log
    }

    /// An iPhone seen only through Instant Hotspot: approximate readings every 30 minutes
    /// (the idle browse), 7:00–23:00, charging on the desk 18:00–19:00.
    static func sampleIPhoneWeek(now: Date = sampleNow, calendar: Calendar = .current) -> ChargeLog {
        var log = ChargeLog(id: "ios|iPhone14,8|Peter’s iP", name: "Peter’s iP…", kind: .iPhone, model: "iPhone14,8")
        simulate(&log, now: now, calendar: calendar, factors: [0.9, 1.1, 1.0, 1.3, 0.8, 1.0, 1.2, 1.15],
                 step: 30, hours: 7...23, drainPerHour: 5, charging: 18..<19, chargePerHour: 30,
                 approximate: true)
        return log
    }

    private static func simulate(_ log: inout ChargeLog, now: Date, calendar: Calendar, factors: [Double],
                                 step: Int, hours: ClosedRange<Double>, drainPerHour: Double,
                                 charging: Range<Double>, chargePerHour: Double, approximate: Bool) {
        let today = calendar.startOfDay(for: now)
        for (i, factor) in factors.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: i - (factors.count - 1), to: today) else { continue }
            var level = 100.0
            var minute = Int(hours.lowerBound * 60)
            while Double(minute) <= hours.upperBound * 60 {
                let date = day.addingTimeInterval(TimeInterval(minute * 60))
                if date > now { break }
                let hour = Double(minute) / 60
                let isCharging = charging.contains(hour)
                // Busier late morning and mid-afternoon.
                let wobble = 1 + 0.35 * sin(hour * 1.3 + Double(i))
                let delta = Double(step) / 60 * (isCharging ? chargePerHour : -drainPerHour * factor * wobble)
                level = min(100, max(3, level + delta))
                log.record(ChargeSample(date: date, percent: level.rounded(),
                                        isCharging: approximate ? nil : isCharging, isApproximate: approximate))
                minute += step
            }
        }
    }
}
