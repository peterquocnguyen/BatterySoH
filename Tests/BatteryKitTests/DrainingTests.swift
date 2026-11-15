@testable import BatteryKit
import Testing

@Suite("Draining on charger")
struct DrainingTests {
    @Test func drainingSampleIsDetected() {
        let s = BatterySnapshot.sampleDraining
        #expect(s.powerState == .drainingOnAC)
        #expect(!s.isChargeOnHold)
        #expect(s.statusTitle == "Draining on charger")
        #expect(s.timeSummary == "draining despite charger")
        #expect(s.minutesRemaining == 372)
        let deficit = try! #require(s.chargerDeficitW)
        #expect(abs(deficit - 8.8056) < 0.01)
        // systemLoad wins when reported.
        #expect(s.macLoadW == 73.8)
    }

    @Test func loadFallsBackToInputPlusBattery() {
        var s = BatterySnapshot.sampleDraining
        s.systemLoadW = nil
        let load = try! #require(s.macLoadW)
        #expect(abs(load - (65 + 8.8056)) < 0.01)
    }

    @Test func smallDischargeOnACIsNotDraining() {
        var s = BatterySnapshot.sampleOnHold
        s.amperageMA = -20 // 0.25 W: gauge noise
        #expect(s.powerState == .onACNotCharging)
        #expect(s.isChargeOnHold)
    }

    @Test func justUnpluggedIsOnBattery() {
        let s = BatterySnapshot.sampleJustUnplugged
        #expect(s.powerState == .onBattery)
        #expect(s.batteryPowerW == 0)
        #expect(s.macLoadW == 7.4)
        #expect(s.timeSummary == "calculating…")
    }
}
