import BatteryKit
import ServiceManagement
import SwiftUI

/// F6 / F9 — Settings scene: "General" (every setting) and "About". Values live in
/// UserDefaults under `SettingsKey`.
struct SettingsView: View {
    var body: some View {
        TabView {
            SettingsGeneralView()
                .tabItem { Label("General", systemImage: "gearshape") }
            SettingsAboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

enum SettingsLayout {
    /// Both tabs share the width; each sets its own height, and the window resizes to the tab.
    static let width: CGFloat = 440
}

/// F6 — the General tab.
struct SettingsGeneralView: View {
    @Environment(BatteryModel.self) private var model

    @AppStorage(SettingsKey.showPercent) private var showPercent = true
    @AppStorage(SettingsKey.showTime) private var showTime = true
    @AppStorage(SettingsKey.showWatts) private var showWatts = false
    @AppStorage(SettingsKey.precisePercent) private var precisePercent = false
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval: Double = 2
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnit: Fmt.TemperatureUnit = .celsius

    @State private var launchAtLogin = false
    @State private var launchStatus: SMAppService.Status = .notRegistered
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show percentage", isOn: $showPercent)
                Toggle("Show precise percentage in menu bar", isOn: $precisePercent)
                    .disabled(!showPercent)
                Toggle("Show time remaining", isOn: $showTime)
                Toggle("Show charging watts instead of time", isOn: $showWatts)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text(
                    "Precise percentage is the battery gauge's raw value (e.g. 79.0%); macOS rounds it differently. Charging watts show only while the battery charges; on battery the time left shows instead."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Display") {
                Picker("Refresh while open", selection: $refreshInterval) {
                    ForEach(SettingsRefreshOption.allCases) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: refreshInterval) { model.restartFastTimer() }

                Picker("Temperature", selection: $temperatureUnit) {
                    Text("Celsius (°C)").tag(Fmt.TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(Fmt.TemperatureUnit.fahrenheit)
                }
            }

            Section {
                Toggle(
                    "Change Energy Mode without a password",
                    isOn: Binding(
                        get: { model.isPasswordFreeEnergyMode },
                        set: { model.setPasswordFreeEnergyMode($0) }))
                if let error = model.controlError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Energy Mode")
            } footer: {
                Text(
                    "Adds a rule to \(PasswordFreeEnergyMode.sudoersPath) that lets only you run the six `pmset powermode` commands without a password. Turning it on or off asks for your password once."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("General") {
                Toggle("Launch at login", isOn: launchBinding)
                if launchStatus == .requiresApproval {
                    HStack {
                        Text("Allow BatterySoH in System Settings › Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open…") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: syncLaunchStatus)
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { launchAtLogin }, set: setLaunchAtLogin)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Couldn't \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        syncLaunchStatus()
    }

    private func syncLaunchStatus() {
        launchStatus = SMAppService.mainApp.status
        launchAtLogin = launchStatus == .enabled || launchStatus == .requiresApproval
    }
}

/// F9 — the About tab: the custom-drawn `AboutContent` at the tab's width.
struct SettingsAboutView: View {
    @Environment(BatteryModel.self) private var model

    var body: some View {
        AboutContent(info: .current(mac: model.mac)) {
            AboutDiagnostics.report(
                info: .current(mac: model.mac), snapshot: model.snapshot,
                lowPowerMode: model.isLowPowerMode, condition: model.macCondition)
        }
        .frame(width: SettingsLayout.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum SettingsRefreshOption: Double, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case five = 5

    var id: Double { rawValue }
    var seconds: Double { rawValue }
    var label: String { "\(Int(rawValue)) s" }
}

// MARK: - Render entries

enum SettingsRenderEntries {
    @MainActor
    static func all(mac: MacInfo) -> [RenderEntry] {
        let info = AboutInfo(
            version: AboutInfo.fallbackVersion, build: AboutInfo.fallbackBuild,
            copyright: AboutInfo.fallbackCopyright, osVersion: "macOS 27.2 (27C61)",
            mac: mac, icon: AboutInfo.appIcon())
        return [
            RenderEntry("settings-about") {
                AboutContent(info: info, diagnostics: { "" })
                    .frame(width: SettingsLayout.width)
                    .background(Color(nsColor: .windowBackgroundColor))
            },
            RenderEntry("settings-about-copied") {
                AboutContent(info: info, diagnostics: { "" }, showsCopied: true)
                    .frame(width: SettingsLayout.width)
                    .background(Color(nsColor: .windowBackgroundColor))
            },
            RenderEntry("settings-general") {
                // Form controls are AppKit-backed and may draw as placeholders here.
                SettingsGeneralView()
                    .environment(BatteryModel(previewSnapshot: .sampleCharging, history: []))
                    .background(Color(nsColor: .windowBackgroundColor))
            },
        ]
    }
}
