import Foundation
import Testing
@testable import BatteryKit

private func sample(_ d: Int, _ h: Int, _ m: Int = 0, _ p: Double, charging: Bool? = false,
                    approx: Bool = false) -> ChargeSample {
    ChargeSample(date: utcDate(2026, 11, d, h, m), percent: p, isCharging: approx ? nil : charging, isApproximate: approx)
}

@Suite("ChargeLog recording")
struct ChargeLogRecordTests {
    @Test func identicalConsecutiveReadingsExtendOneRun() {
        var log = ChargeLog(id: "mac", name: "Mac")
        #expect(log.record(sample(15, 9, 0, 80)) == .appended)
        #expect(log.record(sample(15, 9, 5, 80)) == .extended)
        #expect(log.record(sample(15, 9, 10, 80)) == .extended)
        #expect(log.samples.count == 1)
        #expect(log.samples[0].until == utcDate(2026, 11, 15, 9, 10))
        #expect(log.record(sample(15, 9, 15, 79)) == .appended)
        #expect(log.samples.count == 2)
    }

    @Test func chargingFlagChangeIsANewSample() {
        var log = ChargeLog(id: "mac", name: "Mac")
        log.record(sample(15, 9, 0, 80, charging: false))
        #expect(log.record(sample(15, 9, 5, 80, charging: true)) == .appended)
    }

    @Test func outOfOrderReadingIsIgnored() {
        var log = ChargeLog(id: "mac", name: "Mac")
        log.record(sample(15, 10, 0, 80))
        #expect(log.record(sample(15, 9, 0, 85)) == .ignored)
        #expect(log.samples.count == 1)
    }

    @Test func sameReadingAfterLongGapStartsANewRun() {
        var log = ChargeLog(id: "mac", name: "Mac")
        log.record(sample(15, 9, 0, 80))
        #expect(log.record(sample(15, 12, 0, 80)) == .appended)
        #expect(log.samples.count == 2)
        #expect(log.samples[0].until == nil)
    }

    @Test func retentionKeepsEightDays() {
        var log = ChargeLog(id: "mac", name: "Mac")
        log.record(sample(5, 12, 0, 90))
        log.record(sample(7, 11, 0, 80))
        log.record(sample(7, 13, 0, 70))
        log.record(sample(15, 12, 0, 60))
        let pruned = log.prune(now: utcDate(2026, 11, 15, 12))
        #expect(pruned)
        // Nov 7 11:00 is 8 days + 1 h ago; 13:00 is inside the window.
        #expect(log.samples.map(\.percent) == [70, 60])
        let again = log.prune(now: utcDate(2026, 11, 15, 12))
        #expect(!again)
    }

    @Test func iPhoneCabledAndHotspotReadingsShareOneKey() throws {
        let cabled = DeviceBattery(id: "udid", name: "Peter’s iPhone", kind: .iPhone, connection: .usb,
                                   model: "iPhone14,8", percent: 91)
        let nearby = try #require(HotspotParser.parse(identifier: "x", name: "Peter’s iP", model: "iPhone14,8",
                                                      batteryLife: 75))
        #expect(ChargeLog.key(for: cabled) == ChargeLog.key(for: nearby))
        #expect(ChargeLog.key(for: cabled) == "ios|iPhone14,8|Peter’s iP")
        #expect(ChargeLog.key(for: .sampleMouse) == nil)
    }

    @Test func compactEncodingRoundTrips() throws {
        let s = ChargeSample(date: utcDate(2026, 11, 15, 9), until: utcDate(2026, 11, 15, 10), percent: 75,
                             isCharging: nil, isApproximate: true)
        let data = try ChargeLogStore.encoder.encode(s)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("\"c\""))
        #expect(json.contains("\"a\":true"))
        #expect(try ChargeLogStore.decoder.decode(ChargeSample.self, from: data) == s)
        let exact = try ChargeLogStore.encoder.encode(ChargeSample(date: utcDate(2026, 11, 15, 9), percent: 80, isCharging: true))
        #expect(!String(decoding: exact, as: UTF8.self).contains("\"a\""))
    }
}

