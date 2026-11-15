import Foundation
import Testing
@testable import BatteryKit

@Suite("Battery condition (F11)")
struct ConditionTests {
    // MARK: Maximum capacity

    @Test func maximumCapacityUsesNominalRoundedDown() {
        // This Mac: System Information said 91 % for 5,744 of 6,249 mAh.
        #expect(BatteryCondition.maximumCapacityPercent(nominalMAh: 5744, fullMAh: 5592, designMAh: 6249) == 91)
        #expect(BatteryCondition.maximumCapacityPercent(nominalMAh: nil, fullMAh: 5592, designMAh: 6249) == 89)
        #expect(BatteryCondition.maximumCapacityPercent(nominalMAh: 0, fullMAh: 5592, designMAh: 6249) == 89)
        #expect(BatteryCondition.maximumCapacityPercent(nominalMAh: 7000, fullMAh: nil, designMAh: 6249) == 100)
        #expect(BatteryCondition.maximumCapacityPercent(nominalMAh: 5744, fullMAh: nil, designMAh: nil) == nil)
        #expect(BatteryCondition.maximumCapacityPercent(nominalMAh: nil, fullMAh: nil, designMAh: 6249) == nil)
    }

    // MARK: Estimate

    @Test(arguments: [(80, BatteryCondition.Status.normal), (79, .serviceRecommended), (100, .normal), (40, .serviceRecommended)])
    func serviceLevelIs80(_ capacity: Int, _ status: BatteryCondition.Status) {
        #expect(BatteryCondition.estimate(maximumCapacityPercent: capacity)?.status == status)
    }

    @Test func permanentFailureNeedsService() {
        let c = BatteryCondition.estimate(maximumCapacityPercent: 95, permanentFailure: true)
        #expect(c?.status == .serviceRecommended)
        #expect(c?.permanentFailure == true)
    }

    @Test func nothingToGoOn() {
        #expect(BatteryCondition.estimate(maximumCapacityPercent: nil) == nil)
    }

