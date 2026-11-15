import AppKit
import BatteryKit
import SwiftUI

/// F10 — the page for one other device: an iPhone / iPad over USB or Wi-Fi sync (or its last
/// exact reading, or a Personal Hotspot level), or a Bluetooth / USB accessory. Pure drawing,
/// like the This Mac page; the window wraps it in a ScrollView.
struct WindowDevicePage: View {
    let device: DeviceBattery
    let temperatureUnit: Fmt.TemperatureUnit
    /// Clock for the "Updated …" caption. nil: the real time, redrawn every 30 s.
    var now: Date?
    /// Opens Finder for the Wi-Fi sync setup (hotspot-only iPhone / iPad).
    var onOpenFinder: () -> Void = {}

    var body: some View {
        if let now {
            content(now: now)
        } else if device.isIOSDevice {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
        } else {
            content(now: Date())
        }
    }

    /// Not a live reading (last exact one, or a hotspot level): the values are drawn faded.
    private var fade: Double { device.isLive ? 1 : 0.55 }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            WindowDeviceHeader(device: device, fade: fade)
            WindowDeviceChargeCard(device: device, now: now, fade: fade)
            if device.hasHealth {
                WindowCard {
                    WindowRowList(rows: device.healthRows(unit: temperatureUnit))
                }
                .opacity(fade)
            }
            if device.needsWiFiSyncSetup {
                WindowWiFiSyncSetup(kind: device.kind, onOpenFinder: onOpenFinder)
            }
            if device.isMobileDevice {
                WindowDevicesFootnote()
                    .padding(.top, 4)
            }
        }
        .padding(20)
    }
}

// MARK: - Header

