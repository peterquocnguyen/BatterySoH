import AppKit
import BatteryKit
import Foundation
import Observation

/// App-wide state. Owns the reader, the refresh timer and the history store.
///
/// Refresh policy (spec "Stay tiny"):
/// - IOPS notifications always update the snapshot (cheap, event-driven).
/// - A fast timer runs only while a UI surface is visible (`visibleSurfaces > 0`).
/// - A slow timer (5 min) keeps the menu bar title fresh, records one history sample per day
///   and one charge-log reading for Insights (F11) — the same registry read, nothing extra.
/// - Instant Hotspot browsing runs only while a surface is visible (restarted every minute in
///   case the phone re-advertises). Its levels are never logged (Insights uses exact data only).
@Observable
@MainActor
final class BatteryModel {
    private(set) var snapshot: BatterySnapshot?
    let mac: MacInfo
    private(set) var history: [HistorySample] = []
    /// Other devices: iPhone / iPad (exact connected reads, then the last exact reading of
    /// disconnected ones, then hotspot-only ones), then Bluetooth / USB accessories.
    var devices: [DeviceBattery] {
        let exactLogNames = chargeLogs.filter { !$0.isThisMac }.map(\.name)
        return HotspotParser.merge(connected: mobileDevices, remembered: rememberedDevices,
                                   nearby: nearbyDevices, knownNames: exactLogNames) + accessories
    }
    private(set) var accessories: [DeviceBattery] = []
    private(set) var mobileDevices: [DeviceBattery] = []
    /// Last exact reading per iPhone / iPad (persisted), shown while it isn't connected.
    private(set) var rememberedDevices: [DeviceBattery] = []
    private(set) var nearbyDevices: [DeviceBattery] = []
    /// F11 charge logs (This Mac + iPhones / iPads), refreshed on every new sample.
    private(set) var chargeLogs: [ChargeLog] = []

    private let reader = BatteryReader()
    private let store = HistoryStore()
    @ObservationIgnored private var chargeStore: ChargeLogStore?
    @ObservationIgnored private var lastExactStore: LastExactReadingStore?
    @ObservationIgnored private var observer: PowerSources.Observer?
    @ObservationIgnored private var fastTimer: Timer?
    @ObservationIgnored private var slowTimer: Timer?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private var visibleSurfaces = 0
    /// Started on first visible surface so MobileDevice.framework only loads when needed.
    @ObservationIgnored private var mobileMonitor: MobileDeviceMonitor?
    @ObservationIgnored private var mobileRefreshed = Date.distantPast
    /// Instant Hotspot browser: runs only while a surface is visible.
    @ObservationIgnored private var hotspotBrowser: NearbyHotspotBrowser?
    /// When browsing last (re)started; nil while stopped.
    @ObservationIgnored private var hotspotStartedAt: Date?
    /// An empty result right after a restart is the session starting over, not the phone leaving.
    @ObservationIgnored private var nearbyGraceUntil = Date.distantPast

    static let hotspotRestartInterval: TimeInterval = 60
    static let sampleInterval: TimeInterval = 5 * 60

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
    /// macOS Low Power Mode is on (the menu bar glyph turns yellow, like the system's).
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var lowPowerObserver: NSObjectProtocol?
    /// True when the password-free sudo rule for Energy Mode is installed.
    private(set) var isPasswordFreeEnergyMode = false

    @ObservationIgnored private var controlsReadInFlight = false
    @ObservationIgnored private var controlsReadQueued = false
    @ObservationIgnored private var capabilityCache: [PowerSourceKind: Set<EnergyMode>] = [:]
    @ObservationIgnored private var errorClearTask: Task<Void, Never>?

    /// Static model for previews and `--render`: no timers, no disk writes, no pmset/PowerUI.
    init(previewSnapshot: BatterySnapshot?, history: [HistorySample],
         energyStatus: EnergyModeStatus? = nil, chargeLimit: ChargeLimitStatus? = nil,
         chargeToFullRequested: Bool = false, controlError: String? = nil,
         devices: [DeviceBattery] = [], chargeLogs: [ChargeLog] = [],
         mac: MacInfo = .current()) {
        isStatic = true
        self.mac = mac
        self.chargeLogs = chargeLogs
        snapshot = previewSnapshot
        self.history = history
        self.energyStatus = energyStatus
        self.chargeLimit = chargeLimit
        chargeToFullRequestedAt = chargeToFullRequested ? Date() : nil
        self.controlError = controlError
        // Previews put every sample device in `accessories`; `devices` returns them as given.
        accessories = devices
    }