@Suite("ChargeLogStore")
struct ChargeLogStoreTests {
    let tmp: TempDir
    init() throws { tmp = try TempDir() }
    var dir: URL { tmp.url.appendingPathComponent("charge-log") }

    @Test func appendWritesHashedFileAndReloads() throws {
        let store = ChargeLogStore(directory: dir)
        try store.record(key: "mac", name: "MacBook Pro", kind: nil, model: nil,
                         sample: sample(15, 9, 0, 80), now: utcDate(2026, 11, 15, 9))
        let file = store.fileURL(for: "mac")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(file.lastPathComponent.count == 16 + 5)
        #expect(!file.lastPathComponent.contains("mac"))
        let reloaded = ChargeLogStore(directory: dir)
        #expect(reloaded.logs["mac"] == store.logs["mac"])
    }

    @Test func runExtensionsAreBatchedUntilFlush() throws {
        let store = ChargeLogStore(directory: dir)
        let now = utcDate(2026, 11, 15, 9)
        try store.record(key: "mac", name: "Mac", kind: nil, model: nil, sample: sample(15, 9, 0, 80), now: now)
        #expect(try store.record(key: "mac", name: "Mac", kind: nil, model: nil,
                                 sample: sample(15, 9, 5, 80), now: now) == .extended)
        #expect(ChargeLogStore(directory: dir).logs["mac"]?.samples.first?.until == nil)
        store.flush()
        #expect(ChargeLogStore(directory: dir).logs["mac"]?.samples.first?.until == utcDate(2026, 11, 15, 9, 5))
    }

    @Test func approximateSamplesAreNotLogged() throws {
        let store = ChargeLogStore(directory: dir)
        let key = "ios|iPhone14,8|Peter’s iP"
        #expect(try store.record(key: key, name: "Peter’s iP…", kind: .iPhone, model: "iPhone14,8",
                                 sample: sample(15, 9, 0, 75, approx: true), now: utcDate(2026, 11, 15, 9)) == .ignored)
        #expect(store.logs[key] == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: key).path))
        try store.record(key: key, name: "Peter’s iPhone", kind: .iPhone, model: "iPhone14,8",
                         sample: sample(15, 10, 0, 91, charging: true), now: utcDate(2026, 11, 15, 10))
        #expect(store.logs[key]?.name == "Peter’s iPhone")
        #expect(store.logs[key]?.samples.count == 1)
    }

    @Test func loadPrunesApproximateSamplesFromOlderBuilds() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mixedKey = "ios|iPhone14,8|Peter’s iP", hotspotKey = "ios|iPhone12,1|Kid"
        let mixed = ChargeLog(id: mixedKey, name: "Peter’s iP", kind: .iPhone, model: "iPhone14,8",
                              samples: [sample(15, 9, 0, 75, approx: true), sample(15, 10, 0, 91, charging: true)])
        let hotspotOnly = ChargeLog(id: hotspotKey, name: "Kid", kind: .iPhone, model: "iPhone12,1",
                                    samples: [sample(15, 9, 0, 40, approx: true)])
        let writer = ChargeLogStore(directory: dir)
        try ChargeLogStore.encoder.encode(mixed).write(to: writer.fileURL(for: mixedKey))
        try ChargeLogStore.encoder.encode(hotspotOnly).write(to: writer.fileURL(for: hotspotKey))

        let store = ChargeLogStore(directory: dir)
        #expect(store.logs[mixedKey]?.samples.map(\.percent) == [91])
        #expect(store.logs[hotspotKey] == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: hotspotKey).path))
        // Pruned on disk too.
        let data = try Data(contentsOf: store.fileURL(for: mixedKey))
        #expect(try ChargeLogStore.decoder.decode(ChargeLog.self, from: data).samples.count == 1)
    }
}

@Suite("Charge usage analysis")
struct ChargeAnalysisTests {
    @Test func sumsDropsAndIgnoresRises() {
        let samples = [sample(15, 9, 0, 100), sample(15, 10, 0, 90),
                       sample(15, 11, 0, 95, charging: true), sample(15, 12, 0, 80)]
        let u = ChargeAnalysis.usage(samples, from: utcDate(2026, 11, 15, 0), to: utcDate(2026, 11, 16, 0))
        #expect(u.used == 25)
        #expect(u.covered == 3 * 3600)
    }

