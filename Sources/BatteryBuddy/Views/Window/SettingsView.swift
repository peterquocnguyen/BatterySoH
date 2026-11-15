import BatteryKit
import ServiceManagement
import SwiftUI

/// F6 — Settings scene. Values live in UserDefaults under `SettingsKey`.
struct SettingsView: View {
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
                Toggle("Show watts instead of time", isOn: $showWatts)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Precise percentage is the battery gauge's raw value (e.g. 79.0%); macOS rounds it differently. Watts are the battery's charge or discharge rate.")
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

            Section("General") {
                Toggle("Launch at login", isOn: launchBinding)
                if launchStatus == .requiresApproval {
                    HStack {
                        Text("Allow Battery Buddy in System Settings › Login Items.")
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
        .frame(width: 440)
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

enum SettingsRefreshOption: Double, CaseIterable, Identifiable {
    case one = 1, two = 2, five = 5

    var id: Double { rawValue }
    var seconds: Double { rawValue }
    var label: String { "\(Int(rawValue)) s" }
}
