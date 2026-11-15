import Foundation
import Testing

@testable import BatteryKit

/// Each test gets its own temp directory, removed afterwards.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    var historyFile: URL { url.appendingPathComponent("nested/dir/history.json") }
}

@Suite("HistoryStore")
struct HistoryStoreTests {
    let tmp: TempDir
    init() throws { tmp = try TempDir() }

    func store() -> HistoryStore { HistoryStore(fileURL: tmp.historyFile, calendar: utcCalendar) }

    @Test func missingFileLoadsEmpty() {
        #expect(store().samples.isEmpty)
    }

    @Test func corruptFileLoadsEmpty() throws {
        try FileManager.default.createDirectory(
            at: tmp.historyFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: tmp.historyFile)
        #expect(store().samples.isEmpty)
    }

    @Test func oneSamplePerDayLatestWins() throws {
        let s = store()
        let morning = HistorySample(date: utcDate(2025, 11, 3, 8), healthPercent: 90, cycleCount: 100)
        let evening = HistorySample(date: utcDate(2025, 11, 3, 20), healthPercent: 89.9, cycleCount: 101)
        #expect(try s.record(morning))
        #expect(try s.record(evening))
        #expect(s.samples == [evening])
        #expect(try s.record(evening) == false, "identical sample is a no-op")
    }

    @Test func samplesStaySorted() throws {
        let s = store()
        let d3 = HistorySample(date: utcDate(2025, 11, 3), healthPercent: 90, cycleCount: 100)
        let d1 = HistorySample(date: utcDate(2025, 11, 1), healthPercent: 91, cycleCount: 98)
        let d2 = HistorySample(date: utcDate(2025, 11, 2), healthPercent: 90.5, cycleCount: 99)
        try s.record(d3)
        try s.record(d1)
        try s.record(d2)
        #expect(s.samples == [d1, d2, d3])
    }

    @Test func persistenceRoundTrip() throws {
        let s = store()
        let a = HistorySample(
            date: utcDate(2025, 10, 30), healthPercent: 91.25, cycleCount: 97,
            fullChargeCapacityMAh: 5700, designCapacityMAh: 6249)
        let b = HistorySample(date: utcDate(2025, 11, 2), healthPercent: 90.5, cycleCount: 99)
        try s.record(b)
        try s.record(a)
        #expect(FileManager.default.fileExists(atPath: tmp.historyFile.path))

        let reloaded = store()
        #expect(reloaded.samples == [a, b])

        // Reloading and recording into the same day replaces, not appends.
        let b2 = HistorySample(date: utcDate(2025, 11, 2, 23), healthPercent: 90.4, cycleCount: 100)
        try reloaded.record(b2)
        #expect(store().samples == [a, b2])
    }

    @Test func fileIsISO8601JSON() throws {
        try store().record(HistorySample(date: utcDate(2025, 11, 3), healthPercent: 90, cycleCount: 100))
        let text = try String(contentsOf: tmp.historyFile, encoding: .utf8)
        #expect(text.contains("\"2025-11-03T12:00:00Z\""))
        #expect(text.contains("\"healthPercent\""))
    }
}

@Suite("HistoryAggregator")
struct HistoryAggregatorTests {
    let samples = [
        HistorySample(date: utcDate(2025, 12, 1), healthPercent: 88, cycleCount: 120),
        HistorySample(date: utcDate(2025, 11, 1), healthPercent: 90, cycleCount: 100),
        HistorySample(date: utcDate(2025, 11, 20), healthPercent: 92, cycleCount: 110),
        HistorySample(date: utcDate(2026, 1, 5), healthPercent: 87, cycleCount: 130),
        HistorySample(date: utcDate(2025, 10, 31, 23, 59), healthPercent: 93, cycleCount: 95),
    ]

    @Test func monthlyGroupsAveragesAndOrders() {
        let months = HistoryAggregator.monthly(samples, calendar: utcCalendar)
        #expect(months.map(\.period) == ["2025-10", "2025-11", "2025-12", "2026-01"])
        let nov = months[1]
        #expect(nov.averageHealthPercent == 91)
        #expect(nov.maxCycleCount == 110)
        #expect(nov.sampleCount == 2)
        #expect(months[0].sampleCount == 1)
        #expect(months[3].maxCycleCount == 130)
    }

    @Test func monthlyEmpty() {
        #expect(HistoryAggregator.monthly([]).isEmpty)
    }

    @Test func monthlySampleSeries() {
        let series = HistorySample.sampleSeries(endingAt: utcDate(2025, 11, 15), months: 22)
        let months = HistoryAggregator.monthly(series, calendar: utcCalendar)
        #expect(months.count == 22)
        #expect(months.first?.period == "2024-02")
        #expect(months.last?.period == "2025-11")
        #expect(months.map(\.period) == months.map(\.period).sorted())
    }

    @Test func csvHeaderAndRows() {
        let csv = HistoryAggregator.csv([
            HistorySample(date: utcDate(2025, 11, 2), healthPercent: 90.46, cycleCount: 99),
            HistorySample(
                date: utcDate(2025, 11, 1), healthPercent: 91.25, cycleCount: 98,
                fullChargeCapacityMAh: 5700, designCapacityMAh: 6249),
        ])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(
            lines == [
                "date,health_percent,cycle_count,full_charge_mah,design_mah",
                "2025-11-01,91.2,98,5700,6249",
                "2025-11-02,90.5,99,,",
                "",
            ])
    }

    @Test func csvEmptyIsHeaderOnly() {
        #expect(HistoryAggregator.csv([]) == "date,health_percent,cycle_count,full_charge_mah,design_mah\n")
    }

    /// The store groups samples by the user's local day, so the CSV must print that same day —
    /// not the UTC date (which differs for e.g. 00:30 in UTC+7).
    @Test func csvUsesLocalCalendarDay() throws {
        let local = Calendar.current
        let earlyMorning = try #require(
            local.date(from: DateComponents(year: 2025, month: 11, day: 3, hour: 0, minute: 30)))
        let lateNight = try #require(
            local.date(from: DateComponents(year: 2025, month: 11, day: 4, hour: 23, minute: 30)))
        let csv = HistoryAggregator.csv([
            HistorySample(date: earlyMorning, healthPercent: 90, cycleCount: 1),
            HistorySample(date: lateNight, healthPercent: 90, cycleCount: 2),
        ])
        #expect(csv.contains("\n2025-11-03,90.0,1,,\n"))
        #expect(csv.contains("\n2025-11-04,90.0,2,,\n"))
    }
}
