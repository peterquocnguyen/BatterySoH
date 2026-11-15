import CryptoKit
import Foundation

// F11 Insights: per-device charge samples and the pure "battery used per day" analysis.

/// One charge reading, or a run of identical consecutive readings (`date` … `until`).
public struct ChargeSample: Codable, Equatable, Sendable {
    public var date: Date
    /// Last time the same reading was seen again; nil for a single reading.
    public var until: Date?
    /// 0–100, what the device shows.
    public var percent: Double
    /// nil when the source doesn't say.
    public var isCharging: Bool?
    /// Advertised level (Instant Hotspot), not a live read. No longer recorded: older builds
    /// logged these, so they can still be on disk; `ChargeLogStore.load` drops them and the
    /// analysis ignores them.
    public var isApproximate: Bool

    /// End of the run (the last time this reading was seen).
    public var end: Date { until ?? date }

    public init(date: Date, until: Date? = nil, percent: Double, isCharging: Bool? = nil, isApproximate: Bool = false) {
        self.date = date
        self.until = until
        self.percent = percent
        self.isCharging = isCharging
        self.isApproximate = isApproximate
    }

    /// Same reading, ignoring time.
    func sameReading(as other: ChargeSample) -> Bool {
        percent == other.percent && isCharging == other.isCharging && isApproximate == other.isApproximate
    }

    // Short keys and omitted defaults keep a week of 5-minute samples small on disk.
    enum CodingKeys: String, CodingKey { case date = "d", until = "u", percent = "p", isCharging = "c", isApproximate = "a" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        until = try c.decodeIfPresent(Date.self, forKey: .until)
        percent = try c.decode(Double.self, forKey: .percent)
        isCharging = try c.decodeIfPresent(Bool.self, forKey: .isCharging)
        isApproximate = try c.decodeIfPresent(Bool.self, forKey: .isApproximate) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(until, forKey: .until)
        try c.encode(percent, forKey: .percent)
        try c.encodeIfPresent(isCharging, forKey: .isCharging)
        if isApproximate { try c.encode(true, forKey: .isApproximate) }
    }
}

/// The charge log of one device: This Mac, or an iPhone / iPad.
public struct ChargeLog: Codable, Equatable, Sendable, Identifiable {
    /// Log key (`ChargeLog.thisMacID` or `ChargeLog.key(for:)`).
    public var id: String
    public var name: String
    /// nil for This Mac.
    public var kind: DeviceBattery.Kind?
    public var model: String?
    /// Oldest first.
    public var samples: [ChargeSample]

    /// Samples older than this are dropped (7 full days to compare + today).
    public static let retention: TimeInterval = 8 * 86_400
    public static let thisMacID = "mac"

    public var isThisMac: Bool { id == Self.thisMacID }

    public init(id: String, name: String, kind: DeviceBattery.Kind? = nil, model: String? = nil, samples: [ChargeSample] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.model = model
        self.samples = samples
    }

    /// Log key for an iPhone / iPad: model plus the advertised name stem, so the device's
    /// cabled / Wi-Fi reads and its Instant Hotspot entry map to the same log. nil for accessories.
    public static func key(for device: DeviceBattery) -> String? {
        guard device.isIOSDevice else { return nil }
        return "ios|\(device.model ?? device.kind.rawValue)|\(HotspotParser.advertisedStem(device.name))"
    }

    /// The sample to log for a device reading, or nil when it isn't logged: Insights uses exact
    /// data only, so Instant Hotspot (approximate) levels, remembered last readings and devices
    /// without a level are skipped.
    public static func exactSample(for device: DeviceBattery, at date: Date) -> (key: String, sample: ChargeSample)? {
        guard device.isExactReading, let key = key(for: device), let percent = device.percent else { return nil }
        return (key, ChargeSample(date: date, percent: Double(percent), isCharging: device.isCharging))
    }

    public enum RecordResult: Equatable, Sendable {
        /// A new sample was appended.
        case appended
        /// The last sample's run was extended (same reading seen again).
        case extended
        /// Out of order; nothing changed.
        case ignored
    }

    /// Adds a reading. Identical consecutive readings extend the last sample's run instead of
    /// adding a sample, unless the gap since it exceeds `ChargeAnalysis.maxGap` (so the gap
    /// stays visible as "unknown").
    @discardableResult
    public mutating func record(_ sample: ChargeSample) -> RecordResult {
        guard let last = samples.last else {
            samples.append(sample)
            return .appended
        }
        guard sample.date >= last.end else { return .ignored }
        if last.sameReading(as: sample), sample.date.timeIntervalSince(last.end) <= ChargeAnalysis.maxGap {
            if sample.date == last.end { return .extended }
            samples[samples.count - 1].until = sample.date
            return .extended
        }
        samples.append(sample)
        return .appended
    }