    @Test func gapsLongerThanTwoHoursAreUnknown() {
        let samples = [sample(15, 9, 0, 100), sample(15, 12, 0, 70), sample(15, 13, 0, 60)]
        let u = ChargeAnalysis.usage(samples, from: utcDate(2026, 11, 15, 0), to: utcDate(2026, 11, 16, 0))
        #expect(u.used == 10)
        #expect(u.covered == 3600)
    }

    @Test func runsCountAsCoveredWithNoUse() {
        let samples = [ChargeSample(date: utcDate(2026, 11, 15, 8), until: utcDate(2026, 11, 15, 11), percent: 100),
                       sample(15, 11, 30, 95)]
        let u = ChargeAnalysis.usage(samples, from: utcDate(2026, 11, 15, 0), to: utcDate(2026, 11, 16, 0))
        #expect(u.used == 5)
        #expect(u.covered == 3.5 * 3600)
    }

    @Test func dropIsSplitAcrossTheCutoff() {
        let samples = [sample(15, 11, 0, 100), sample(15, 13, 0, 90)]
        let u = ChargeAnalysis.usage(samples, from: utcDate(2026, 11, 15, 0), to: utcDate(2026, 11, 15, 12))
        #expect(u.used == 5)
        #expect(u.covered == 3600)
    }

    @Test func approximateSamplesAreIgnored() {
        // The hotspot levels (75, 73) would add a 16-point "drop"; only 91 → 90 is real.
        let samples = [sample(15, 9, 0, 91, charging: true), sample(15, 9, 30, 75, approx: true),
                       sample(15, 10, 0, 73, approx: true), sample(15, 10, 30, 90, charging: false)]
        let u = ChargeAnalysis.usage(samples, from: utcDate(2026, 11, 15, 0), to: utcDate(2026, 11, 16, 0))
        #expect(u.used == 1)
        #expect(u.covered == 1.5 * 3600)
    }

    /// Each past day: 100 → 80 by 11:00, → 60 by 17:00; today: 100 → 90 by 11:00.
    static func week(today todayUse: Double = 10, pastDays: Int = 7) -> [ChargeSample] {
        var out: [ChargeSample] = []
        for d in (15 - pastDays)..<15 {
            out += [sample(d, 9, 0, 100), sample(d, 11, 0, 80), sample(d, 13, 0, 80), sample(d, 15, 0, 70),
                    sample(d, 17, 0, 60)]
        }
        out += [sample(15, 9, 0, 100), sample(15, 11, 0, 100 - todayUse)]
        return out
    }

    @Test func averagesAndByTimeOfDay() throws {
        let s = ChargeAnalysis.summary(Self.week(), now: utcDate(2026, 11, 15, 12), calendar: utcCalendar)
        #expect(s.days.count == 8)
        #expect(s.days.last?.isToday == true)
        #expect(s.days.first?.start == utcDate(2026, 11, 8, 0))
        let past = try #require(s.days.first)
        #expect(past.usedAllDay == 40)
        #expect(past.usedByCutoff == 20)
        #expect(s.today?.usedByCutoff == 10)
        #expect(s.averageAllDay == 40)
        #expect(s.averageByCutoff == 20)
        #expect(s.daysWithData == 7)
        #expect(s.comparison == .less)
    }

    @Test func dayWithoutEnoughCoverageIsLeftOut() {
        // Nov 10: a single 30-minute stretch only.
        var samples = Self.week().filter { !(utcCalendar.isDate($0.date, inSameDayAs: utcDate(2026, 11, 10))) }
        samples += [sample(10, 9, 0, 100), sample(10, 9, 30, 50)]
        samples.sort { $0.date < $1.date }
        let s = ChargeAnalysis.summary(samples, now: utcDate(2026, 11, 15, 12), calendar: utcCalendar)
        #expect(s.daysWithData == 6)
        #expect(s.averageAllDay == 40)
    }

