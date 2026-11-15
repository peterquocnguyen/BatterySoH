import AppKit
import BatteryKit
import SwiftUI

// Building blocks of the popover body (SPEC F2 header/tiles/chips, F3 summary + footer).

// MARK: - Header

struct PopoverHeader: View {
    let display: PopoverDisplay

    var body: some View {
        let headline = display.headline
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: display.statusIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(display.statusColor)
                    Text(display.statusTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Text(display.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(headline.value)
                        .font(.system(size: 38, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(headline.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(headline.caption)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 8) {
                        PopoverBatteryGlyph(fraction: display.chargeFraction, fill: display.chargeColor,
                                            width: 38, height: 18)
                        Text(display.chargeText)
                            .font(.system(size: 26, weight: .semibold))
                            .monospacedDigit()
                    }
                    Text(display.timeSummary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Tiles + PD profiles

struct PopoverTiles: View {
    let display: PopoverDisplay

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PopoverTile(title: "Charger", value: display.chargerTile,
                            valueStyle: display.snapshot.externalConnected ? .primary : .secondary)
                PopoverTile(title: "Active profile", value: display.profileTile)
            }
            HStack(spacing: 8) {
                PopoverTile(title: "Battery", value: display.batteryElectrical)
                PopoverTile(title: "Temperature", value: display.temperature)
            }
        }
    }
}

struct PopoverProfileChips: View {
    let display: PopoverDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PopoverCaption("PD profiles")
            PopoverWrapLayout(spacing: 5, lineSpacing: 5) {
                ForEach(display.profiles) { profile in
                    chip(profile, active: profile.index == display.activeProfileIndex)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ profile: PDProfile, active: Bool) -> some View {
        Text(Fmt.profile(profile))
            .font(.system(size: 11.5, weight: active ? .bold : .medium))
            .monospacedDigit()
            .foregroundStyle(active ? PopoverPalette.onCharge : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? PopoverPalette.charge : PopoverPalette.tileFill))
            .accessibilityLabel(active ? "\(Fmt.profile(profile)), active" : Fmt.profile(profile))
    }
}

// MARK: - Draining banner

/// Red-tinted note under the tiles explaining why the battery drains on a charger.
struct PopoverDrainBanner: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PopoverPalette.drain)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(shape.fill(PopoverPalette.drain.opacity(0.12)))
        .overlay(shape.strokeBorder(PopoverPalette.drain.opacity(0.28), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Summary rows (F3)

struct PopoverSummary: View {
    let display: PopoverDisplay

    var body: some View {
        let snapshot = display.snapshot
        let time = display.timeRow
        VStack(spacing: 9) {
            barRow("Battery Charge", value: display.chargeText,
                   percent: display.chargeFraction * 100, color: display.chargeColor)
            barRow("Battery Health", value: Fmt.percent(snapshot.healthPercent, decimals: 1),
                   percent: snapshot.healthPercent, color: PopoverPalette.health(snapshot.healthPercent))
            VStack(spacing: 6) {
                if let condition = display.condition {
                    row("Condition", value: condition.status.title,
                        color: condition.needsService ? condition.status.tint : nil)
                }
                row(time.label, value: time.value)
                row("Cycles", value: display.cycles)
                row("Temperature", value: display.temperature)
            }
            .padding(.top, 2)
        }
    }

    private func barRow(_ label: String, value: String, percent: Double?, color: Color) -> some View {
        VStack(spacing: 5) {
            row(label, value: value)
            PopoverBar(percent: percent, color: color)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, value: String, color: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: color == nil ? .regular : .semibold))
                .monospacedDigit()
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(value == Fmt.dash ? .secondary : .primary))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Footer

struct PopoverFooter: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 6) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(PopoverFooterButtonStyle())
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
            .help("Settings")
            .accessibilityLabel("Settings")

            Spacer()

            Button {
                openWindow(id: WindowID.main)
                NSApp.activate()
            } label: {
                Label("Open Window", systemImage: "macwindow")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(PopoverFooterButtonStyle())

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(PopoverFooterButtonStyle())
                .keyboardShortcut("q")
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - No battery

struct PopoverNoBattery: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "powerplug")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PopoverPalette.tileFill))
            VStack(alignment: .leading, spacing: 3) {
                Text("No battery")
                    .font(.system(size: 15, weight: .semibold))
                Text("This Mac has no internal battery, or its battery data can't be read right now.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
