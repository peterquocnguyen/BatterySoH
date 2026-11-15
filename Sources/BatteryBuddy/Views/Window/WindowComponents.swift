import AppKit
import BatteryKit
import SwiftUI

// Small custom-drawn building blocks shared by the window tabs. Everything here is pure
// SwiftUI drawing (no AppKit-backed controls) so `--render` can capture it.

/// Rounded "inset grouped" container: white on light, a faint lift on dark.
struct WindowCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(scheme == .dark ? Color.white.opacity(0.06)
                                                    : Color(nsColor: .controlBackgroundColor)))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
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

/// Bordered rounded button drawn by SwiftUI (renders headlessly, unlike `.bordered`).
struct WindowPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(shape.fill(fill(pressed: configuration.isPressed)))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 0.5, y: 0.5)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }

    private func fill(pressed: Bool) -> Color {
        if pressed { return Color.primary.opacity(0.14) }
        return scheme == .dark ? Color.white.opacity(0.10) : Color(nsColor: .controlBackgroundColor)
    }
}
