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

    // MARK: F8 battery controls

    /// Energy Mode per source + capabilities (`pmset`). Nil until read, or on Macs without it.
    private(set) var energyStatus: EnergyModeStatus?
    /// macOS charge limit state (PowerUI). Nil when unavailable.
    private(set) var chargeLimit: ChargeLimitStatus?
    /// True while the administrator prompt for an Energy Mode change is up.
    private(set) var isChangingEnergyMode = false
    /// Set after "Charge to Full Now" succeeded, until macOS starts charging (or 2 min pass).
    private(set) var chargeToFullRequestedAt: Date?
    /// Short-lived message for a failed control action (user cancel is not an error).
    private(set) var controlError: String?
    /// True when the password-free sudo rule for Energy Mode is installed.
    private(set) var isPasswordFreeEnergyMode = false

    @ObservationIgnored private var controlsReadInFlight = false
    @ObservationIgnored private var controlsReadQueued = false
    @ObservationIgnored private var capabilityCache: [PowerSourceKind: Set<EnergyMode>] = [:]
    @ObservationIgnored private var errorClearTask: Task<Void, Never>?

    /// Static model for previews and `--render`: no timers, no disk writes, no pmset/PowerUI.
    init(previewSnapshot: BatterySnapshot?, history: [HistorySample],
         energyStatus: EnergyModeStatus? = nil, chargeLimit: ChargeLimitStatus? = nil,
         chargeToFullRequested: Bool = false, controlError: String? = nil) {
        isStatic = true
        snapshot = previewSnapshot
        self.history = history
        self.energyStatus = energyStatus
        self.chargeLimit = chargeLimit
        chargeToFullRequestedAt = chargeToFullRequested ? Date() : nil
        self.controlError = controlError
    }

    init() {
        isStatic = false
        history = store.samples
        refresh()
        refreshControls()
        observer = PowerSources.Observer { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.refreshControls()
            }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !isStatic, let s = reader.snapshot() else { return }
        if s != snapshot { snapshot = s }
        recordHistory(s)
        expireChargeToFullRequest()
    }

    /// Call from `.onAppear` / `.onDisappear` of popover and window.
    func surfaceAppeared() {
        visibleSurfaces += 1
        refresh()
        refreshControls()
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
            MainActor.assumeIsolated {
                self?.refresh()
                self?.refreshControls()
            }
        }
    }

    // MARK: Controls (F8)

    /// Source whose Energy Mode the popover shows and changes.
    var currentPowerSource: PowerSourceKind? {
        snapshot.map { $0.externalConnected ? .ac : .battery }
    }

    var energyMode: EnergyMode? {
        guard let source = currentPowerSource else { return nil }
        return energyStatus?.modes[source]
    }

    var supportedEnergyModes: [EnergyMode] {
        guard let source = currentPowerSource, energyStatus != nil else { return [] }
        return energyStatus?.supportedModes(for: source) ?? []
    }

    /// Re-reads Energy Mode (pmset) and charge limit (PowerUI) off the main thread. Called on
    /// IOPS changes and on each fast-timer tick while a surface is visible; never overlaps.
    func refreshControls() {
        guard !isStatic else { return }
        guard !controlsReadInFlight else {
            controlsReadQueued = true
            return
        }
        controlsReadInFlight = true
        let needCapabilities = currentPowerSource.map { capabilityCache[$0] == nil } ?? true
        Task { [weak self] in
            let (energy, limit, passwordFree) = await Task.detached(priority: .utility) {
                (EnergyModeControl.read(includeCapabilities: needCapabilities), ChargeLimit.shared.status(),
                 PasswordFreeEnergyMode.isInstalled())
            }.value
            guard let self else { return }
            if passwordFree != self.isPasswordFreeEnergyMode { self.isPasswordFreeEnergyMode = passwordFree }
            self.applyControls(energy: energy, limit: limit)
            self.controlsReadInFlight = false
            if self.controlsReadQueued {
                self.controlsReadQueued = false
                self.refreshControls()
            }
        }
    }

    private func applyControls(energy: EnergyModeStatus?, limit: ChargeLimitStatus?) {
        if var energy {
            capabilityCache.merge(energy.capabilities) { _, new in new }
            energy.capabilities = capabilityCache
            if energy != energyStatus { energyStatus = energy }
        } else if energyStatus != nil {
            energyStatus = nil
        }
        if limit != chargeLimit { chargeLimit = limit }
        expireChargeToFullRequest()
    }

    /// Asks for an administrator password, then runs `pmset` for the current source.
    func setEnergyMode(_ mode: EnergyMode) async {
        guard !isStatic, !isChangingEnergyMode, let source = currentPowerSource, mode != energyMode else { return }
        isChangingEnergyMode = true
        defer { isChangingEnergyMode = false }
        // NSAppleScript is not thread-safe: run it on the main actor. The password dialog is
        // drawn by SecurityAgent, so blocking here only pauses our own UI while it is up.
        let result: Result<Void, Error> = Result { try EnergyModeControl.set(mode, for: source) }
        switch result {
        case .success:
            clearControlError()
        case .failure(EnergyModeError.cancelledByUser):
            break
        case .failure(EnergyModeError.failed(let message)):
            showControlError("Couldn't change Energy Mode: \(message)")
        case .failure(let error):
            showControlError("Couldn't change Energy Mode: \(error.localizedDescription)")
        }
        refreshControls()
    }

    /// Installs or removes the password-free sudo rule (one administrator prompt either way).
    func setPasswordFreeEnergyMode(_ enabled: Bool) {
        guard !isStatic, enabled != isPasswordFreeEnergyMode else { return }
        do {
            if enabled { try PasswordFreeEnergyMode.install() } else { try PasswordFreeEnergyMode.uninstall() }
            clearControlError()
        } catch EnergyModeError.cancelledByUser {
        } catch EnergyModeError.failed(let message) {
            showControlError("Couldn't \(enabled ? "enable" : "disable") password-free Energy Mode: \(message)")
        } catch {
            showControlError(error.localizedDescription)
        }
        isPasswordFreeEnergyMode = PasswordFreeEnergyMode.isInstalled()
    }

    /// Same as the native Battery menu item: lifts the charge limit until the battery is full.
    func chargeToFullNow() async {
        guard !isStatic, chargeToFullRequestedAt == nil else { return }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            Result { try ChargeLimit.shared.chargeToFullNow() }
        }.value
        switch result {
        case .success:
            chargeToFullRequestedAt = Date()
            clearControlError()
        case .failure(ChargeLimitError.unavailable):
            showControlError("Charge to Full Now isn't available on this version of macOS.")
        case .failure(ChargeLimitError.failed(let message)):
            showControlError("Couldn't charge to full: \(message)")
        case .failure(let error):
            showControlError("Couldn't charge to full: \(error.localizedDescription)")
        }
        refresh()
        refreshControls()
    }

    /// The "Charging to 100%…" note ends once macOS starts charging, stops holding, or after 2 min.
    private func expireChargeToFullRequest() {
        guard !isStatic, let requested = chargeToFullRequestedAt else { return }
        let charging = snapshot?.isCharging == true
        let released = chargeLimit.map { !$0.isHoldingCharge } ?? true
        if charging || released || Date().timeIntervalSince(requested) > 120 {
            chargeToFullRequestedAt = nil
        }
    }

    private func showControlError(_ message: String) {
        controlError = message
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.controlError = nil
        }
    }

    private func clearControlError() {
        errorClearTask?.cancel()
        controlError = nil
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
    /// Menu bar shows the one-decimal raw percent (e.g. 79.0%) instead of what macOS shows.
    static let precisePercent = "menuBar.precisePercent"
    static let refreshInterval = "refreshInterval"
    static let temperatureUnit = "temperatureUnit"
}

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