/// Glyph, name (+ "Not live"), "iOS 26.1 · USB", model identifier — like the This Mac header.
private struct WindowDeviceHeader: View {
    let device: DeviceBattery
    let fade: Double

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: device.symbol)
                .font(.system(size: 40, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(device.isLive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 64, height: 52)
                .opacity(fade)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(device.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .opacity(fade)
                    if device.isApproximate { WindowNotLiveBadge() }
                }
                Group {
                    if let line = device.detailLine {
                        Text(line)
                            .foregroundStyle(.secondary)
                    }
                    if let model = device.model {
                        Text(model)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .padding(.top, 2)
                            .help("Device identifier")
                            .accessibilityLabel("Device identifier \(model)")
                    }
                }
                .opacity(fade)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Charge

/// "Battery Charge": one bar (or Left / Right / Case bars), how current the reading is, and any
/// note (trust needed, hotspot level).
private struct WindowDeviceChargeCard: View {
    let device: DeviceBattery
    let now: Date
    let fade: Double

    var body: some View {
        WindowCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Battery Charge").font(.headline)
                    Spacer()
                    if device.isApproximate, let since = device.updatedAt {
                        Text("since \(since.formatted(date: .omitted, time: .shortened))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // Untrusted iPad / iPhone: no level, the trust note says why.
                if device.percent != nil || !device.parts.isEmpty || device.note == nil {
                    levels.padding(.top, 8)
                }
                if let status = device.statusLine(now: now) {
                    HStack(spacing: 5) {
                        Image(systemName: status.symbol)
                            .foregroundStyle(status.tint)
                        Text(status.text)
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .opacity(device.isLastKnown ? fade : 1)
                }
                if let note = device.note {
                    Label(note, systemImage: device.isApproximate ? "clock.arrow.circlepath" : "lock.iphone")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
            .padding(14)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var levels: some View {
        if !device.parts.isEmpty {
            VStack(spacing: 6) {
                ForEach(device.parts) { part in
                    HStack(spacing: 10) {
                        Text(part.name)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        if let p = part.percent {
                            WindowMeterBar(fraction: Double(p) / 100,
                                           label: "\(p)%\(part.isCharging ? " ⚡︎" : "")",
                                           tint: part.isCharging ? .green : device.chargeTint(p))
                        } else {
                            Text(Fmt.dash).foregroundStyle(.tertiary)
                            Spacer()
                        }
                    }
                }
            }
        } else if let percent = device.percent {
            WindowMeterBar(fraction: Double(percent) / 100, label: device.percentLabel(percent),
                           tint: device.chargeTint(percent))
                .opacity(fade)
        } else {
            Text(Fmt.dash).foregroundStyle(.tertiary)
        }
    }
}

/// Small capsule next to the name of a device seen only through Personal Hotspot.
private struct WindowNotLiveBadge: View {
    var body: some View {
        Text("Not live")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .fixedSize()
    }
}

// MARK: - Wi-Fi sync setup (hotspot-only iPhone / iPad)

/// How to get exact values for a device seen only through Personal Hotspot: the primary element
/// of its page (accent-tinted, filled button).
struct WindowWiFiSyncSetup: View {
    let kind: DeviceBattery.Kind
    let onOpenFinder: () -> Void

    private var device: String { kind == .iPad ? "iPad" : "iPhone" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Get the live level", systemImage: "cable.connector")
                .font(.headline)
                .foregroundStyle(.tint)
            Text("For the live level, charging state, health and cycles: connect the \(device) by cable once, unlock it and tap Trust, then in Finder select it and turn on “Show this \(device) when on Wi-Fi”. After that Battery Buddy reads it wirelessly whenever both are on the same Wi-Fi.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Finder", action: onOpenFinder)
                .windowPillButton(prominent: true)
                .help("Open Finder to turn on Wi-Fi sync for this \(device)")
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            shape.fill(Color.accentColor.opacity(0.12))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
        }
    }
}

// MARK: - Footnote (iPhone / iPad pages)

/// How iPhone / iPad get here, what a hotspot level is, and why Apple Watch is missing.
private struct WindowDevicesFootnote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            footnote(symbol: "cable.connector",
                     text: "iPhone and iPad show up when connected by cable, or over Wi-Fi with “Show this iPhone when on Wi-Fi” on in Finder, and trusted. Health and cycles need that connection. When it drops (iPhone asleep or away), the last reading stays, marked not connected.")
            footnote(symbol: "personalhotspot",
                     text: "Without a cable, an iPhone or cellular iPad on the same Apple Account shares a level through Personal Hotspot, like the Wi-Fi menu shows. It is approximate and can lag well behind the device.")
            footnote(symbol: "applewatch",
                     text: "Apple Watch doesn’t share its battery with a Mac. Check it on iPhone in the Batteries widget.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func footnote(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 14)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Derived display values

extension DeviceBattery {
    var isMobileDevice: Bool { [.iPhone, .iPad, .iPod, .watch].contains(kind) }

    /// A current exact reading (or an accessory): drawn at full strength.
    var isLive: Bool { !isApproximate && !isLastKnown }

    var hasHealth: Bool {
        designCapacityMAh != nil || cycleCount != nil || temperatureC != nil
    }

    /// The line under the charge bar: "Charging · Updated just now", "Updated 3 min ago",
    /// "Last updated 12:40 · not connected", "Charging" (accessory). nil for hotspot levels
    /// (they say "since 12:03" next to the heading) and when there is nothing to say.
    fileprivate func statusLine(now: Date) -> (symbol: String, tint: Color, text: String)? {
        guard !isApproximate, percent != nil else { return nil }
        guard isIOSDevice, let updatedAt else {
            return isCharging ? ("bolt.fill", .green, "Charging") : nil
        }
        let when = Fmt.freshness(updatedAt, now: now)
        if isLastKnown { return ("wifi.slash", .secondary, "Last updated \(when) · not connected") }
        if isCharging { return ("bolt.fill", .green, "Charging · Updated \(when)") }
        return ("clock", .secondary, "Updated \(when)")
    }

    /// "iOS 26.1 · USB", "Bluetooth"; the model identifier is drawn separately.
    fileprivate var detailLine: String? {
        let parts = [osVersion, connection?.label].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Seen only through Personal Hotspot: show how to turn on Wi-Fi sync.
    fileprivate var needsWiFiSyncSetup: Bool { isApproximate && [.iPhone, .iPad].contains(kind) }

    /// "75%", or "≈ 75%" for an advertised (approximate) level.
    func percentLabel(_ percent: Int) -> String {
        isApproximate ? "≈ \(percent)%" : "\(percent)%"
    }

    /// Neutral when the level isn't live: no green "all good" (or charging) claim.
    func chargeTint(_ percent: Int) -> Color {
        if !isLive { return .gray }
        if isCharging { return .green }
        if percent <= 10 { return .red }
        if percent <= 20 { return .orange }
        return .green
    }

    func healthRows(unit: Fmt.TemperatureUnit) -> [WindowRow] {
        [
            WindowRow(label: "Battery Health", value: Fmt.percent(healthPercent, decimals: 1)),
            WindowRow(label: "Full Charge Capacity", value: Fmt.mAh(fullChargeCapacityMAh)),
            WindowRow(label: "Design Capacity", value: Fmt.mAh(designCapacityMAh)),
            WindowRow(label: "Charge Cycles", value: cycleCount.map(String.init) ?? Fmt.dash),
            WindowRow(label: "Battery Temperature", value: Fmt.temperature(temperatureC, unit: unit)),
        ]
    }

    var symbol: String {
        let lowerName = name.lowercased()
        let candidates: [String]
        switch kind {
        case .iPhone: candidates = ["iphone"]
        case .iPad: candidates = ["ipad"]
        case .iPod: candidates = ["ipodtouch", "iphone"]
        case .watch: candidates = ["applewatch"]
        case .airPods:
            if lowerName.contains("max") { candidates = ["airpodsmax", "headphones"] }
            else if lowerName.contains("pro") { candidates = ["airpodspro", "airpods"] }
            else { candidates = ["airpods.gen3", "airpods"] }
        case .headphones: candidates = ["headphones"]
        case .mouse: candidates = ["magicmouse", "computermouse"]
        case .keyboard: candidates = ["keyboard"]
        case .trackpad: candidates = ["rectangle.and.hand.point.up.left", "hand.point.up.left"]
        case .gameController: candidates = ["gamecontroller"]
        case .pencil: candidates = ["applepencil", "pencil"]
        case .other: candidates = ["battery.75percent"]
        }
        return candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            ?? "battery.75percent"
    }
}

private extension DeviceBattery.Connection {
    var label: String {
        switch self {
        case .usb: return "USB"
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .nearby: return "Nearby"
        case .other: return "Connected"
        }
    }
}
