import AppKit
import BatteryKit
import SwiftUI

/// "Devices" tab: batteries of other devices this Mac can see — iPhone / iPad over USB or
/// Wi-Fi sync (or their last exact reading, or a Personal Hotspot level), and Bluetooth / USB
/// accessories. Pure drawing, like the other tab contents.
struct WindowDevicesContent: View {
    let devices: [DeviceBattery]
    let temperatureUnit: Fmt.TemperatureUnit
    /// Clock for the "Updated …" captions. nil: the real time, redrawn every 30 s.
    var now: Date?
    /// Opens Finder for the Wi-Fi sync setup (hotspot-only iPhone / iPad).
    var onOpenFinder: () -> Void = {}

    var body: some View {
        if let now {
            content(now: now)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if devices.isEmpty {
                WindowNoDevices()
            } else {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        ForEach(section.devices) { device in
                            WindowDeviceCard(device: device, temperatureUnit: temperatureUnit, now: now,
                                             onOpenFinder: onOpenFinder)
                        }
                    }
                }
            }
            WindowDevicesFootnote()
        }
        .padding(20)
    }

    private var sections: [(title: String, devices: [DeviceBattery])] {
        let mobile = devices.filter(\.isMobileDevice)
        let accessories = devices.filter { !$0.isMobileDevice }
        return [("iPhone & iPad", mobile), ("Accessories", accessories)].filter { !$0.devices.isEmpty }
    }
}

// MARK: - Device card

private struct WindowDeviceCard: View {
    let device: DeviceBattery
    let temperatureUnit: Fmt.TemperatureUnit
    let now: Date
    let onOpenFinder: () -> Void

    /// Not a live reading (last exact one, or a hotspot level): the values are drawn faded.
    private var fade: Double { device.isLive ? 1 : 0.55 }

    var body: some View {
        WindowCard {
            VStack(alignment: .leading, spacing: 0) {
                summary.padding(14)
                if device.hasHealth {
                    WindowHairline()
                    WindowRowList(rows: device.healthRows(unit: temperatureUnit))
                        .padding(.vertical, 2)
                        .opacity(fade)
                }
                if device.needsWiFiSyncSetup {
                    WindowHairline()
                    WindowWiFiSyncSetup(kind: device.kind, prominent: true, onOpenFinder: onOpenFinder)
                        .padding(14)
                }
            }
        }
    }

    /// Name, percent, charge bar(s), how current the reading is, and any note.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if device.parts.isEmpty {
                if let percent = device.percent {
                    WindowMeterBar(fraction: Double(percent) / 100, label: device.percentLabel(percent),
                                   tint: device.chargeTint(percent))
                        .padding(.top, 10)
                        .opacity(fade)
                }
            } else {
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
                .padding(.top, 10)
            }
            if let caption = device.freshnessCaption(now: now) {
                Label(caption, systemImage: device.isLastKnown ? "wifi.slash" : "clock")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            if let note = device.note {
                Label(note, systemImage: device.isApproximate ? "clock.arrow.circlepath" : "lock.iphone")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .opacity(fade)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: device.symbol)
                .font(.system(size: 24, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(device.isLive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 36, height: 32)
                .opacity(fade)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(fade)
                    if device.isApproximate { WindowNotLiveBadge() }
                }
                if let subtitle = device.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(fade)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            trailing.opacity(fade)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let percent = device.percent, device.isApproximate {
            VStack(alignment: .trailing, spacing: 1) {
                Text(device.percentLabel(percent))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                if let since = device.updatedAt {
                    Text("since \(since.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("About \(percent) percent, last shared level, not live")
        } else if let percent = device.percent {
            HStack(spacing: 3) {
                if device.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                }
                Text("\(percent)%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(percent) percent\(device.isCharging ? ", charging" : "")\(device.isLastKnown ? ", last reading, not connected" : "")")
        } else {
            Text(Fmt.dash)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tertiary)
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

// MARK: - Wi-Fi sync setup (hotspot-only iPhone / iPad, Insights without exact data)

/// How to get exact values for a device seen only through Personal Hotspot.
/// `prominent`: the primary element of its card (accent-tinted, filled button).
struct WindowWiFiSyncSetup: View {
    let kind: DeviceBattery.Kind
    var prominent = false
    let onOpenFinder: () -> Void

    private var device: String { kind == .iPad ? "iPad" : "iPhone" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Get the live level", systemImage: "cable.connector")
                .font(prominent ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text("For the live level, charging state, health and cycles: connect the \(device) by cable once, unlock it and tap Trust, then in Finder select it and turn on “Show this \(device) when on Wi-Fi”. After that Battery Buddy reads it wirelessly whenever both are on the same Wi-Fi.")
                .font(.callout)
                .foregroundStyle(prominent ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Finder", action: onOpenFinder)
                .windowPillButton(prominent: prominent)
                .help("Open Finder to turn on Wi-Fi sync for this \(device)")
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            shape.fill(Color.accentColor.opacity(prominent ? 0.12 : 0.08))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(prominent ? 0.35 : 0), lineWidth: 1))
        }
    }
}

// MARK: - Empty state and footnote

private struct WindowNoDevices: View {
    var body: some View {
        WindowCard {
            VStack(spacing: 8) {
                Image(systemName: "ipad.and.iphone")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No other devices")
                    .font(.headline)
                Text("Connect an iPhone or iPad, or turn on a Bluetooth accessory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 16)
        }
    }
}

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

    /// "Updated just now" / "Last updated 12:40 · not connected"; nil for accessories and
    /// hotspot levels (those say "since 12:03" next to the level).
    func freshnessCaption(now: Date) -> String? {
        guard isIOSDevice, !isApproximate, percent != nil, let updatedAt else { return nil }
        let when = Fmt.freshness(updatedAt, now: now)
        return isLastKnown ? "Last updated \(when) · not connected" : "Updated \(when)"
    }

    /// "iOS 26.1 · USB · iPhone18,1", "Bluetooth".
    fileprivate var subtitle: String? {
        let parts = [osVersion, connection?.label, model].compactMap { $0 }
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
