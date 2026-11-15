import BatteryKit
import SwiftUI

// SPEC F8: the native Battery menu's controls in the popover's visual language — the charge
// limit line with "Charge to Full Now", and the Energy Mode picker.

// MARK: - Charge limit line

/// Under the header while macOS's charge limit holds the charge.
struct PopoverChargeLimitLine: View {
    @Environment(BatteryModel.self) private var model
    let display: PopoverDisplay

    var body: some View {
        if let percent = display.heldAtLimitPercent {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            HStack(spacing: 8) {
                Image(systemName: model.chargeToFullRequestedAt != nil ? "bolt.fill" : "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PopoverPalette.charger)
                    .frame(width: 16)
                if model.chargeToFullRequestedAt != nil {
                    Text("Charging to 100%…")
                        .font(.system(size: 12.5, weight: .medium))
                } else {
                    Text("Paused at your \(percent)% limit")
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if display.canChargeToFull, model.chargeToFullRequestedAt == nil {
                    Button("Charge to Full Now") {
                        Task { await model.chargeToFullNow() }
                    }
                    .popoverControlButton()
                    .help("Charge to 100% this time. macOS restores the \(percent)% limit afterwards.")
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .background(shape.fill(PopoverPalette.charger.opacity(0.10)))
            .overlay(shape.strokeBorder(PopoverPalette.charger.opacity(0.22), lineWidth: 0.5))
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Energy Mode

struct PopoverEnergyModeSection: View {
    @Environment(BatteryModel.self) private var model

    static func isAvailable(_ model: BatteryModel) -> Bool {
        model.energyMode != nil && model.supportedEnergyModes.count >= 2
    }

    var body: some View {
        let selected = model.energyMode
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                PopoverCaption("Energy Mode")
                Spacer()
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(model.supportedEnergyModes) { mode in
                    PopoverEnergyModeButton(mode: mode, isSelected: mode == selected,
                                            isBusy: model.isChangingEnergyMode) {
                        Task { await model.setEnergyMode(mode) }
                    }
                }
            }
            if !model.isPasswordFreeEnergyMode, !model.supportedEnergyModes.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                    Text("Asks for your password each time.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Set up once…") { model.setPasswordFreeEnergyMode(true) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Installs a sudo rule that allows only the Energy Mode pmset commands without a password. You enter your password once. Remove it in Settings.")
                }
                .font(.system(size: 11.5))
            }
            if let error = model.controlError {
                PopoverControlError(text: error)
            }
        }
    }

    private var caption: String {
        if model.isChangingEnergyMode { return "Waiting for administrator password…" }
        switch model.currentPowerSource {
        case .ac: return "Applies on power adapter"
        case .battery: return "Applies on battery"
        case nil: return ""
        }
    }
}

/// Transient failure of a control action (`BatteryModel.controlError`).
struct PopoverControlError: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(PopoverPalette.critical)
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One circular mode button with its label underneath, like the native menu's mode items.
struct PopoverEnergyModeButton: View {
    let mode: EnergyMode
    let isSelected: Bool
    let isBusy: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    if isSelected {
                        Circle().fill(Color.accentColor)
                    } else {
                        PopoverCirclePlatter(hovering: hovering)
                    }
                    Image(systemName: Self.symbol(for: mode))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.75))
                }
                .frame(width: 34, height: 34)
                Text(mode.title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy && !isSelected ? 0.55 : 1)
        .onHover { hovering = $0 }
        .help(isSelected
              ? "\(mode.title) is on."
              : "Switch to \(mode.title).")
        .accessibilityLabel("Energy Mode \(mode.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    static func symbol(for mode: EnergyMode) -> String {
        switch mode {
        case .automatic: return "battery.100percent"
        case .lowPower: return "battery.25percent"
        case .highPower: return "forward.fill"
        }
    }
}

/// Neutral circle for unselected mode buttons: same platter look as the tiles.
private struct PopoverCirclePlatter: View {
    var hovering: Bool

    var body: some View {
        Circle()
            .fill(Color.primary.opacity(hovering ? 0.11 : 0.07))
            .overlay {
                if LiquidGlass.isSupported {
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
            }
    }
}

// MARK: - Button style

extension View {
    /// Native glass button on macOS 26+ (live only), else a custom-drawn capsule that also
    /// renders headlessly.
    func popoverControlButton() -> some View { modifier(PopoverControlButtonModifier()) }
}

private struct PopoverControlButtonModifier: ViewModifier {
    @Environment(\.renderHarness) private var renderHarness

    func body(content: Content) -> some View {
        if !renderHarness, #available(macOS 26, *) {
            content
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.glass)
                .controlSize(.small)
        } else {
            content.buttonStyle(PopoverCapsuleButtonStyle())
        }
    }
}

struct PopoverCapsuleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill(pressed: configuration.isPressed)))
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 0.5, y: 0.5)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }

    private func fill(pressed: Bool) -> Color {
        if pressed { return Color.primary.opacity(0.14) }
        if scheme == .dark { return Color.white.opacity(hovering ? 0.16 : 0.11) }
        return Color.white.opacity(hovering ? 0.8 : 1)
    }
}