    @Test func needsThreeDaysToCompare() {
        let s = ChargeAnalysis.summary(Self.week(pastDays: 2), now: utcDate(2026, 11, 15, 12), calendar: utcCalendar)
        #expect(s.daysWithData == 2)
        #expect(s.averageByCutoff == nil)
        #expect(s.comparison == .notEnoughData)
        #expect(ChargeAnalysis.sentence(s.comparison, time: "12:00") == "Battery Buddy needs a few days of data to compare.")
        let three = ChargeAnalysis.summary(Self.week(pastDays: 3), now: utcDate(2026, 11, 15, 12), calendar: utcCalendar)
        #expect(three.comparison == .less)
    }

    @Test func todayWithoutReadingsDoesNotCompare() {
        let samples = Self.week().filter { !utcCalendar.isDate($0.date, inSameDayAs: utcDate(2026, 11, 15)) }
        let s = ChargeAnalysis.summary(samples, now: utcDate(2026, 11, 15, 12), calendar: utcCalendar)
        #expect(s.averageByCutoff == 20)
        #expect(s.comparison == .notEnoughData)
    }

    @Test func comparisonThresholds() {
        // ±15 % of 20 = ±3.
        #expect(ChargeAnalysis.compare(today: 16.9, average: 20) == .less)
        #expect(ChargeAnalysis.compare(today: 17.1, average: 20) == .aboutTheSame)
        #expect(ChargeAnalysis.compare(today: 22.9, average: 20) == .aboutTheSame)
        #expect(ChargeAnalysis.compare(today: 23.1, average: 20) == .more)
        // Small averages: at least ±1 point.
        #expect(ChargeAnalysis.compare(today: 2.9, average: 2) == .aboutTheSame)
        #expect(ChargeAnalysis.compare(today: 3.1, average: 2) == .more)
        #expect(ChargeAnalysis.compare(today: 0, average: 0) == .aboutTheSame)
    }

    @Test func sentences() {
        #expect(ChargeAnalysis.sentence(.less, time: "12:07") == "You’re using less battery today than you usually do by 12:07.")
        #expect(ChargeAnalysis.sentence(.more, time: "12:07") == "You’re using more battery today than you usually do by 12:07.")
        #expect(ChargeAnalysis.sentence(.aboutTheSame, time: "12:07") == "You’re using about as much battery today as you usually do by 12:07.")
    }

    @Test func summaryIgnoresApproximateSamples() {
        let now = utcDate(2026, 11, 15, 12)
        let hotspotOnly = [sample(15, 9, 0, 80, approx: true), sample(15, 9, 30, 78, approx: true)]
        let s = ChargeAnalysis.summary(hotspotOnly, now: now, calendar: utcCalendar)
        #expect(!s.hasAnyData)
        #expect(s.today?.usedByCutoff == 0)
        // Hotspot levels mixed into an exact week change nothing: days, averages, sentence.
        let exact = Self.week()
        var mixed = exact
        for d in 8...15 { mixed.append(sample(d, 10, 30, 40, approx: true)) }
        mixed.sort { $0.date < $1.date }
        #expect(ChargeAnalysis.summary(mixed, now: now, calendar: utcCalendar)
                == ChargeAnalysis.summary(exact, now: now, calendar: utcCalendar))
    }

    @Test func syntheticWeeksCompareLikeTheReference() {
        let now = ChargeLog.sampleNow
        let mac = ChargeAnalysis.summary(ChargeLog.sampleMacWeek(now: now).samples, now: now)
        #expect(mac.daysWithData == 7)
        #expect(mac.comparison == .less)
        let phone = ChargeAnalysis.summary(ChargeLog.sampleIPhoneWeek(now: now).samples, now: now)
        #expect(phone.daysWithData == 7)
        #expect(ChargeLog.sampleIPhoneWeek(now: now).samples.allSatisfy { !$0.isApproximate })
        let old = ChargeAnalysis.summary(ChargeLog.sampleApproximateIPhoneWeek(now: now).samples, now: now)
        #expect(!old.hasAnyData)
    }
}

