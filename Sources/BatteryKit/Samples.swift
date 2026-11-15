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