    @Test func peakPerformanceOnlyForIPhone() {
        #expect(BatteryCondition.estimate(maximumCapacityPercent: 90)?.peakPerformance == nil)
        #expect(BatteryCondition.estimate(maximumCapacityPercent: 90, isIPhone: true)?.peakPerformance == .normal)
        #expect(BatteryCondition.estimate(maximumCapacityPercent: 90, unexpectedShutdown: true, isIPhone: true)?
            .peakPerformance == .unexpectedShutdown)
        // A worn battery wins over the shutdown record.
        #expect(BatteryCondition.estimate(maximumCapacityPercent: 74, unexpectedShutdown: true, isIPhone: true)?
            .peakPerformance == .worn)
    }

    @Test func pointsAboveServiceLevel() {
        #expect(BatteryCondition.estimate(maximumCapacityPercent: 91)?.pointsAboveServiceLevel == 11)
        #expect(BatteryCondition.estimate(maximumCapacityPercent: 70)?.pointsAboveServiceLevel == 0)
    }

    // MARK: Mac

    @Test func macPrefersMacOSVerdict() {
        let c = BatteryCondition.mac(.sampleOnHold, reported: MacReportedHealth(health: "Good", maximumCapacityPercent: 91))
        #expect(c == BatteryCondition(status: .normal, source: .macOS, maximumCapacityPercent: 91))
    }

    @Test func macServiceFromMacOS() {
        // macOS says service even though our own math would say normal.
        let c = BatteryCondition.mac(.sampleOnHold, reported: MacReportedHealth(health: "Check Battery", maximumCapacityPercent: nil))
        #expect(c?.status == .serviceRecommended)
        #expect(c?.source == .macOS)
        #expect(c?.maximumCapacityPercent == 91) // 5,748 of 6,249 mAh
    }

    @Test func macEstimatesWithoutReport() {
        #expect(BatteryCondition.mac(.sampleOnHold, reported: nil)?.source == .estimated)
        #expect(BatteryCondition.mac(.sampleWorn, reported: nil)?.status == .serviceRecommended)
        // A report without a condition is no verdict.
        #expect(BatteryCondition.mac(.sampleWorn, reported: MacReportedHealth(health: nil, maximumCapacityPercent: 77))?
            .source == .estimated)
    }

    @Test func macPermanentFailureFromGauge() {
        var s = BatterySnapshot.sampleOnHold
        s.permanentFailureStatus = 4
        let c = BatteryCondition.mac(s, reported: .sampleGood)
        #expect(c?.status == .serviceRecommended)
        #expect(c?.permanentFailure == true)
    }

    @Test func parserReadsPermanentFailure() {
        let s = BatteryParser.parse(["CurrentCapacity": 50, "PermanentFailureStatus": 0])
        #expect(s.permanentFailureStatus == 0)
    }

    // MARK: system_profiler

    /// Shape of `system_profiler SPPowerDataType -json` on a MacBook Pro (trimmed, no serial).
    static let profilerJSON = """
    {"SPPowerDataType":[{"_name":"spbattery_information",
      "sppower_battery_charge_info":{"sppower_battery_state_of_charge":80},
      "sppower_battery_health_info":{"sppower_battery_cycle_count":183,"sppower_battery_health":"Good",
        "sppower_battery_health_maximum_capacity":"91%"}},
      {"_name":"sppower_information"}]}
    """

    @Test func parsesSystemProfiler() {
        let r = MacReportedHealth.parse(systemProfilerJSON: Data(Self.profilerJSON.utf8))
        #expect(r == MacReportedHealth(health: "Good", maximumCapacityPercent: 91))
        #expect(r?.status == .normal)
    }

    @Test func systemProfilerWithoutBattery() {
        let json = #"{"SPPowerDataType":[{"_name":"sppower_information"}]}"#
        #expect(MacReportedHealth.parse(systemProfilerJSON: Data(json.utf8)) == nil)
        #expect(MacReportedHealth.parse(systemProfilerJSON: Data("not json".utf8)) == nil)
    }

    @Test(arguments: [("Good", BatteryCondition.Status?.some(.normal)), ("Normal", .normal), ("Fair", .serviceRecommended),
                      ("Service Recommended", .serviceRecommended), ("Check Battery", .serviceRecommended),
                      ("", nil)])
    func healthStrings(_ health: String, _ status: BatteryCondition.Status?) {
        #expect(MacReportedHealth(health: health, maximumCapacityPercent: nil).status == status)
    }

    // MARK: iPhone / iPad

    @Test func deviceConditionFromRegistry() {
        // Real field shape from an iPhone 14 Plus over Wi-Fi sync (values from the device).
        let registry: [String: Any] = [
            "AppleRawMaxCapacity": 3353, "DesignCapacity": 4325, "NominalChargeCapacity": 3213, "CycleCount": 746,
            "BatteryShutdownReason": ["ShutDownTimestamp": 0, "ShutDownUpoReboot": 0],
        ]
        let d = MobileBatteryParser.parse(id: "x", lockdown: ["DeviceClass": "iPhone", "ProductType": "iPhone14,8"],
                                          battery: [:], registry: registry, connection: .wifi)
        #expect(d.nominalChargeCapacityMAh == 3213)
        #expect(d.unexpectedShutdownRecorded == false)
        let c = BatteryCondition.device(d)
        #expect(c?.maximumCapacityPercent == 74)
        #expect(c?.status == .serviceRecommended)
        #expect(c?.peakPerformance == .worn)
        #expect(c?.source == .estimated)
    }

    @Test func unexpectedShutdownRecord() {
        #expect(MobileBatteryParser.unexpectedShutdown(["ShutDownTimestamp": 1794545882, "ShutDownUpoReboot": 0]) == true)
        #expect(MobileBatteryParser.unexpectedShutdown(["ShutDownTimestamp": 0, "ShutDownUpoReboot": 1]) == true)
        #expect(MobileBatteryParser.unexpectedShutdown(["ShutDownTimestamp": 0, "ShutDownUpoReboot": 0]) == false)
        #expect(MobileBatteryParser.unexpectedShutdown(nil) == nil)
    }

    @Test func noConditionForHotspotOrAccessories() {
        #expect(BatteryCondition.device(.sampleNearbyIPhone) == nil)
        #expect(BatteryCondition.device(.sampleMouse) == nil)
        #expect(BatteryCondition.device(.sampleIPadUntrusted) == nil)
    }

    @Test func iPadHasNoPeakPerformance() {
        var d = DeviceBattery.sampleIPhone
        d.kind = .iPad
        #expect(BatteryCondition.device(d)?.peakPerformance == nil)
        #expect(BatteryCondition.device(.sampleIPhone)?.peakPerformance == .normal)
    }

    @Test func rememberedReadingWithoutNewFieldsDecodes() throws {
        // A last-exact file written before F11 has no nominal / shutdown keys.
        let json = #"{"id":"a","name":"P","kind":"iPhone","percent":80,"isCharging":false,"externalConnected":false,"parts":[],"isApproximate":false,"isLastKnown":true}"#
        let d = try JSONDecoder().decode(DeviceBattery.self, from: Data(json.utf8))
        #expect(d.nominalChargeCapacityMAh == nil)
        #expect(d.unexpectedShutdownRecorded == nil)
    }

    // MARK: Rated cycles

    @Test(arguments: [
        ("iPhone14,8", DeviceBattery.Kind.iPhone, Int?.some(500)), // 14 Plus
        ("iPhone15,3", .iPhone, 500),   // 14 Pro Max
        ("iPhone15,4", .iPhone, 1000),  // 15
        ("iPhone16,1", .iPhone, 1000),  // 15 Pro
        ("iPhone18,1", .iPhone, 1000),
        ("iPad16,3", .iPad, 1000),
        ("Watch7,1", .watch, nil),
        ("garbage", .iPhone, nil),
    ])
    func ratedCycles(_ model: String, _ kind: DeviceBattery.Kind, _ rated: Int?) {
        #expect(BatteryCondition.ratedCycles(kind: kind, model: model) == rated)
    }

    @Test func gaugeDesignCountWins() {
        #expect(BatteryCondition.ratedCycles(kind: nil, model: nil, designCycleCount: 1000) == 1000)
        #expect(BatteryCondition.ratedCycles(kind: .iPhone, model: "iPhone14,8", designCycleCount: 0) == 500)
    }
}
