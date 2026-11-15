import Foundation
import Testing
@testable import BatteryKit

@Suite("BatterySnapshot derived values")
struct DerivedValueTests {
    // MARK: healthPercent

    @Test func healthUsesFullChargeOverDesign() {
        let s = BatterySnapshot(chargePercent: 50, fullChargeCapacityMAh: 5000, designCapacityMAh: 6250)
        #expect(s.healthPercent == 80)
    }

    @Test func healthFallsBackToNominal() {
        let s = BatterySnapshot(chargePercent: 50, nominalChargeCapacityMAh: 3125, designCapacityMAh: 6250)
        #expect(s.healthPercent == 50)
    }

    @Test func healthIsCappedAt100() {
        let s = BatterySnapshot(chargePercent: 50, fullChargeCapacityMAh: 6500, designCapacityMAh: 6249)
        #expect(s.healthPercent == 100)
    }

    @Test func healthNilWithoutDesignOrFull() {
        #expect(BatterySnapshot(chargePercent: 1, fullChargeCapacityMAh: 5000).healthPercent == nil)
        #expect(BatterySnapshot(chargePercent: 1, fullChargeCapacityMAh: 5000, designCapacityMAh: 0).healthPercent == nil)
        #expect(BatterySnapshot(chargePercent: 1, fullChargeCapacityMAh: 0, designCapacityMAh: 6000).healthPercent == nil)
    }

    // MARK: batteryPowerW

    @Test func batteryPowerSign() {
        let charging = BatterySnapshot(chargePercent: 1, voltageMV: 12520, amperageMA: 3770)
        let discharging = BatterySnapshot(chargePercent: 1, voltageMV: 12100, amperageMA: -1000)
        #expect(abs(charging.batteryPowerW! - 47.2004) < 0.0001)
        #expect(discharging.batteryPowerW == -12.1)
        #expect(BatterySnapshot(chargePercent: 1, voltageMV: 12000).batteryPowerW == nil)
        #expect(BatterySnapshot(chargePercent: 1, amperageMA: 100).batteryPowerW == nil)
    }

    // MARK: macLoadW

    @Test func macLoadPrefersTelemetry() {
        var s = BatterySnapshot.sampleCharging
        s.systemLoadW = 18
        #expect(s.macLoadW == 18)
    }

    @Test func macLoadOnBatteryFallsBackToBatteryDraw() {
        var s = BatterySnapshot.sampleOnBattery
        s.systemLoadW = nil
        #expect(s.macLoadW == 12.1)
    }

    @Test func macLoadOnACFallsBackToPowerInMinusCharging() throws {
        var s = BatterySnapshot.sampleCharging // 65 W in, +47.2 W into battery
        s.systemLoadW = nil
        let load = try #require(s.macLoadW)
        #expect(abs(load - (65 - 47.2004)) < 0.0001)
    }

    @Test func macLoadOnACAddsBatteryAssist() {
        // On AC with the battery assisting (draining on charger): load = power in + battery out.
        var s = BatterySnapshot.sampleOnHold
        s.systemLoadW = nil
        s.systemPowerInW = 30
        s.amperageMA = -500
        #expect(s.powerState == .drainingOnAC)
        let load = try! #require(s.macLoadW)
        #expect(abs(load - (30 + 12.356 * 0.5)) < 0.001)
    }

    @Test func macLoadOnACNeverNegative() {
        var s = BatterySnapshot.sampleCharging
        s.systemLoadW = nil
        s.systemPowerInW = 10 // less than battery charge power
        #expect(s.macLoadW == 0)
    }

    @Test func macLoadOnACWithoutPowerInIsNil() {
        var s = BatterySnapshot.sampleCharging
        s.systemLoadW = nil
        s.systemPowerInW = nil
        #expect(s.macLoadW == nil)
    }

    @Test func macLoadZeroTelemetryTreatedAsMissing() {
        var s = BatterySnapshot.sampleOnBattery
        s.systemLoadW = 0
        #expect(s.macLoadW == 12.1)
    }

