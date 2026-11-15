import BatteryKit
import SwiftUI

// MARK: - F1 Menu bar item

/// Menu bar item: native-style battery glyph (percent inside, bolt on power) plus optional
/// text beside it (time / watts / precise percent). MenuBarExtra labels only render an Image
/// and a Text, so this stays deliberately flat.
struct MenuBarLabel: View {
    @Environment(BatteryModel.self) private var model
    @AppStorage(SettingsKey.showPercent) private var showPercent = true
    @AppStorage(SettingsKey.showTime) private var showTime = true
    @AppStorage(SettingsKey.showWatts) private var showWatts = false
    @AppStorage(SettingsKey.precisePercent) private var precisePercent = false
    @Environment(\.colorScheme) private var menuBarScheme

    var body: some View {
        let snapshot = model.snapshot
        let title = Self.title(for: snapshot, showPercent: showPercent, showTime: showTime, showWatts: showWatts,
                               precise: precisePercent)
        HStack(spacing: 4) {
            Image(nsImage: MenuBarGlyph.image(Self.glyphStyle(for: snapshot, showPercent: showPercent,
                                                              precise: precisePercent,
                                                              lowPower: model.isLowPowerMode,
                                                              darkMenuBar: menuBarScheme == .dark)))
            if !title.isEmpty {
                Text(title).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(snapshot))
    }

    private func accessibilityText(_ snapshot: BatterySnapshot?) -> String {
        guard let snapshot else { return "No battery" }
        let status = PopoverDisplay(snapshot: snapshot, chargeLimit: model.chargeLimit).statusTitle
        return "Battery \(snapshot.chargePercent) percent, \(status)"
    }

    /// Percent inside the glyph unless hidden or replaced by the precise text; bolt on power.
    static func glyphStyle(for snapshot: BatterySnapshot?, showPercent: Bool, precise: Bool,
                           lowPower: Bool = false, darkMenuBar: Bool = false,
                           pointScale: CGFloat = 1) -> MenuBarGlyph.Style {
        guard let snapshot else { return MenuBarGlyph.Style(percentText: nil, percent: 0, showsBolt: false,
                                                             pointScale: pointScale) }
        return MenuBarGlyph.Style(percentText: showPercent && !precise ? "\(snapshot.chargePercent)" : nil,
                                  percent: snapshot.chargePercent,
                                  showsBolt: snapshot.externalConnected,
                                  lowPower: lowPower, darkMenuBar: lowPower && darkMenuBar,
                                  pointScale: pointScale)
    }

    /// Text beside the glyph: "4h 8m", "+47.2 W", or with `precise` "79.0%" / "79.0% (4h 8m)".
    /// The whole percent lives inside the glyph, so it never appears here.
    static func title(for snapshot: BatterySnapshot?, showPercent: Bool, showTime: Bool, showWatts: Bool,
                      precise: Bool = false) -> String {
        guard let snapshot else { return "" }
        var extra: String?
        // Watts only while charging; on battery (or draining on a charger) the time left is
        // more useful than the discharge rate, so fall back to it.
        if showWatts, let w = snapshot.batteryPowerW, w >= 0.05 {
            extra = Fmt.watts(w, signed: true)
        } else if showTime, let minutes = snapshot.minutesRemaining, minutes > 0 {
            extra = Fmt.duration(minutes: minutes)
        }
        guard showPercent, precise else { return extra ?? "" }
        let percent = snapshot.rawChargePercent.map { String(format: "%.1f%%", $0) } ?? "\(snapshot.chargePercent)%"
        return extra.map { "\(percent) (\($0))" } ?? percent
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
                content(PopoverDisplay(snapshot: snapshot, temperatureUnit: temperatureUnit,
                                       chargeLimit: model.chargeLimit))
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
        .debugWindowDump("popover")
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
            .padding(.bottom, display.heldAtLimitPercent != nil ? 12 : 22)
        if display.heldAtLimitPercent != nil {
            PopoverChargeLimitLine(display: display)
                .padding(.bottom, 16)
        }
        PopoverFlowDiagram(display: display, isVisible: isVisible)
            .padding(.bottom, 16)
        Divider()
            .padding(.bottom, 12)
        PopoverTiles(display: display)
            .padding(.bottom, 12)
        if let drain = display.drainExplanation {
            PopoverDrainBanner(text: drain)
                .padding(.bottom, 12)
        }
        if !display.profiles.isEmpty {
            PopoverProfileChips(display: display)
                .padding(.bottom, 14)
        }
        Divider()
            .padding(.bottom, 12)
        PopoverSummary(display: display)
            .padding(.bottom, 14)
        if PopoverEnergyModeSection.isAvailable(model) {
            Divider()
                .padding(.bottom, 10)
            PopoverEnergyModeSection()
                .padding(.bottom, 12)
        } else if let error = model.controlError {
            PopoverControlError(text: error)
                .padding(.bottom, 12)
        }
    }
}

// MARK: - Render harness entries

enum PopoverRenderEntries {
    /// Static F8 state per sample (the harness never runs pmset or PowerUI).
    static let fullCaps: [PowerSourceKind: Set<EnergyMode>] = [.ac: [.automatic, .lowPower, .highPower],
                                                              .battery: [.automatic, .lowPower]]
    static let limitHolding = ChargeLimitStatus(isEnabled: true, limitPercent: 80, isHoldingCharge: true,
                                                overrideAllowed: true)
    static let limitIdle = ChargeLimitStatus(isEnabled: true, limitPercent: 80, isHoldingCharge: false,
                                             overrideAllowed: true)

