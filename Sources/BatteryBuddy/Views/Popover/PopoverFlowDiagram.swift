import BatteryKit
import SwiftUI

/// CHARGER → MAC → BATTERY power-flow diagram (SPEC F2). Adapts to the power state:
/// - charging: both links active, flowing left → right
/// - on AC, not charging: charger → Mac active, Mac ↔ battery idle
/// - on battery: charger dimmed, battery → Mac flowing right → left
/// - draining on AC: both links flow *into* the Mac (charger → Mac and battery → Mac)
struct PopoverFlowDiagram: View {
    let display: PopoverDisplay
    /// False while the popover is closed, so the timeline stops ticking.
    var isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.popoverStaticFrame) private var staticFrame

    private let nodeSize: CGFloat = 54

    var body: some View {
        let snapshot = display.snapshot
        let plugged = snapshot.externalConnected
        let link = display.batteryLink

        HStack(alignment: .top, spacing: 0) {
            FlowNode(caption: "Charger", value: display.chargerNodeValue, size: nodeSize, dimmed: !plugged) {
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 22, weight: .medium))
                    .rotationEffect(.degrees(plugged ? 0 : -90))
            }
            FlowLink(top: plugged ? Fmt.watts(display.powerInW) : "",
                     bottom: plugged ? display.chargerElectrical : "",
                     color: PopoverPalette.charger,
                     direction: plugged ? .forward : .none,
                     period: PopoverDisplay.period(forWatts: display.powerInW),
                     animate: animate)
                .frame(height: nodeSize)
            FlowNode(caption: "Mac", value: display.macNodeValue, size: nodeSize, dimmed: false) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 24, weight: .regular))
            }
            FlowLink(top: link.top, bottom: link.bottom,
                     color: linkColor,
                     direction: linkDirection,
                     period: PopoverDisplay.period(forWatts: linkWatts),
                     animate: animate)
                .frame(height: nodeSize)
            FlowNode(caption: "Battery", value: display.chargeText, size: nodeSize, dimmed: false) {
                PopoverBatteryGlyph(fraction: display.chargeFraction, fill: display.chargeColor,
                                    width: 28, height: 14)
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var animate: Bool { isVisible && !reduceMotion && !staticFrame }

    private var linkDirection: FlowLink.Direction {
        switch display.state {
        case .charging: return .forward
        case .onBattery, .drainingOnAC: return .backward
        case .full, .onACNotCharging: return .none
        }
    }

    private var linkColor: Color {
        switch display.state {
        case .charging: return PopoverPalette.charge
        case .onBattery: return PopoverPalette.discharge
        case .drainingOnAC: return PopoverPalette.drain
        case .full, .onACNotCharging: return .secondary
        }
    }

    /// Watts on the Mac ↔ battery link (estimated from the Mac's load right after unplugging).
    private var linkWatts: Double? {
        display.state == .onBattery ? display.dischargeW : display.snapshot.batteryPowerW
    }

    private var accessibilityText: String {
        let s = display.snapshot
        switch display.state {
        case .charging:
            return "Charger supplies \(Fmt.watts(display.powerInW)). Mac \(display.macNodeValue). "
                + "\(display.batteryLink.top) into the battery at \(display.chargeText)."
        case .onBattery:
            return "Charger unplugged. Battery at \(display.chargeText) supplies \(display.batteryLink.top) to the Mac."
        case .drainingOnAC:
            return "Charger supplies \(Fmt.watts(display.powerInW)) and the battery at \(display.chargeText) "
                + "adds \(Fmt.watts(s.batteryPowerW.map { abs($0) })). Mac \(display.macNodeValue)."
        case .full, .onACNotCharging:
            return "Charger supplies \(Fmt.watts(display.powerInW)) to the Mac. Battery \(s.statusTitle.lowercased()) at \(display.chargeText)."
        }
    }
}

// MARK: - Node

private struct FlowNode<Icon: View>: View {
    var caption: String
    var value: String
    var size: CGFloat
    var dimmed: Bool
    @ViewBuilder var icon: Icon

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
                .overlay(icon.foregroundStyle(.primary.opacity(0.8)))
                .frame(width: size, height: size)
            PopoverCaption(caption)
                .fixedSize()
                .padding(.top, 8)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(dimmed ? .secondary : .primary)
                .fixedSize()
                .padding(.top, 2)
        }
        .frame(width: size)
        .opacity(dimmed ? 0.5 : 1)
    }
}

// MARK: - Link

private struct FlowLink: View {
    enum Direction { case forward, backward, none }

    var top: String
    var bottom: String
    var color: Color
    var direction: Direction
    var period: Double
    var animate: Bool

    /// Phase used for the static render / reduced motion frame (dots at ~0.18, 0.51, 0.84).
    private static let restingPhase = 0.18

    var body: some View {
        VStack(spacing: 3) {
            Text(top)
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(direction == .none ? Color.secondary : color)
                .lineLimit(1)
                .frame(height: 15)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate || direction == .none)) { context in
                let phase = animate
                    ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    : Self.restingPhase
                Canvas { ctx, size in draw(in: &ctx, size: size, phase: phase) }
            }
            .frame(height: 12)
            Text(bottom)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 14)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, phase: Double) {
        let y = size.height / 2
        let x0: CGFloat = 1, x1 = size.width - 1
        var line = Path()
        line.move(to: CGPoint(x: x0, y: y))
        line.addLine(to: CGPoint(x: x1, y: y))

        guard direction != .none else {
            ctx.stroke(line, with: .color(.secondary.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4]))
            return
        }
        ctx.stroke(line, with: .color(color.opacity(0.3)),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))

        let forward = direction == .forward
        let tip = forward ? x1 : x0
        let back: CGFloat = forward ? -7 : 7
        var arrow = Path()
        arrow.move(to: CGPoint(x: tip, y: y))
        arrow.addLine(to: CGPoint(x: tip + back, y: y - 4.5))
        arrow.addLine(to: CGPoint(x: tip + back, y: y + 4.5))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(color))

        // Three dots travelling toward the arrow, fading in and out at the ends.
        let start = forward ? x0 + 3 : x1 - 3
        let travel = (x1 - x0) - 14
        let radius: CGFloat = 3.5
        for i in 0..<3 {
            let t = (phase + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let x = start + (forward ? 1 : -1) * CGFloat(t) * travel
            let alpha = 0.25 + 0.75 * sin(Double.pi * t)
            let dot = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            ctx.fill(dot, with: .color(color.opacity(alpha)))
        }
    }
}
