import Foundation

/// F11 — whether a battery needs service, and (iPhone) whether iOS may be limiting peak
/// performance. The Mac's condition comes from macOS itself (`system_profiler`); iPhone / iPad
/// don't share iOS's own Battery Health verdict with a Mac, so theirs is an estimate from the
/// same inputs iOS uses: maximum capacity vs design, and the shutdown record.
public struct BatteryCondition: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Maximum capacity at or above the service level, no failure reported.
        case normal
        /// Below Apple's 80 % service level, or a failure macOS / the gauge reports.
        case serviceRecommended
    }

    public enum Source: String, Codable, Sendable {
        /// macOS's own verdict (System Information › Power › Condition).
        case macOS
        /// Worked out by BatterySoH from capacity (and, for iPhone, the shutdown record).
        case estimated
    }

    /// iPhone only: what iOS's "Peak Performance Capability" most likely says.
    public enum PeakPerformance: String, Codable, Sendable {
        /// No unexpected shutdown recorded and capacity above the service level.
        case normal
        /// The battery recorded an unexpected shutdown: iOS turns on performance management
        /// after one, to keep it from happening again.
        case unexpectedShutdown
        /// Capacity below the service level: iOS may manage performance to avoid shutdowns.
        case worn
    }

    public var status: Status
    public var source: Source
    /// What Settings shows as "Maximum Capacity": nominal (else full-charge) capacity vs design,
    /// rounded down. nil when unknown.
    public var maximumCapacityPercent: Int?
    /// The gauge or macOS reports a permanent battery failure.
    public var permanentFailure: Bool
    /// iPhone only; nil for Mac / iPad (they don't manage performance for battery wear).
    public var peakPerformance: PeakPerformance?

    /// Apple considers a battery worn below 80 % of its design capacity.
    public static let serviceThresholdPercent = 80

    public init(status: Status, source: Source, maximumCapacityPercent: Int?,
                permanentFailure: Bool = false, peakPerformance: PeakPerformance? = nil) {
        self.status = status
        self.source = source
        self.maximumCapacityPercent = maximumCapacityPercent
        self.permanentFailure = permanentFailure
        self.peakPerformance = peakPerformance
    }

    public var needsService: Bool { status == .serviceRecommended }

    /// Percent points left above the service level (0 when at or below it).
    public var pointsAboveServiceLevel: Int? {
        maximumCapacityPercent.map { max(0, $0 - Self.serviceThresholdPercent) }
    }

    // MARK: - Rules (pure)

    /// Nominal (else full-charge) capacity vs design, rounded down like Settings
    /// (5,744 of 6,249 mAh → 91 %, what System Information shows for the same battery).
    public static func maximumCapacityPercent(nominalMAh: Int?, fullMAh: Int?, designMAh: Int?) -> Int? {
        guard let design = designMAh, design > 0,
              let capacity = BatteryParser.positive(nominalMAh) ?? BatteryParser.positive(fullMAh) else { return nil }
        return min(100, capacity * 100 / design)
    }

    /// Condition worked out from capacity alone (plus, for iPhone, the shutdown record).
    /// nil when there is nothing to go on.
    public static func estimate(maximumCapacityPercent: Int?, permanentFailure: Bool = false,
                                unexpectedShutdown: Bool? = nil, isIPhone: Bool = false) -> BatteryCondition? {
        guard maximumCapacityPercent != nil || permanentFailure else { return nil }
        let worn = maximumCapacityPercent.map { $0 < serviceThresholdPercent } ?? false
        var peak: PeakPerformance?
        if isIPhone, maximumCapacityPercent != nil {
            if worn { peak = .worn } else if unexpectedShutdown == true { peak = .unexpectedShutdown } else { peak = .normal }
        }
        return BatteryCondition(status: worn || permanentFailure ? .serviceRecommended : .normal,
                                source: .estimated, maximumCapacityPercent: maximumCapacityPercent,
                                permanentFailure: permanentFailure, peakPerformance: peak)
    }

    /// This Mac: macOS's own condition when `reported` has one, else an estimate.
    public static func mac(_ snapshot: BatterySnapshot, reported: MacReportedHealth?) -> BatteryCondition? {
        let computed = maximumCapacityPercent(nominalMAh: snapshot.nominalChargeCapacityMAh,
                                              fullMAh: snapshot.fullChargeCapacityMAh,
                                              designMAh: snapshot.designCapacityMAh)
        let failure = (snapshot.permanentFailureStatus ?? 0) != 0
        let maxCapacity = reported?.maximumCapacityPercent ?? computed
        guard let status = reported?.status else {
            return estimate(maximumCapacityPercent: maxCapacity, permanentFailure: failure)
        }
        let permanent = failure || reported?.isPermanentFailure == true
        return BatteryCondition(status: permanent ? .serviceRecommended : status, source: .macOS,
                                maximumCapacityPercent: maxCapacity, permanentFailure: permanent)
    }

    /// iPhone / iPad: an estimate from the last exact read. nil for accessories, hotspot
    /// levels and untrusted devices (no capacity).
    public static func device(_ d: DeviceBattery) -> BatteryCondition? {
        guard d.isIOSDevice, !d.isApproximate else { return nil }
        let maxCapacity = maximumCapacityPercent(nominalMAh: d.nominalChargeCapacityMAh,
                                                 fullMAh: d.fullChargeCapacityMAh,
                                                 designMAh: d.designCapacityMAh)
        return estimate(maximumCapacityPercent: maxCapacity, unexpectedShutdown: d.unexpectedShutdownRecorded,
                        isIPhone: d.kind == .iPhone)
    }

    /// Full cycles the battery is rated for while keeping 80 % of its capacity: the gauge's own
    /// design count when it has one (Mac), else Apple's published figure — iPhone 15 and later
    /// 1000, earlier iPhone 500, iPad 1000. nil when unknown.
    public static func ratedCycles(kind: DeviceBattery.Kind?, model: String?, designCycleCount: Int? = nil) -> Int? {
        if let designCycleCount, designCycleCount > 0 { return designCycleCount }
        switch kind {
        case .iPad: return 1000
        case .iPhone:
            guard let (major, minor) = modelNumber(model, prefix: "iPhone") else { return nil }
            // iPhone15,4 / 15,5 = iPhone 15 / 15 Plus; iPhone16,x = 15 Pro; later all 1000.
            return major >= 16 || (major == 15 && minor >= 4) ? 1000 : 500
        default: return nil
        }
    }

    /// "iPhone15,4" → (15, 4).
    static func modelNumber(_ model: String?, prefix: String) -> (Int, Int)? {
        guard let model, model.hasPrefix(prefix) else { return nil }
        let parts = model.dropFirst(prefix.count).split(separator: ",")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return (major, minor)
    }
}