    @MainActor
    static func model(_ name: String, _ snapshot: BatterySnapshot?) -> BatteryModel {
        let energy: EnergyModeStatus
        let limit: ChargeLimitStatus?
        switch name {
        case "on-battery", "just-unplugged":
            energy = EnergyModeStatus(modes: [.battery: .lowPower, .ac: .automatic], capabilities: fullCaps)
            limit = limitIdle
        case "on-hold":
            energy = EnergyModeStatus(modes: [.battery: .automatic, .ac: .automatic], capabilities: fullCaps)
            limit = limitHolding
        case "draining":
            energy = EnergyModeStatus(modes: [.battery: .automatic, .ac: .highPower], capabilities: fullCaps)
            limit = limitIdle
        default:
            energy = EnergyModeStatus(modes: [.battery: .automatic, .ac: .automatic], capabilities: fullCaps)
            limit = limitIdle
        }
        return BatteryModel(previewSnapshot: snapshot, history: [], energyStatus: energy, chargeLimit: limit)
    }

    @MainActor
    static func all() -> [RenderEntry] {
        var entries = BatterySnapshot.allSamples.map { sample in
            RenderEntry("popover-\(sample.name)") {
                PopoverView()
                    .environment(model(sample.name, sample.snapshot))
                    .environment(\.popoverStaticFrame, true)
                    .popoverRenderBackground()
            }
        }
        entries.append(RenderEntry("popover-on-hold-charging-to-full") {
            PopoverView()
                .environment(BatteryModel(
                    previewSnapshot: .sampleOnHold, history: [],
                    energyStatus: EnergyModeStatus(modes: [.ac: .highPower, .battery: .automatic], capabilities: fullCaps),
                    chargeLimit: limitHolding, chargeToFullRequested: true))
                .environment(\.popoverStaticFrame, true)
                .popoverRenderBackground()
        })
        entries.append(RenderEntry("popover-controls-error-no-high-power") {
            PopoverView()
                .environment(BatteryModel(
                    previewSnapshot: .sampleOnBattery, history: [],
                    energyStatus: EnergyModeStatus(modes: [.battery: .automatic],
                                                   capabilities: [.battery: [.automatic, .lowPower]]),
                    chargeLimit: nil,
                    controlError: "Couldn't change Energy Mode: pmset failed (error 1)."))
                .environment(\.popoverStaticFrame, true)
                .popoverRenderBackground()
        })
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

/// Menu bar glyphs for every sample, magnified 3× on light and dark menu bar strips, plus
/// 1× labels as they appear in the menu bar and the settings variants.
private struct PopoverMenuBarLabelGallery: View {
    private struct Variant: Identifiable {
        var name: String
        var snapshot: BatterySnapshot?
        var showPercent = true
        var lowPower = false
        var id: String { name }
    }

    private var variants: [Variant] {
        var list = BatterySnapshot.allSamples.map { Variant(name: $0.name, snapshot: $0.snapshot) }
        var full = BatterySnapshot.sampleOnHold
        full.chargePercent = 100
        full.fullyCharged = true
        full.notChargingReason = 0
        var low = BatterySnapshot.sampleOnBattery
        low.chargePercent = 7
        var mid = BatterySnapshot.sampleCharging
        mid.chargePercent = 42
        list += [
            Variant(name: "full-100", snapshot: full),
            Variant(name: "low-7", snapshot: low),
            Variant(name: "charging-42", snapshot: mid),
            Variant(name: "no-percent", snapshot: .sampleOnBattery, showPercent: false),
            Variant(name: "no-pct-chg", snapshot: mid, showPercent: false),
            Variant(name: "no-battery", snapshot: nil),
            Variant(name: "low-power-80", snapshot: .sampleOnHold, lowPower: true),
            Variant(name: "low-power-42", snapshot: low.with(percent: 42), lowPower: true),
            Variant(name: "low-power-100", snapshot: full, lowPower: true),
        ]
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopoverCaption("Menu bar glyph · 3×")
            PopoverWrapLayout(spacing: 8, lineSpacing: 8) {
                ForEach(variants) { variant in
                    VStack(spacing: 3) {
                        HStack(spacing: 0) {
                            strip(variant, scheme: .light)
                            strip(variant, scheme: .dark)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text(variant.name)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            PopoverCaption("Labels · 1× (light / dark menu bar)")
            ForEach(labelRows, id: \.0) { name, snapshot, settings in
                HStack(spacing: 10) {
                    Text(name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    label(snapshot, settings).foregroundStyle(.black)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color(white: 0.93))
                    label(snapshot, settings).foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color(white: 0.16))
                }
            }
        }
        .padding(12)
        .frame(width: 470, alignment: .leading)
    }

    private func strip(_ variant: Variant, scheme: ColorScheme) -> some View {
        let style = MenuBarLabel.glyphStyle(for: variant.snapshot, showPercent: variant.showPercent,
                                            precise: false, lowPower: variant.lowPower,
                                            darkMenuBar: scheme == .dark, pointScale: 3)
        return Image(nsImage: MenuBarGlyph.image(style))
            .renderingMode(variant.lowPower ? .original : .template)
            .foregroundStyle(scheme == .light ? Color.black : Color.white)
            .padding(.horizontal, 6)
            .frame(height: 66)
            .background(scheme == .light ? Color(white: 0.93) : Color(white: 0.16))
    }

    private typealias Settings = (percent: Bool, time: Bool, watts: Bool, precise: Bool)

    private var labelRows: [(String, BatterySnapshot?, Settings)] {
        [
            ("default (charging)", .sampleCharging, (true, false, false, false)),
            ("time (on battery)", .sampleOnBattery, (true, true, false, false)),
            ("watts (charging)", .sampleCharging, (true, true, true, false)),
            ("precise + time", .sampleOnBattery, (true, true, false, true)),
            ("on hold", .sampleOnHold, (true, true, false, false)),
        ]
    }

    private func label(_ snapshot: BatterySnapshot?, _ s: Settings) -> some View {
        let title = MenuBarLabel.title(for: snapshot, showPercent: s.percent, showTime: s.time,
                                       showWatts: s.watts, precise: s.precise)
        return HStack(spacing: 4) {
            Image(nsImage: MenuBarGlyph.image(MenuBarLabel.glyphStyle(for: snapshot, showPercent: s.percent,
                                                                      precise: s.precise)))
                .renderingMode(.template)
            if !title.isEmpty {
                Text(title).font(.system(size: 13)).monospacedDigit()
            }
        }
    }
}

private extension BatterySnapshot {
    func with(percent: Int) -> BatterySnapshot {
        var copy = self
        copy.chargePercent = percent
        return copy
    }
}