@Suite("Approximate nearby level")
struct ApproximateLevelTests {
    @Test func hotspotReadingsAreApproximateWithTheLagNote() throws {
        let d = try #require(HotspotParser.parse(identifier: "x", name: "Peter’s iP", model: "iPhone14,8", batteryLife: 75))
        #expect(d.isApproximate)
        #expect(d.isCharging == false)
        #expect(d.note == "Last level the iPhone shared over Personal Hotspot. It can lag well behind the phone.")
        let pad = try #require(HotspotParser.parse(identifier: "y", name: "iPad", model: "iPad16,3", batteryLife: 50))
        #expect(pad.note == "Last level the iPad shared over Personal Hotspot. It can lag well behind the iPad.")
    }

    @Test func cabledAndAccessoryReadingsAreExact() {
        let d = MobileBatteryParser.parse(id: "u", lockdown: ["DeviceClass": "iPhone"],
                                          battery: ["BatteryCurrentCapacity": 91, "BatteryIsCharging": true],
                                          registry: nil, connection: .wifi)
        #expect(!d.isApproximate)
        #expect(!DeviceBattery.sampleMouse.isApproximate)
    }

    @Test func exactReadWinsAndNearbyStaysApproximate() throws {
        let nearby = try #require(HotspotParser.parse(identifier: "n", name: "Peter’s iP", model: "iPhone14,8", batteryLife: 75))
        let other = try #require(HotspotParser.parse(identifier: "o", name: "Kid", model: "iPhone12,1", batteryLife: 40))
        let cabled = DeviceBattery(id: "u", name: "Peter’s iPhone", kind: .iPhone, connection: .wifi,
                                   model: "iPhone14,8", percent: 91, isCharging: true)
        let merged = HotspotParser.merge(connected: [cabled], nearby: [nearby, other])
        #expect(merged.map(\.percent) == [91, 40])
        #expect(merged.map(\.isApproximate) == [false, true])
        #expect(merged[0].isCharging)
        #expect(HotspotParser.merge(connected: [], nearby: [nearby]).first?.isApproximate == true)
    }

    @Test func hotspotUpdatedAtIsFirstSeenOfTheCurrentValue() throws {
        let t0 = utcDate(2026, 11, 15, 12, 3), t1 = utcDate(2026, 11, 15, 12, 10)
        let first = try #require(HotspotParser.parse(identifier: "n", name: "Peter’s iP", model: "iPhone14,8", batteryLife: 75))
        let stamped = HotspotParser.carryUpdatedAt(previous: [], current: [first], now: t0)
        #expect(stamped.first?.updatedAt == t0)
        let same = HotspotParser.carryUpdatedAt(previous: stamped, current: [first], now: t1)
        #expect(same.first?.updatedAt == t0)
        var changed = first
        changed.percent = 80
        #expect(HotspotParser.carryUpdatedAt(previous: same, current: [changed], now: t1).first?.updatedAt == t1)
    }

    @Test func onlyExactReadingsAreLogged() throws {
        let t = utcDate(2026, 11, 15, 12)
        let hotspot = try #require(HotspotParser.parse(identifier: "n", name: "Peter’s iP", model: "iPhone14,8", batteryLife: 75))
        #expect(ChargeLog.exactSample(for: hotspot, at: t) == nil)
        let wifi = DeviceBattery(id: "u", name: "Peter’s iP", kind: .iPhone, connection: .wifi,
                                 model: "iPhone14,8", percent: 91, isCharging: true, updatedAt: t)
        let entry = try #require(ChargeLog.exactSample(for: wifi, at: t))
        #expect(entry.key == "ios|iPhone14,8|Peter’s iP")
        #expect(entry.sample == ChargeSample(date: t, percent: 91, isCharging: true))
        // A remembered reading is old data, not a new reading; untrusted devices have no level.
        #expect(ChargeLog.exactSample(for: wifi.lastKnown, at: t) == nil)
        #expect(ChargeLog.exactSample(for: .sampleIPadUntrusted, at: t) == nil)
        #expect(ChargeLog.exactSample(for: .sampleMouse, at: t) == nil)
    }

    @Test func advertisedStemCutsAtTwelveBytes() {
        #expect(HotspotParser.advertisedStem("Peter’s iPhone") == "Peter’s iP")
        #expect(HotspotParser.advertisedStem("Peter’s iP…") == "Peter’s iP")
        #expect(HotspotParser.advertisedStem("iPad") == "iPad")
    }
}