// MARK: - macOS's own verdict

/// What System Information reports for the Mac's battery (`system_profiler SPPowerDataType`):
/// `sppower_battery_health` ("Good" = "Normal" in the UI; anything else is a service state) and
/// `sppower_battery_health_maximum_capacity` ("91%"). Apps can't read these through IOKit
/// without an Apple entitlement, so the reader runs the public tool.
public struct MacReportedHealth: Codable, Equatable, Sendable {
    /// Raw value, e.g. "Good", "Fair", "Poor", "Check Battery", "Service Recommended".
    public var health: String?
    public var maximumCapacityPercent: Int?

    public init(health: String?, maximumCapacityPercent: Int?) {
        self.health = health
        self.maximumCapacityPercent = maximumCapacityPercent
    }

    /// nil when macOS gave no condition.
    public var status: BatteryCondition.Status? {
        guard let h = health?.trimmingCharacters(in: .whitespaces).lowercased(), !h.isEmpty else { return nil }
        return ["good", "normal"].contains(h) ? .normal : .serviceRecommended
    }

    public var isPermanentFailure: Bool {
        health?.lowercased().contains("permanent") == true
    }

    /// Pure: parses `system_profiler SPPowerDataType -json` output.
    public static func parse(systemProfilerJSON data: Data) -> MacReportedHealth? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let info = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            let health = info["sppower_battery_health"] as? String
            let maxCapacity = percent(info["sppower_battery_health_maximum_capacity"])
            guard health != nil || maxCapacity != nil else { return nil }
            return MacReportedHealth(health: health, maximumCapacityPercent: maxCapacity)
        }
        return nil
    }

    /// "91%" / 91 → 91.
    static func percent(_ value: Any?) -> Int? {
        if let n = value as? Int { return (0...100).contains(n) ? n : nil }
        guard let s = value as? String else { return nil }
        let digits = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let n = Int(digits), (0...100).contains(n) else { return nil }
        return n
    }

    /// Runs `/usr/sbin/system_profiler SPPowerDataType -json` (~1 s). Blocking: call off the
    /// main thread. nil when the tool fails, times out or reports no battery.
    public static func read(timeout: TimeInterval = 15) -> MacReportedHealth? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(systemProfilerJSON: data)
    }
}
