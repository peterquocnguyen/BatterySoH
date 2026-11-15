import AppKit
import BatteryKit
import SwiftUI

// Shared look for the menu bar popover (F2/F3): palette, battery glyph, tiles, bars, buttons.

// MARK: - Palette

/// Accent colours tuned per appearance: the light variants are darker than the system
/// colours so that large numbers and labels keep contrast on a light popover.
enum PopoverPalette {
    /// Power going into the battery.
    static let charge = dynamic(light: (0.11, 0.58, 0.24), dark: (0.25, 0.84, 0.36))
    /// Power coming out of the battery.
    static let discharge = dynamic(light: (0.82, 0.40, 0.00), dark: (1.00, 0.62, 0.04))
    /// Power from the wall / charger.
    static let charger = dynamic(light: (0.00, 0.48, 0.80), dark: (0.39, 0.78, 1.00))
    static let warning = dynamic(light: (0.80, 0.58, 0.00), dark: (1.00, 0.80, 0.04))
    static let critical = dynamic(light: (0.82, 0.16, 0.13), dark: (1.00, 0.33, 0.30))
    /// Text drawn on a `charge`-filled capsule (white on dark green, near-black on bright green).
    static let onCharge = dynamic(light: (1, 1, 1), dark: (0.04, 0.16, 0.07))

    /// Neutral fills for tiles / tracks, readable on both window backgrounds and materials.
    static let tileFill = Color.primary.opacity(0.055)
    static let trackFill = Color.primary.opacity(0.09)

    static func health(_ percent: Double?) -> Color {
        guard let percent else { return .secondary }
        if percent >= 80 { return charge }
        if percent >= 60 { return warning }
        return critical
    }

    static func chargeLevel(_ percent: Double, state: PowerState) -> Color {
        if state == .charging || state == .full { return charge }
        if percent <= 10 { return critical }
        if percent <= 20 { return discharge }
        return charge
    }

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat),
                                dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

// MARK: - Battery glyph

/// Custom-drawn battery outline with a proportional fill (SF Symbols only have 5 levels).
struct PopoverBatteryGlyph: View {
    var fraction: Double
    var fill: Color
    var width: CGFloat = 34
    var height: CGFloat = 16

    var body: some View {
        let inset = max(2, height * 0.16)
        let line = max(1.2, height * 0.08)
        HStack(spacing: line) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.75), lineWidth: line)
                RoundedRectangle(cornerRadius: height * 0.16, style: .continuous)
                    .fill(fill)
                    .frame(width: max(height * 0.2, (width - inset * 2) * min(1, max(0, fraction))),
                           height: height - inset * 2)
                    .padding(.leading, inset)
            }
            .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: line, style: .continuous)
                .fill(Color.secondary.opacity(0.75))
                .frame(width: line * 1.6, height: height * 0.38)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Tiles, bars, captions

struct PopoverCaption: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }
}

struct PopoverTile: View {
    var title: String
    var value: String
    var valueStyle: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            PopoverCaption(title)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(PopoverPalette.tileFill))
        .accessibilityElement(children: .combine)
    }
}

/// Thin horizontal level bar (0–100).
struct PopoverBar: View {
    var percent: Double?
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PopoverPalette.trackFill)
                if let percent {
                    Capsule()
                        .fill(color)
                        .frame(width: max(6, geo.size.width * min(1, max(0, percent / 100))))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// Small rounded footer button that ImageRenderer can draw (no AppKit bezel).
struct PopoverFooterButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.09 : 0.05)))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Layout

/// Left-to-right wrapping row (PD chips can exceed one line on chargers with PPS profiles).
struct PopoverWrapLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : spacing + size.width
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += row.indices.isEmpty ? size.width : spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Render support

private struct PopoverStaticFrameKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True in the headless render harness: animated elements draw one fixed frame.
    var popoverStaticFrame: Bool {
        get { self[PopoverStaticFrameKey.self] }
        set { self[PopoverStaticFrameKey.self] = newValue }
    }
}
