import AppKit
import BatteryKit
import SwiftUI

/// F9 — About (Settings › About): icon, name, version, author, privacy, credits, diagnostics.
/// Pure drawing (the button uses the custom pill style under `--render`), so the Settings tab
/// shows it directly at a fixed width.
struct AboutContent: View {
    let info: AboutInfo
    /// Builds the diagnostics text at click time, so it reflects the latest snapshot.
    let diagnostics: () -> String
    @State private var copied: Bool
    @State private var copyCount = 0

    init(info: AboutInfo, diagnostics: @escaping () -> String, showsCopied: Bool = false) {
        self.info = info
        self.diagnostics = diagnostics
        _copied = State(initialValue: showsCopied)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AboutHeader(info: info)
            WindowCard {
                VStack(spacing: 0) {
                    WindowRowList(rows: [
                        WindowRow(label: "Author", value: AboutInfo.author),
                        WindowRow(label: "System", value: info.systemLine),
                    ])
                    WindowHairline()
                    diagnosticsFooter
                }
            }
            AboutPrivacyCard()
            VStack(alignment: .leading, spacing: 4) {
                Text("Credits").font(.headline)
                Text(AboutInfo.credits)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)
            Text(info.copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .padding(20)
    }

    private var diagnosticsFooter: some View {
        HStack(spacing: 10) {
            // The confirmation takes the hint's place so the card never changes height.
            if copied {
                Label("Copied to clipboard", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else {
                Text("Paste this into bug reports.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            Button("Copy Diagnostics", action: copy)
                .windowPillButton()
                .help("Copy app, macOS, Mac and battery details as plain text")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnostics(), forType: .string)
        copyCount += 1
        let token = copyCount
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            // A newer click restarts the timer.
            guard token == copyCount else { return }
            withAnimation(.easeIn(duration: 0.3)) { copied = false }
        }
    }
}

// MARK: - Pieces

private struct AboutHeader: View {
    let info: AboutInfo

    var body: some View {
        VStack(spacing: 6) {
            AboutAppIcon(image: info.icon)
                .padding(.bottom, 4)
            Text(AboutInfo.appName)
                .font(.title2.weight(.semibold))
            Text(info.versionLine)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.enabled)
            Text(AboutInfo.tagline)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

private struct AboutAppIcon: View {
    let image: NSImage?
    private let size: CGFloat = 88

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Drawn stand-in when no icon file can be found (unbundled runs outside the repo).
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(Color.green.gradient)
                    .padding(size * 0.08)
                    .overlay(
                        Image(systemName: "battery.75percent")
                            .font(.system(size: size * 0.4, weight: .medium))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct AboutPrivacyCard: View {
    var body: some View {
        WindowCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 20, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Privacy").font(.headline)
                    Text(AboutInfo.privacy)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }
}

// MARK: - App info

/// Everything About shows that depends on the bundle or the machine. Render entries
/// build it with fixed values; Settings uses `current(mac:)`.
struct AboutInfo {
    static let appName = "BatterySoH"
    static let author = "Peter Quoc"
    static let tagline = "A lightweight battery and charger monitor for your Mac."
    static let privacy = "BatterySoH works offline. It reads battery data from macOS and never sends anything anywhere."
    static let credits = "Data from IOKit (AppleSmartBattery), IOPowerSources and the SMC."

    // Fallbacks for unbundled runs (`swift run`, `--render`), where Bundle.main has no
    // Info.plist. Keep in sync with Resources/Info.plist.
    static let fallbackVersion = "0.2.0"
    static let fallbackBuild = "3"
    static let fallbackCopyright = "© 2026 Peter Quoc"

    // TODO(About links): website URL — not chosen yet. Add a link row to AboutContent once set.
    static let websiteURL: URL? = nil
    // TODO(About links): support email (mailto:) — not chosen yet.
    static let supportEmail: String? = nil
    // TODO(About links): license URL / license text — license not chosen yet.
    static let licenseURL: URL? = nil

    var version: String
    var build: String
    var copyright: String
    /// "macOS 27.2 (27C61)"
    var osVersion: String
    var mac: MacInfo
    var icon: NSImage?

    /// "Version 0.2.0 (3)"
    var versionLine: String { "Version \(version) (\(build))" }

    /// "macOS 27.2 · Mac16,8"
    var systemLine: String {
        let short = osVersion.components(separatedBy: " (").first ?? osVersion
        return "\(short) · \(mac.identifier)"
    }

    @MainActor
    static func current(mac: MacInfo) -> AboutInfo {
        let bundle = Bundle.main
        func string(_ key: String) -> String? {
            guard let s = bundle.object(forInfoDictionaryKey: key) as? String, !s.isEmpty else { return nil }
            return s
        }
        return AboutInfo(version: string("CFBundleShortVersionString") ?? fallbackVersion,
                         build: string("CFBundleVersion") ?? fallbackBuild,
                         copyright: string("NSHumanReadableCopyright") ?? fallbackCopyright,
                         osVersion: currentOSVersion(),
                         mac: mac,
                         icon: appIcon())
    }

    /// "macOS 27.2 (27C61)"; the build part is dropped if sysctl doesn't answer.
    static func currentOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var text = "macOS \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { text += ".\(v.patchVersion)" }
        if let build = sysctlString("kern.osversion") { text += " (\(build))" }
        return text
    }

    /// The bundle's icon when running as an .app; otherwise `Resources/AppIcon.icns` found next
    /// to or above the executable (the repo during `swift run` / `--render`); nil → drawn stand-in.
    @MainActor
    static func appIcon() -> NSImage? {
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "app" {
            if let icon = NSApp?.applicationIconImage { return icon }
            if let url = bundle.url(forResource: "AppIcon", withExtension: "icns") {
                return NSImage(contentsOf: url)
            }
        }
        guard let exe = bundle.executableURL?.resolvingSymlinksInPath() else { return nil }
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/AppIcon.icns")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return NSImage(contentsOf: candidate)
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buffer)
        return s.isEmpty ? nil : s
    }
}

// MARK: - Diagnostics

enum AboutDiagnostics {
    /// Plain-text report for bug reports. No serial number: it identifies the user's machine.
    static func report(info: AboutInfo, snapshot: BatterySnapshot?, lowPowerMode: Bool,
                       generated: Date = Date()) -> String {
        var lines: [String] = []
        func row(_ label: String, _ value: String) {
            lines.append(label.padding(toLength: 16, withPad: " ", startingAt: 0) + value)
        }
        let mac = info.mac

        lines.append("\(AboutInfo.appName) \(info.version) (\(info.build))")
        row("Generated", generated.formatted(Date.ISO8601FormatStyle(timeZone: .current)))
        row("macOS", info.osVersion.replacingOccurrences(of: "macOS ", with: ""))
        row("Mac", mac.name + (mac.detail.map { " (\($0))" } ?? ""))
        row("Chip", mac.chip ?? Fmt.dash)
        row("Identifier", mac.identifier)
        row("Low Power Mode", lowPowerMode ? "On" : "Off")
        lines.append("")

        guard let s = snapshot else {
            lines.append("Battery: none found")
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append("Battery")
        row("Charge", "\(s.chargePercent)% (\(Fmt.percent(s.rawChargePercent, decimals: 1)) raw, \(Fmt.mAh(s.currentCapacityMAh)))")
        row("Health", "\(Fmt.percent(s.healthPercent, decimals: 1)) (\(Fmt.mAh(s.fullChargeCapacityMAh)) of \(Fmt.mAh(s.designCapacityMAh)))")
        row("Cycles", "\(s.cycleCount.map(String.init) ?? Fmt.dash)\(s.designCycleCount.map { " of \($0)" } ?? "")")
        row("Temperature", Fmt.temperature(s.temperatureC))
        row("Power state", "\(s.statusTitle) [\(s.powerState.rawValue)]")
        row(s.powerState == .charging ? "Time to full" : "Time to empty", Fmt.duration(minutes: s.minutesRemaining))
        if s.isChargeOnHold {
            row("On hold reason", String(format: "0x%08X", s.notChargingReason ?? 0))
        }
        row("Battery", "\(Fmt.volts(mV: s.voltageMV)) · \(Fmt.amps(mA: s.amperageMA)) · \(Fmt.watts(s.batteryPowerW, signed: true))")
        row("Mac uses", Fmt.watts(s.macLoadW))
        row("Power in", Fmt.watts(s.systemPowerInW))
        if let a = s.adapter {
            row("Adapter", "\(a.watts.map { "\($0) W" } ?? Fmt.dash) · \(a.displayKind) (\(a.description ?? Fmt.dash))")
            if let p = a.activeProfile {
                row("Active profile", "\(Fmt.volts(mV: p.voltageMV)) · \(Fmt.amps(mA: p.currentMA))")
            }
            if !a.profiles.isEmpty {
                row("PD profiles", a.profiles.map(Fmt.profile).joined(separator: "  "))
            }
        } else {
            row("Adapter", s.externalConnected ? "connected (no details)" : "not connected")
        }
        row("Gauge", s.gaugeName ?? Fmt.dash)
        return lines.joined(separator: "\n") + "\n"
    }
}
