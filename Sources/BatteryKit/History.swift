import Foundation

/// One daily history sample.
public struct HistorySample: Codable, Equatable, Sendable, Identifiable {
    public var date: Date
    public var healthPercent: Double
    public var cycleCount: Int
    public var fullChargeCapacityMAh: Int?
    public var designCapacityMAh: Int?

    public var id: Date { date }

    public init(date: Date, healthPercent: Double, cycleCount: Int,
                fullChargeCapacityMAh: Int? = nil, designCapacityMAh: Int? = nil) {
        self.date = date
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
        self.fullChargeCapacityMAh = fullChargeCapacityMAh
        self.designCapacityMAh = designCapacityMAh
    }

    public init?(snapshot: BatterySnapshot) {
        guard let health = snapshot.healthPercent, let cycles = snapshot.cycleCount else { return nil }
        self.init(date: snapshot.timestamp, healthPercent: health, cycleCount: cycles,
                  fullChargeCapacityMAh: snapshot.fullChargeCapacityMAh,
                  designCapacityMAh: snapshot.designCapacityMAh)
    }
}

/// One row of the History table: a calendar month.
public struct MonthSummary: Equatable, Sendable, Identifiable {
    /// "2025-11"
    public var period: String
    public var averageHealthPercent: Double
    public var maxCycleCount: Int
    public var sampleCount: Int

    public var id: String { period }
}

public enum HistoryAggregator {
    /// Groups samples by calendar month, newest month last.
    public static func monthly(_ samples: [HistorySample], calendar: Calendar = .current) -> [MonthSummary] {
        let groups = Dictionary(grouping: samples) { s -> String in
            let c = calendar.dateComponents([.year, .month], from: s.date)
            return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        }
        return groups.map { period, items in
            MonthSummary(period: period,
                         averageHealthPercent: items.map(\.healthPercent).reduce(0, +) / Double(items.count),
                         maxCycleCount: items.map(\.cycleCount).max() ?? 0,
                         sampleCount: items.count)
        }.sorted { $0.period < $1.period }
    }

    public static func csv(_ samples: [HistorySample]) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        // Samples are bucketed by local calendar day; print that day, not the UTC date.
        f.timeZone = .current
        var lines = ["date,health_percent,cycle_count,full_charge_mah,design_mah"]
        for s in samples.sorted(by: { $0.date < $1.date }) {
            lines.append([f.string(from: s.date), String(format: "%.1f", s.healthPercent), String(s.cycleCount),
                          s.fullChargeCapacityMAh.map(String.init) ?? "", s.designCapacityMAh.map(String.init) ?? ""]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// JSON-file store with at most one sample per calendar day.
public final class HistoryStore {
    public let fileURL: URL
    public private(set) var samples: [HistorySample] = []
    private let calendar: Calendar

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BatteryBuddy", isDirectory: true).appendingPathComponent("history.json")
    }

    public init(fileURL: URL = HistoryStore.defaultURL, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { samples = []; return }
        samples = (try? Self.decoder.decode([HistorySample].self, from: data)) ?? []
    }

    /// Adds `sample` unless one already exists for that day; then the day's sample is replaced
    /// (latest reading of the day wins). Returns true when the file changed.
    @discardableResult
    public func record(_ sample: HistorySample) throws -> Bool {
        if let i = samples.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: sample.date) }) {
            if samples[i] == sample { return false }
            samples[i] = sample
        } else {
            samples.append(sample)
            samples.sort { $0.date < $1.date }
        }
        try save()
        return true
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(samples).write(to: fileURL, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
