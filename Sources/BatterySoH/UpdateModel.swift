import AppKit
import BatteryKit
import Foundation
import Observation

/// F12 — update check state. Manual checks from Settings; automatic ones (opt-in, at most once a
/// day) at launch and from an hourly timer. Never downloads or installs anything itself: an
/// available update links to its GitHub release page.
@Observable
@MainActor
final class UpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(AppRelease)
        case failed(String)
    }

    private(set) var state: State
    let currentVersion: String

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private let isStatic: Bool
    @ObservationIgnored private let defaults: UserDefaults

    /// Live model: runs an automatic check now if one is due and the user turned them on.
    init(currentVersion: String = AboutInfo.bundleVersion, defaults: UserDefaults = .standard) {
        isStatic = false
        self.currentVersion = currentVersion
        self.defaults = defaults
        state = .idle
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutomaticallyIfDue() }
        }
        timer?.tolerance = 5 * 60
        // Give launch a moment before touching the network.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.checkAutomaticallyIfDue()
        }
    }

    /// Static model for `--render`: no timer, no network.
    init(previewState: State, currentVersion: String = AboutInfo.fallbackVersion) {
        isStatic = true
        self.currentVersion = currentVersion
        defaults = .standard
        state = previewState
    }

    var isChecking: Bool { state == .checking }

    var availableRelease: AppRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    var lastCheck: Date? { defaults.object(forKey: SettingsKey.updatesLastCheck) as? Date }

    /// "Check for Updates" in Settings.
    func checkNow() {
        guard !isStatic, !isChecking else { return }
        run()
    }

    func checkAutomaticallyIfDue() {
        guard !isStatic, !isChecking, defaults.bool(forKey: SettingsKey.updatesAutomatic),
            UpdateChecker.isDue(lastCheck: lastCheck)
        else { return }
        run(quietly: true)
    }

    /// Opens the release page (notes + DMG) in the browser.
    func openReleasePage() {
        NSWorkspace.shared.open(availableRelease?.pageURL ?? UpdateChecker.releasesPage)
    }

    /// `quietly`: an automatic check keeps a found update but doesn't replace it with an error,
    /// and never shows "Checking…".
    private func run(quietly: Bool = false) {
        checkTask?.cancel()
        let previous = state
        if !quietly { state = .checking }
        let version = currentVersion
        checkTask = Task { [weak self] in
            let outcome = await UpdateChecker.check(currentVersion: version)
            guard let self, !Task.isCancelled else { return }
            self.apply(outcome, previous: previous, quietly: quietly)
        }
    }

    private func apply(_ outcome: UpdateCheckOutcome, previous: State, quietly: Bool) {
        switch outcome {
        case .available(let release):
            defaults.set(Date(), forKey: SettingsKey.updatesLastCheck)
            state = .available(release)
        case .upToDate:
            defaults.set(Date(), forKey: SettingsKey.updatesLastCheck)
            state = .upToDate(checkedAt: Date())
        case .failed(let message):
            // An automatic check that fails stays silent and retries on the next timer tick.
            state = quietly ? previous : .failed(message)
        }
    }
}
