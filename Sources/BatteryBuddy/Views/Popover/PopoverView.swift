import BatteryKit
import SwiftUI

// MARK: - F1 Menu bar item

/// Menu bar title: battery glyph + "67.5% (4h 8m)". MenuBarExtra labels only render an
/// Image and a Text, so this stays deliberately flat.
struct MenuBarLabel: View {
    @Environment(BatteryModel.self) private var model
    @AppStorage(SettingsKey.showPercent) private var showPercent = true
    @AppStorage(SettingsKey.showTime) private var showTime = true
    @AppStorage(SettingsKey.showWatts) private var showWatts = false

    var body: some View {
        let snapshot = model.snapshot
        let title = Self.title(for: snapshot, showPercent: showPercent, showTime: showTime, showWatts: showWatts)
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(for: snapshot))
            if !title.isEmpty {
                Text(title).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.map { "Battery \($0.chargePercent) percent, \($0.statusTitle)" } ?? "No battery")
    }

    static func symbol(for snapshot: BatterySnapshot?) -> String {
        guard let snapshot else { return "battery.0percent" }
        if snapshot.powerState == .charging { return "battery.100percent.bolt" }
        switch snapshot.chargePercent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    /// "67.5% (4h 8m)", "71.3% (+47.2 W)", "80%", "4h 8m", or "" (glyph only).
    static func title(for snapshot: BatterySnapshot?, showPercent: Bool, showTime: Bool, showWatts: Bool) -> String {
        guard let snapshot else { return showPercent ? Fmt.dash : "" }
        let percent = snapshot.rawChargePercent.map { String(format: "%.1f%%", $0) } ?? "\(snapshot.chargePercent)%"

        var extra: String?
        if showWatts {
            if let w = snapshot.batteryPowerW, abs(w) >= 0.05 { extra = Fmt.watts(w, signed: true) }
        } else if showTime, let minutes = snapshot.minutesRemaining, minutes > 0 {
            extra = Fmt.duration(minutes: minutes)
        }

        switch (showPercent, extra) {
        case (true, let extra?): return "\(percent) (\(extra))"
        case (true, nil): return percent
        case (false, let extra?): return extra
        case (false, nil): return ""
        }
    }
}

// MARK: - F2 / F3 Popover

struct PopoverView: View {
    @Environment(BatteryModel.self) private var model
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnit: Fmt.TemperatureUnit = .celsius
    @State private var isVisible = false

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = model.snapshot {
                content(PopoverDisplay(snapshot: snapshot, temperatureUnit: temperatureUnit))
            } else {
                PopoverNoBattery()
                    .padding(.bottom, 16)
            }
            Divider()
                .padding(.bottom, 10)
            PopoverFooter()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            isVisible = true
            model.surfaceAppeared()
        }
        .onDisappear {
            isVisible = false
            model.surfaceDisappeared()
        }
    }

    @ViewBuilder
    private func content(_ display: PopoverDisplay) -> some View {
        PopoverHeader(display: display)
            .padding(.bottom, 22)
        PopoverFlowDiagram(display: display, isVisible: isVisible)
            .padding(.bottom, 16)
        Divider()
            .padding(.bottom, 12)
        PopoverTiles(display: display)
            .padding(.bottom, 12)
        if !display.profiles.isEmpty {
            PopoverProfileChips(display: display)
                .padding(.bottom, 14)
        }
        Divider()
            .padding(.bottom, 12)
        PopoverSummary(display: display)
            .padding(.bottom, 14)
    }
}

// MARK: - Render harness entries

enum PopoverRenderEntries {
    @MainActor
    static func all() -> [RenderEntry] {
        var entries = BatterySnapshot.allSamples.map { sample in
            RenderEntry("popover-\(sample.name)") {
                PopoverView()
                    .environment(BatteryModel(previewSnapshot: sample.snapshot, history: []))
                    .environment(\.popoverStaticFrame, true)
                    .popoverRenderBackground()
            }
        }
        entries.append(RenderEntry("popover-no-battery") {
            PopoverView()
                .environment(BatteryModel(previewSnapshot: nil, history: []))
                .environment(\.popoverStaticFrame, true)
                .popoverRenderBackground()
        })
        entries.append(RenderEntry("popover-menubar-labels") {
            PopoverMenuBarLabelGallery().popoverRenderBackground()
        })
        return entries
    }
}

private extension View {
    /// The harness applies its window background outside its colour-scheme override, so it
    /// always resolves light. Paint our own inside the override so dark renders are honest.
    func popoverRenderBackground() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Every sample's menu bar title in a strip, plus the settings variants, for visual checks.
private struct PopoverMenuBarLabelGallery: View {
    var body: some View {
        let samples: [(String, BatterySnapshot?)] = BatterySnapshot.allSamples.map { ($0.name, $0.snapshot) }
            + [("no-battery", nil)]
        VStack(alignment: .leading, spacing: 6) {
            ForEach(samples, id: \.0) { name, snapshot in
                HStack(spacing: 12) {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    MenuBarLabel()
                        .environment(BatteryModel(previewSnapshot: snapshot, history: []))
                        .font(.system(size: 13))
                    Text("watts: " + MenuBarLabel.title(for: snapshot, showPercent: true, showTime: true, showWatts: true))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
    }
}
