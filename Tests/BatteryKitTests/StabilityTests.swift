import Foundation
import Testing

@testable import BatteryKit

/// Regression tests for failure modes that used to lose data, hang or trap.
@Suite("Stability")
struct StabilityTests {
    private static func files(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: Corrupt store files are set aside, never overwritten

    @Test func corruptHistoryIsKeptAsideNotOverwritten() throws {
        let tmp = try TempDir()
        let file = tmp.historyFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("[{\"date\": 12, half a file".utf8)
        try garbage.write(to: file)

        let store = HistoryStore(fileURL: file, calendar: utcCalendar)
        #expect(store.samples.isEmpty)
        #expect(store.isWritable)
        let dir = file.deletingLastPathComponent()
        let aside = try Self.files(in: dir).filter { $0.hasPrefix("history.corrupt-") && $0.hasSuffix(".json") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(aside[0])) == garbage)

        // Recording starts a fresh file; the old bytes stay in the corrupt copy.
        try store.record(HistorySample(date: utcDate(2026, 11, 17, 9), healthPercent: 91, cycleCount: 200))
        #expect(HistoryStore(fileURL: file, calendar: utcCalendar).samples.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(aside[0])) == garbage)
    }

    @Test func goodHistoryIsNotSetAside() throws {
        let tmp = try TempDir()
        let store = HistoryStore(fileURL: tmp.historyFile, calendar: utcCalendar)
        try store.record(HistorySample(date: utcDate(2026, 11, 17, 9), healthPercent: 91, cycleCount: 200))
        let reloaded = HistoryStore(fileURL: tmp.historyFile, calendar: utcCalendar)
        #expect(reloaded.samples.count == 1)
        #expect(try Self.files(in: tmp.historyFile.deletingLastPathComponent()) == ["history.json"])
    }

    @Test func setAsideReportsFailure() throws {
        let tmp = try TempDir()
        #expect(StoreFile.setAside(tmp.url.appendingPathComponent("missing.json")) == nil)
        #expect(StoreFile.read(tmp.url.appendingPathComponent("missing.json")) == nil)
    }

    @Test func corruptLastExactFileIsKeptAside() throws {
        let tmp = try TempDir()
        let url = tmp.url.appendingPathComponent("last.json")
        try Data("{\"devices\": 3}".utf8).write(to: url)
        let store = LastExactReadingStore(fileURL: url)
        #expect(store.devices.isEmpty)
        #expect(try Self.files(in: tmp.url).contains { $0.hasPrefix("last.corrupt-") })
    }

    @Test func readOnlyLastExactStoreNeverWrites() throws {
        let tmp = try TempDir()
        let url = tmp.url.appendingPathComponent("last.json")
        // Corrupt: a read-only store leaves it exactly where it is.
        try Data("nope".utf8).write(to: url)
        let reader = LastExactReadingStore(fileURL: url, readOnly: true)
        #expect(reader.isReadOnly)
        #expect(reader.devices.isEmpty)
        #expect(try Self.files(in: tmp.url) == ["last.json"])
        // Remember / flush are no-ops on disk.
        #expect(try !reader.remember([.sampleIPhone]))
        try reader.flush()
        #expect(try Data(contentsOf: url) == Data("nope".utf8))
    }

    @Test func readOnlyLastExactStoreDoesNotPruneExpired() throws {
        let tmp = try TempDir()
        let url = tmp.url.appendingPathComponent("last.json")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var phone = DeviceBattery.sampleIPhone
        phone.updatedAt = t0
        let writer = LastExactReadingStore(fileURL: url, now: t0)
        #expect(try writer.remember([phone], now: t0))
        let before = try Data(contentsOf: url)
        let later = t0.addingTimeInterval(LastExactReadingStore.maxAge + 60)
        #expect(LastExactReadingStore(fileURL: url, now: later, readOnly: true).devices(now: later).isEmpty)
        #expect(try Data(contentsOf: url) == before)
    }

    // MARK: Subprocess deadline

    @Test func subprocessReturnsOutputAndStatus() throws {
        let ok = try #require(Subprocess.run("/bin/echo", ["hello"]))
        #expect(ok.succeeded)
        #expect(ok.text == "hello\n")
        let fail = try #require(Subprocess.run("/usr/bin/false", []))
        #expect(!fail.succeeded)
        #expect(Subprocess.run("/nonexistent/tool", []) == nil)
    }

    @Test func subprocessGivesUpAtTheDeadline() {
        let start = Date()
        #expect(Subprocess.run("/bin/sleep", ["5"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func subprocessDrainsLargeOutput() throws {
        // More than a pipe buffer (64 KB): must not deadlock.
        let result = try #require(Subprocess.run("/bin/sh", ["-c", "head -c 300000 /dev/zero"], timeout: 10))
        #expect(result.output.count == 300_000)
    }

    @Test func energyModeRunUsesDeadline() {
        #expect(EnergyModeControl.run(["hi"], executable: "/bin/echo") == "hi\n")
        #expect(EnergyModeControl.run(["5"], executable: "/bin/sleep", timeout: 0.3) == nil)
    }

    // MARK: Arithmetic on garbage values

    @Test func hugeCapacityDoesNotTrap() {
        #expect(BatteryCondition.maximumCapacityPercent(nominalMAh: Int.max, fullMAh: nil, designMAh: 5000) == 100)
        #expect(BatteryCondition.maximumCapacityPercent(nominalMAh: Int.max / 50, fullMAh: nil, designMAh: 6000) == 100)
        #expect(BatteryCondition.maximumCapacityPercent(nominalMAh: 5744, fullMAh: nil, designMAh: 6249) == 91)
    }

    @Test func hugeAccessoryLevelDoesNotTrap() {
        let source: [String: Any] = ["Name": "Mouse", "Current Capacity": Int.max, "Max Capacity": 1]
        #expect(AccessoryParser.parse([source]).first?.percent == 100)
    }

    // MARK: Identity and change detection

    @Test func anonymousAccessoriesKeepTheirIds() {
        let anonymous: [String: Any] = ["Current Capacity": 50, "Max Capacity": 100]
        let first = AccessoryParser.parse([anonymous, anonymous]).map(\.id)
        let second = AccessoryParser.parse([anonymous, anonymous]).map(\.id)
        #expect(first == ["accessory-0", "accessory-1"])
        #expect(first == second)
    }

    @Test func snapshotSameReadingIgnoresTimestamp() {
        var a = BatterySnapshot.sampleCharging
        var b = a
        b.timestamp = a.timestamp.addingTimeInterval(2)
        #expect(a.sameReading(as: b))
        #expect(a != b)
        #expect(!a.sameReading(as: nil))
        a.chargePercent += 1
        #expect(!a.sameReading(as: b))
    }
}