    /// Drops samples whose run ended before `now - retention`. Returns true when any were dropped.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let before = samples.count
        samples.removeAll { $0.end < cutoff }
        return samples.count != before
    }
}

// MARK: - Store

/// One small JSON file per device in `~/Library/Application Support/BatteryBuddy/charge-log/`,
/// named by a hash of the log key (no device names or identifiers in file names).
///
/// Cheap by design: appends write the file (atomically); run extensions (the same percent seen
/// again) only touch memory and are written at most every `extendWriteInterval`.
public final class ChargeLogStore {
    public let directory: URL
    public private(set) var logs: [String: ChargeLog] = [:]
    private var lastWrite: [String: Date] = [:]
    private var dirty: Set<String> = []

    public static let extendWriteInterval: TimeInterval = 15 * 60

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BatteryBuddy", isDirectory: true)
            .appendingPathComponent("charge-log", isDirectory: true)
    }

    public init(directory: URL = ChargeLogStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    public func load() {
        logs = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var log = try? Self.decoder.decode(ChargeLog.self, from: data) else { continue }
            // Approximate (Instant Hotspot) samples from older builds: Insights uses exact data
            // only, so prune them once. A log that had nothing else is removed.
            if log.samples.contains(where: \.isApproximate) {
                log.samples.removeAll(where: \.isApproximate)
                if log.samples.isEmpty {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                try? Self.encoder.encode(log).write(to: file, options: .atomic)
            }
            logs[log.id] = log
        }
    }

    public static func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    public func fileURL(for key: String) -> URL { directory.appendingPathComponent(Self.fileName(for: key)) }

    /// Records one exact reading for `key`, creating the log on first use; `name` replaces the
    /// stored name. Approximate samples are not logged (`.ignored`).
    @discardableResult
    public func record(key: String, name: String, kind: DeviceBattery.Kind?, model: String?,
                       sample: ChargeSample, now: Date = Date()) throws -> ChargeLog.RecordResult {
        guard !sample.isApproximate else { return .ignored }
        var log = logs[key] ?? ChargeLog(id: key, name: name, kind: kind, model: model)
        var metadataChanged = false
        if log.name != name {
            log.name = name
            metadataChanged = true
        }
        if let model, log.model != model {
            log.model = model
            metadataChanged = true
        }
        let result = log.record(sample)
        let pruned = result == .appended ? log.prune(now: now) : false
        logs[key] = log
        switch result {
        case .ignored:
            if metadataChanged { try write(key, now: now) }
        case .appended:
            try write(key, now: now)
        case .extended:
            if metadataChanged || pruned || now.timeIntervalSince(lastWrite[key] ?? .distantPast) >= Self.extendWriteInterval {
                try write(key, now: now)
            } else {
                dirty.insert(key)
            }
        }
        return result
    }

    /// Writes logs whose run extensions are only in memory (call before quitting).
    public func flush() {
        for key in dirty { try? write(key, now: Date()) }
    }

    private func write(_ key: String, now: Date) throws {
        guard let log = logs[key] else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(log).write(to: fileURL(for: key), options: .atomic)
        lastWrite[key] = now
        dirty.remove(key)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

// MARK: - Analysis

/// Battery used on one calendar day, in percentage points.
public struct UsageDay: Equatable, Sendable, Identifiable {
    /// Local midnight.
    public var start: Date
    /// Whole day (today: midnight → now).
    public var usedAllDay: Double
    /// Midnight → the current time of day.
    public var usedByCutoff: Double
    /// Seconds of the day with known readings (gaps over `maxGap` are unknown).
    public var covered: TimeInterval
    public var isToday: Bool

    public var id: Date { start }
    /// Enough readings to count towards the average.
    public var hasData: Bool { covered >= ChargeAnalysis.minDayCoverage }

    public init(start: Date, usedAllDay: Double, usedByCutoff: Double, covered: TimeInterval, isToday: Bool) {
        self.start = start
        self.usedAllDay = usedAllDay
        self.usedByCutoff = usedByCutoff
        self.covered = covered
        self.isToday = isToday
    }
}

public enum UsageComparison: String, Equatable, Sendable {
    case less, aboutTheSame, more, notEnoughData
}

/// What the Insights "Daily Usage" card shows.
public struct UsageSummary: Equatable, Sendable {
    /// The previous `ChargeAnalysis.comparedDays` days, then today; oldest first.
    public var days: [UsageDay]
    public var now: Date
    /// Means over past days with data; nil with fewer than `minComparisonDays` such days.
    public var averageAllDay: Double?
    public var averageByCutoff: Double?
    public var comparison: UsageComparison
    /// Past days that counted towards the averages.
    public var daysWithData: Int

    public var today: UsageDay? { days.last }
    public var hasAnyData: Bool { days.contains { $0.covered > 0 } }
}

/// Pure analysis over exact `ChargeSample`s (approximate ones are ignored). Battery **used** =
/// sum of percentage drops between consecutive readings; rises (charging) count as zero; gaps
/// longer than `maxGap` are unknown.
/// A drop between two readings is spread evenly over the time between them, so it splits
/// correctly across midnight and the time-of-day cutoff.
public enum ChargeAnalysis {
    /// Readings further apart than this: nothing is known about the time between them.
    public static let maxGap: TimeInterval = 2 * 3600
    /// A day needs this much covered time to count towards the average.
    public static let minDayCoverage: TimeInterval = 3600
    /// Past days with data needed before comparing.
    public static let minComparisonDays = 3
    public static let comparedDays = 7
    /// "About the same" band: ±15 % of the average, but at least ±1 percentage point
    /// (levels are whole percents, so tiny averages would otherwise flip on one step).
    public static let sameBand = 0.15
    public static let sameFloor = 1.0

    /// Percentage points used and seconds covered within `[from, to)`.
    public static func usage(_ samples: [ChargeSample], from: Date, to: Date) -> (used: Double, covered: TimeInterval) {
        guard to > from else { return (0, 0) }
        let samples = samples.contains(where: \.isApproximate) ? samples.filter { !$0.isApproximate } : samples
        var used = 0.0
        var covered: TimeInterval = 0
        func overlap(_ a: Date, _ b: Date) -> TimeInterval {
            max(0, min(b, to).timeIntervalSince(max(a, from)))
        }
        for (i, s) in samples.enumerated() {
            // The run itself: known, constant level.
            covered += overlap(s.date, s.end)
            guard i + 1 < samples.count else { break }
            let next = samples[i + 1]
            let t0 = s.end, t1 = next.date
            let dt = t1.timeIntervalSince(t0)
            guard dt >= 0, dt <= maxGap else { continue }
            let drop = max(0, s.percent - next.percent)
            if dt == 0 {
                if t0 >= from, t0 < to { used += drop }
                continue
            }
            let o = overlap(t0, t1)
            covered += o
            used += drop * o / dt
        }
        return (used, covered)
    }

    /// Per-day usage for the previous `comparedDays` days and today, averages, and the comparison.
    public static func summary(_ samples: [ChargeSample], now: Date, calendar: Calendar = .current) -> UsageSummary {
        let sorted = samples.filter { !$0.isApproximate }.sorted { $0.date < $1.date }
        let todayStart = calendar.startOfDay(for: now)
        let time = calendar.dateComponents([.hour, .minute, .second], from: now)
        var days: [UsageDay] = []
        for offset in stride(from: comparedDays, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let isToday = offset == 0
            let end = isToday ? now : (calendar.date(byAdding: .day, value: 1, to: start) ?? start)
            let cutoff = isToday ? now
                : min(end, calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                         second: time.second ?? 0, of: start) ?? end)
            let all = usage(sorted, from: start, to: end)
            let byCutoff = usage(sorted, from: start, to: cutoff)
            days.append(UsageDay(start: start, usedAllDay: all.used, usedByCutoff: byCutoff.used,
                                 covered: all.covered, isToday: isToday))
        }
        let past = days.filter { !$0.isToday && $0.hasData }
        let enough = past.count >= minComparisonDays
        let avgAll = enough ? past.map(\.usedAllDay).reduce(0, +) / Double(past.count) : nil
        let avgCut = enough ? past.map(\.usedByCutoff).reduce(0, +) / Double(past.count) : nil
        var comparison = UsageComparison.notEnoughData
        if let avgCut, let today = days.last, today.covered > 0 {
            comparison = compare(today: today.usedByCutoff, average: avgCut)
        }
        return UsageSummary(days: days, now: now, averageAllDay: avgAll, averageByCutoff: avgCut,
                            comparison: comparison, daysWithData: past.count)
    }

    public static func compare(today: Double, average: Double) -> UsageComparison {
        let tolerance = max(sameBand * average, sameFloor)
        if today < average - tolerance { return .less }
        if today > average + tolerance { return .more }
        return .aboutTheSame
    }

    /// The Daily Usage sentence. `time` is the current time of day, e.g. "12:07".
    public static func sentence(_ comparison: UsageComparison, time: String) -> String {
        switch comparison {
        case .less: return "You’re using less battery today than you usually do by \(time)."
        case .aboutTheSame: return "You’re using about as much battery today as you usually do by \(time)."
        case .more: return "You’re using more battery today than you usually do by \(time)."
        case .notEnoughData: return "Battery Buddy needs a few days of data to compare."
        }
    }
}
