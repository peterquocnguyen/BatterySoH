import BatteryKit
import SwiftUI

// Sidebar of the main window: one row per device — This Mac, then iPhone / iPad, then
// accessories. The live window shows the rows in a native sidebar `List`; `--render` draws the
// same rows with `WindowSidebarRendering` (ImageRenderer can't draw a List).

/// One sidebar row. `id` is what the selection stores: `thisMacID` or a `DeviceBattery.id`.
struct WindowSidebarItem: Identifiable, Equatable {
    static let thisMacID = "this-mac"

    let id: String
    let name: String
    let symbol: String
    /// "64%", "≈ 75%"; nil when unknown (untrusted iPad, a Mac without a battery).
    let percentText: String?
    let isCharging: Bool
    /// Not a live reading (last exact one, or a hotspot level): drawn faded.
    let isFaded: Bool
}

struct WindowSidebarSection: Identifiable, Equatable {
    /// nil: no header (This Mac sits above the sections).
    let title: String?
    let items: [WindowSidebarItem]
    var id: String { title ?? "" }

    /// This Mac, "iPhone & iPad", "Accessories" (empty sections dropped).
    static func all(mac: MacInfo, snapshot: BatterySnapshot?, devices: [DeviceBattery]) -> [WindowSidebarSection] {
        let thisMac = WindowSidebarItem(
            id: WindowSidebarItem.thisMacID, name: "This Mac", symbol: mac.symbol,
            percentText: snapshot.map { "\($0.chargePercent)%" },
            isCharging: snapshot?.powerState == .charging, isFaded: false)
        let mobile = devices.filter(\.isMobileDevice).map(\.sidebarItem)
        let accessories = devices.filter { !$0.isMobileDevice }.map(\.sidebarItem)
        return [
            WindowSidebarSection(title: nil, items: [thisMac]),
            WindowSidebarSection(title: "iPhone & iPad", items: mobile),
            WindowSidebarSection(title: "Accessories", items: accessories),
        ]
        .filter { !$0.items.isEmpty }
    }
}

extension DeviceBattery {
    fileprivate var sidebarItem: WindowSidebarItem {
        WindowSidebarItem(
            id: id, name: name, symbol: symbol, percentText: percent.map(percentLabel),
            isCharging: isCharging && isLive, isFaded: !isLive)
    }
}

/// Glyph, name, and percent on the right (bolt when charging). Shared by the live List and the
/// render harness.
struct WindowSidebarRow: View {
    let item: WindowSidebarItem

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(item.name).lineLimit(1)
            } icon: {
                Image(systemName: item.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 20)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if item.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                }
                Text(item.percentText ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
        .opacity(item.isFaded ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [item.name]
        if let percent = item.percentText {
            parts.append(percent.hasPrefix("≈") ? "about \(percent.dropFirst(2))" : percent)
        }
        if item.isCharging { parts.append("charging") }
        if item.isFaded { parts.append("not live") }
        return parts.joined(separator: ", ")
    }
}

/// The live sidebar: a native source list (glass on macOS 26+).
struct WindowSidebar: View {
    let sections: [WindowSidebarSection]
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                if let title = section.title {
                    Section(title) { rows(section) }
                } else {
                    rows(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !hasMobileDevices { WindowSidebarHint().padding(12) }
        }
    }

    private func rows(_ section: WindowSidebarSection) -> some View {
        ForEach(section.items) { item in
            WindowSidebarRow(item: item).tag(item.id)
        }
    }

    private var hasMobileDevices: Bool { sections.contains { $0.title == "iPhone & iPad" } }
}

/// Shown at the foot of the sidebar while no iPhone / iPad is listed.
struct WindowSidebarHint: View {
    var body: some View {
        Label {
            Text("iPhone and iPad show up here when connected by cable or Wi-Fi sync, or nearby on your Apple Account.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `--render` stand-in for `WindowSidebar`: the same rows and headers, drawn without a List.
struct WindowSidebarRendering: View {
    let sections: [WindowSidebarSection]
    let selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                if let title = section.title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }
                ForEach(section.items) { item in
                    WindowSidebarRow(item: item)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background {
                            if item.id == selection {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.09))
                            }
                        }
                }
            }
            Spacer(minLength: 12)
            if !sections.contains(where: { $0.title == "iPhone & iPad" }) {
                WindowSidebarHint().padding(.horizontal, 4)
            }
        }
        .padding(10)
    }
}

extension MacInfo {
    var isLaptop: Bool { name.localizedCaseInsensitiveContains("book") }
    var symbol: String { isLaptop ? "laptopcomputer" : "desktopcomputer" }
}
