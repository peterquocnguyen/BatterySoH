import AppKit
import BatteryKit
import SwiftUI

/// "Devices" tab: batteries of other devices this Mac can see — iPhone / iPad over USB or
/// Wi-Fi sync, and Bluetooth / USB accessories. Pure drawing, like the other tab contents.
struct WindowDevicesContent: View {
    let devices: [DeviceBattery]
    let temperatureUnit: Fmt.TemperatureUnit

    var body: some View {
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
                            WindowDeviceCard(device: device, temperatureUnit: temperatureUnit)
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

    var body: some View {
        WindowCard {
            VStack(alignment: .leading, spacing: 0) {
                summary.padding(14)
                if device.hasHealth {
                    WindowHairline()
                    WindowRowList(rows: device.healthRows(unit: temperatureUnit))
                        .padding(.vertical, 2)
                }
            }
        }
    }

    /// Name, percent, charge bar(s) and any trust note.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if device.parts.isEmpty {
                if let percent = device.percent {
                    WindowMeterBar(fraction: Double(percent) / 100, label: "\(percent)%",
                                   tint: device.chargeTint(percent))
                        .padding(.top, 10)
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
            if let note = device.note {
                Label(note, systemImage: device.connection == .nearby ? "info.circle" : "lock.iphone")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: device.symbol)
                .font(.system(size: 24, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle = device.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            if let percent = device.percent {
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
                .accessibilityLabel("\(percent) percent\(device.isCharging ? ", charging" : "")")
            } else {
                Text(Fmt.dash)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
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
                     text: "iPhone and iPad show up when connected by cable, or over Wi-Fi with “Show this iPhone when on Wi-Fi” on in Finder, and trusted. Health and cycles need that connection.")
            footnote(symbol: "personalhotspot",
                     text: "Without a cable, an iPhone or cellular iPad on the same Apple Account shows its charge through Personal Hotspot, like the Wi-Fi menu does.")
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

    fileprivate var hasHealth: Bool {
        designCapacityMAh != nil || cycleCount != nil || temperatureC != nil
    }

    /// "iOS 26.1 · USB · iPhone18,1", "Bluetooth".
    fileprivate var subtitle: String? {
        let parts = [osVersion, connection?.label, model].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    fileprivate func chargeTint(_ percent: Int) -> Color {
        if isCharging { return .green }
        if percent <= 10 { return .red }
        if percent <= 20 { return .orange }
        return .green
    }

    fileprivate func healthRows(unit: Fmt.TemperatureUnit) -> [WindowRow] {
        [
            WindowRow(label: "Battery Health", value: Fmt.percent(healthPercent, decimals: 1)),
            WindowRow(label: "Full Charge Capacity", value: Fmt.mAh(fullChargeCapacityMAh)),
            WindowRow(label: "Design Capacity", value: Fmt.mAh(designCapacityMAh)),
            WindowRow(label: "Charge Cycles", value: cycleCount.map(String.init) ?? Fmt.dash),
            WindowRow(label: "Battery Temperature", value: Fmt.temperature(temperatureC, unit: unit)),
        ]
    }

    fileprivate var symbol: String {
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
