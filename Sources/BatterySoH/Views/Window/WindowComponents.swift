import AppKit
import BatteryKit
import SwiftUI

// Small custom-drawn building blocks shared by the window tabs. Everything here is pure
// SwiftUI drawing (no AppKit-backed controls) so `--render` can capture it.

/// Rounded "inset grouped" container: white on light, a faint lift on dark. On macOS 26+ it is
/// a translucent platter so the window's material shows through.
struct WindowCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.renderHarness) private var renderHarness
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private var fill: Color {
        if LiquidGlass.isSupported, !renderHarness {
            return scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.62)
        }
        return scheme == .dark ? Color.white.opacity(0.06) : Color(nsColor: .controlBackgroundColor)
    }
}

/// 0.5 pt separator line (Divider can be AppKit-backed; this always renders).
struct WindowHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 0.5)
    }
}

/// One label/value row inside a `WindowCard`.
struct WindowRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// Label/value rows separated by inset hairlines.
struct WindowRowList: View {
    let rows: [WindowRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { WindowHairline().padding(.leading, 12) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(row.value == Fmt.dash ? .tertiary : .secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}

/// Horizontal level bar with its percentage drawn on (inside the fill when it fits).
struct WindowMeterBar: View {
    /// 0...1
    let fraction: Double
    let label: String
    let tint: Color

    private let height: CGFloat = 22
    private let labelRoom: CGFloat = 54

    var body: some View {
        GeometryReader { geo in
            let clamped = max(0, min(1, fraction))
            let fill = clamped * geo.size.width
            let inside = fill >= labelRoom
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: fill)
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(inside ? AnyShapeStyle(Color.black.opacity(0.72)) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 8)
                    .frame(width: inside ? fill : nil, alignment: .trailing)
                    .offset(x: inside ? 0 : fill)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(label)
    }
}

extension View {
    /// Native glass button on macOS 26+, else the custom-drawn pill (which also renders headlessly).
    /// `prominent`: accent-filled, for the one action a card is about.
    func windowPillButton(prominent: Bool = false) -> some View {
        modifier(WindowPillButtonModifier(prominent: prominent))
    }
}

private struct WindowPillButtonModifier: ViewModifier {
    var prominent: Bool
    @Environment(\.renderHarness) private var renderHarness

    func body(content: Content) -> some View {
        if !renderHarness, #available(macOS 26, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            content.buttonStyle(WindowPillButtonStyle(prominent: prominent))
        }
    }
}

/// Bordered rounded button drawn by SwiftUI (renders headlessly, unlike `.bordered`).
struct WindowPillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(.callout.weight(prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, prominent ? 12 : 10)
            .padding(.vertical, 4)
            .background(shape.fill(fill(pressed: configuration.isPressed)))
            .overlay(shape.strokeBorder(prominent ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 0.5, y: 0.5)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }

    private func fill(pressed: Bool) -> Color {
        if prominent { return Color.accentColor.opacity(pressed ? 0.8 : 1) }
        if pressed { return Color.primary.opacity(0.14) }
        return scheme == .dark ? Color.white.opacity(0.10) : Color(nsColor: .controlBackgroundColor)
    }
}