    init() {
        isStatic = false
        mac = .current()
        history = store.samples
        let charge = ChargeLogStore()
        chargeStore = charge
        chargeLogs = Self.sorted(charge.logs)
        let lastExact = LastExactReadingStore()
        lastExactStore = lastExact
        rememberedDevices = lastExact.devices
        refresh()
        refreshControls()
        observer = PowerSources.Observer { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.refreshControls()
            }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.publishChargeLogs()
            }
        }
        slowTimer?.tolerance = 60
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.chargeStore?.flush()
                try? self?.lastExactStore?.flush()
            }
        }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.refreshControls()
            }
        }
    }

    func refresh() {
        guard !isStatic else { return }
        if visibleSurfaces > 0 {
            refreshDevices()
            restartNearbyBrowsingIfDue()
        }
        guard let s = reader.snapshot() else { return }
        if s != snapshot { snapshot = s }
        recordHistory(s)
        recordCharge(s)
        expireChargeToFullRequest()
    }

    /// Accessories are a cheap IOPS read; iPhone / iPad reads open a lockdown session, so they
    /// run at most once a minute (plus on every attach).
    private func refreshDevices() {
        let a = AccessoryPowerSources.read()
        if a != accessories { accessories = a }
        if mobileMonitor == nil {
            mobileMonitor = MobileDeviceMonitor { [weak self] list in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Exact readings: logged on every read, even when the list is unchanged.
                    self.logDevices(list)
                    self.rememberExact(list)
                    guard list != self.mobileDevices else { return }
                    self.mobileDevices = list
                }
            }
            mobileMonitor?.start()
            mobileRefreshed = Date()
        } else if Date().timeIntervalSince(mobileRefreshed) >= 60 {
            mobileRefreshed = Date()
            mobileMonitor?.refresh()
        }
    }

    /// Call from `.onAppear` / `.onDisappear` of popover and window.
    func surfaceAppeared() {
        visibleSurfaces += 1
        if visibleSurfaces == 1 { startNearbyBrowsing() }
        refresh()
        refreshControls()
        restartFastTimer()
    }

    func surfaceDisappeared() {
        visibleSurfaces = max(0, visibleSurfaces - 1)
        if visibleSurfaces == 0 { stopNearbyBrowsing() }
        restartFastTimer()
    }

    private func startNearbyBrowsing() {
        guard !isStatic, hotspotStartedAt == nil else { return }
        if hotspotBrowser == nil {
            hotspotBrowser = NearbyHotspotBrowser { [weak self] list in
                MainActor.assumeIsolated { self?.applyNearby(list) }
            }
        }
        guard let hotspotBrowser else { return }
        hotspotBrowser.start()
        hotspotStartedAt = Date()
    }

    private func stopNearbyBrowsing() {
        guard hotspotStartedAt != nil else { return }
        hotspotBrowser?.stop()
        hotspotStartedAt = nil
    }

    /// The hotspot advertisement carries a level that can be hours old; a fresh session gives
    /// the phone a chance to re-advertise. Stop + start about once a minute while visible.
    private func restartNearbyBrowsingIfDue() {
        guard let started = hotspotStartedAt, let hotspotBrowser,
              Date().timeIntervalSince(started) >= Self.hotspotRestartInterval else { return }
        hotspotBrowser.stop()
        hotspotBrowser.start()
        hotspotStartedAt = Date()
        nearbyGraceUntil = Date().addingTimeInterval(15)
    }

    /// Display only: hotspot levels are not logged (Insights uses exact data only).
    private func applyNearby(_ list: [DeviceBattery]) {
        let now = Date()
        if list.isEmpty, !nearbyDevices.isEmpty, now < nearbyGraceUntil { return }
        let stamped = HotspotParser.carryUpdatedAt(previous: nearbyDevices, current: list, now: now)
        if stamped != nearbyDevices { nearbyDevices = stamped }
    }

    /// Keeps each device's last exact reading for when it disconnects; written to disk when it
    /// changes (at most every few minutes otherwise) and right away when a device drops off.
    private func rememberExact(_ list: [DeviceBattery]) {
        guard let lastExactStore else { return }
        _ = try? lastExactStore.remember(list)
        let ids = Set(list.map(\.id))
        if mobileDevices.contains(where: { !ids.contains($0.id) }) { try? lastExactStore.flush() }
        let remembered = lastExactStore.devices
        if remembered != rememberedDevices { rememberedDevices = remembered }
    }

    // MARK: Charge log (F11)

    private func recordCharge(_ s: BatterySnapshot) {
        let sample = ChargeSample(date: s.timestamp, percent: Double(s.chargePercent), isCharging: s.isCharging)
        record(key: ChargeLog.thisMacID, name: mac.name, kind: nil, model: mac.identifier, sample: sample)
    }

    /// Exact iPhone / iPad readings only (`ChargeLog.exactSample` skips everything else).
    private func logDevices(_ list: [DeviceBattery]) {
        let now = Date()
        for d in list {
            guard let entry = ChargeLog.exactSample(for: d, at: now) else { continue }
            record(key: entry.key, name: d.name, kind: d.kind, model: d.model, sample: entry.sample)
        }
    }

    private func record(key: String, name: String, kind: DeviceBattery.Kind?, model: String?, sample: ChargeSample) {
        guard let chargeStore,
              (try? chargeStore.record(key: key, name: name, kind: kind, model: model, sample: sample)) == .appended
        else { return }
        publishChargeLogs()
    }

    /// Run extensions only change memory; the 5-minute tick and every append publish them.
    private func publishChargeLogs() {
        guard let chargeStore else { return }
        let logs = Self.sorted(chargeStore.logs)
        if logs != chargeLogs { chargeLogs = logs }
    }

    /// This Mac first, then by name.
    private static func sorted(_ logs: [String: ChargeLog]) -> [ChargeLog] {
        logs.values.sorted { a, b in
            if a.isThisMac != b.isThisMac { return a.isThisMac }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
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