    // MARK: minutesRemaining / statusTitle / timeSummary

    @Test func minutesRemainingFollowsDirection() {
        var s = BatterySnapshot.sampleCharging
        s.minutesToEmpty = 300
        #expect(s.minutesRemaining == 58)
        var b = BatterySnapshot.sampleOnBattery
        b.minutesToFull = 30
        #expect(b.minutesRemaining == 248)
        #expect(BatterySnapshot.sampleOnHold.minutesRemaining == nil)
    }

    @Test func statusTitles() {
        #expect(BatterySnapshot.sampleCharging.statusTitle == "Charging")
        #expect(BatterySnapshot.sampleOnBattery.statusTitle == "On battery")
        #expect(BatterySnapshot.sampleOnHold.statusTitle == "Charging on hold")
        var connected = BatterySnapshot.sampleOnHold
        connected.notChargingReason = 0
        #expect(connected.statusTitle == "Charger connected")
        connected.notChargingReason = nil
        #expect(connected.statusTitle == "Charger connected")
        var full = connected
        full.fullyCharged = true
        #expect(full.statusTitle == "Fully charged")
    }

    @Test func timeSummaries() {
        #expect(BatterySnapshot.sampleCharging.timeSummary == "full in 58 min")
        #expect(BatterySnapshot.sampleOnBattery.timeSummary == "4h 8m left")
        #expect(BatterySnapshot.sampleOnHold.timeSummary == "not charging")
        var c = BatterySnapshot.sampleCharging
        c.minutesToFull = nil
        #expect(c.timeSummary == "calculating…")
        var b = BatterySnapshot.sampleOnBattery
        b.minutesToEmpty = nil
        #expect(b.timeSummary == "calculating…")
        b.minutesToEmpty = 125
        #expect(b.timeSummary == "2h 5m left")
    }

    @Test func powerStatePrecedence() {
        // Not connected wins over stale charging flags.
        let s = BatterySnapshot(chargePercent: 90, isCharging: true, externalConnected: false, fullyCharged: true)
        #expect(s.powerState == .onBattery)
        // Charging wins over fullyCharged.
        let c = BatterySnapshot(chargePercent: 99, isCharging: true, externalConnected: true, fullyCharged: true)
        #expect(c.powerState == .charging)
    }

    // MARK: Models

    @Test func pdProfileWatts() {
        #expect(PDProfile(index: 0, voltageMV: 5000, currentMA: 3000).watts == 15)
        #expect(PDProfile(index: 4, voltageMV: 20000, currentMA: 3250).watts == 65)
    }

    @Test func activeProfileMatchesByIndexNotPosition() {
        let a = PowerAdapter(profiles: [PDProfile(index: 2, voltageMV: 9000, currentMA: 3000),
                                        PDProfile(index: 5, voltageMV: 20000, currentMA: 5000)],
                             activeProfileIndex: 5)
        #expect(a.activeProfile?.voltageMV == 20000)
        #expect(PowerAdapter(profiles: a.profiles, activeProfileIndex: 9).activeProfile == nil)
    }

    @Test func adapterDisplayKind() {
        #expect(PowerAdapter(isWireless: true).displayKind == "Wireless charger")
        #expect(PowerAdapter(description: "").displayKind == "Power adapter")
        #expect(PowerAdapter().displayKind == "Power adapter")
        #expect(BatterySnapshot.sampleAdapter.displayKind == "USB-C Power Delivery")
    }

    @Test func historySampleFromSnapshot() throws {
        let s = try #require(HistorySample(snapshot: .sampleOnHold))
        #expect(s.cycleCount == 183)
        #expect(s.fullChargeCapacityMAh == 5596)
        #expect(s.designCapacityMAh == 6249)
        #expect(abs(s.healthPercent - 89.55) < 0.01)
        #expect(HistorySample(snapshot: BatterySnapshot(chargePercent: 5)) == nil)
    }
}
