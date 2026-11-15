import BatteryKit
import Foundation
import Observation

/// App-wide state. Owns the reader, the refresh timer and the history store.
///
/// Refresh policy (spec "Stay tiny"):
/// - IOPS notifications always update the snapshot (cheap, event-driven).
/// - A fast timer runs only while a UI surface is visible (`visibleSurfaces > 0`).
/// - A slow timer (15 min) keeps the menu bar title fresh and records one history sample per day.
@Observable
@MainActor
final class BatteryModel {
    private(set) var snapshot: BatterySnapshot?
    let mac = MacInfo.current()
    private(set) var history: [HistorySample] = []

    private let reader = BatteryReader()
    private let store = HistoryStore()
    @ObservationIgnored private var observer: PowerSources.Observer?
    @ObservationIgnored private var fastTimer: Timer?
    @ObservationIgnored private var slowTimer: Timer?
    @ObservationIgnored private var visibleSurfaces = 0

    @ObservationIgnored private let isStatic: Bool

    /// Static model for previews and `--render`: no timers, no disk writes.
    init(previewSnapshot: BatterySnapshot?, history: [HistorySample]) {
        isStatic = true
        snapshot = previewSnapshot
        self.history = history
    }

    init() {
        isStatic = false
        history = store.samples
        refresh()
        observer = PowerSources.Observer { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !isStatic, let s = reader.snapshot() else { return }
        if s != snapshot { snapshot = s }
        recordHistory(s)
    }

    /// Call from `.onAppear` / `.onDisappear` of popover and window.
    func surfaceAppeared() {
        visibleSurfaces += 1
        refresh()
        restartFastTimer()
    }

    func surfaceDisappeared() {
        visibleSurfaces = max(0, visibleSurfaces - 1)
        restartFastTimer()
    }

    func restartFastTimer() {
        fastTimer?.invalidate()
        fastTimer = nil
        guard !isStatic, visibleSurfaces > 0 else { return }
        let interval = max(1, UserDefaults.standard.double(forKey: SettingsKey.refreshInterval).nonZero ?? 2)
        fastTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func exportCSV() -> String { HistoryAggregator.csv(history) }

    private func recordHistory(_ s: BatterySnapshot) {
        guard let sample = HistorySample(snapshot: s) else { return }
        // Only write once per day unless cycle count changed, to avoid disk churn.
        if let last = history.last,
           Calendar.current.isDate(last.date, inSameDayAs: sample.date),
           last.cycleCount == sample.cycleCount { return }
        if (try? store.record(sample)) == true { history = store.samples }
    }
}

enum SettingsKey {
    static let showPercent = "menuBar.showPercent"
    static let showTime = "menuBar.showTime"
    static let showWatts = "menuBar.showWatts"
    static let refreshInterval = "refreshInterval"
    static let temperatureUnit = "temperatureUnit"
}

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
