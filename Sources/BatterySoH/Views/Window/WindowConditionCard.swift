import BatteryKit
import SwiftUI

/// F11 — "Battery Condition": Normal / Service Recommended, maximum capacity against Apple's
/// 80 % service level, iPhone peak performance, and where the verdict comes from. Pure drawing.
struct WindowConditionCard: View {
    let condition: BatteryCondition
    /// "Mac", "iPhone", "iPad": names the device in the source caption.
    let deviceName: String

    var body: some View {
        WindowCard {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Battery Condition").font(.headline)
                        Spacer(minLength: 8)
                        WindowConditionBadge(status: condition.status)
                    }
                    Text(condition.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                WindowHairline()
                WindowRowList(rows: condition.rows)
                    .padding(.vertical, 2)
                if let peak = condition.peakPerformance {
                    WindowHairline().padding(.leading, 12)
                    Text(peak.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                WindowHairline()
                Label(
                    condition.sourceCaption(deviceName: deviceName),
                    systemImage: condition.source == .macOS ? "checkmark.seal" : "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Capsule next to "Battery Condition": green "Normal" or orange "Service Recommended".
struct WindowConditionBadge: View {
    let status: BatteryCondition.Status

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
            Text(status.title)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(status.tint.opacity(0.13)))
        .fixedSize()
    }
}

// MARK: - Display values

extension BatteryCondition.Status {
    var title: String {
        switch self {
        case .normal: return "Normal"
        case .serviceRecommended: return "Service Recommended"
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .serviceRecommended: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .normal: return .green
        case .serviceRecommended: return .orange
        }
    }
}

extension BatteryCondition.PeakPerformance {
    var title: String {
        switch self {
        case .normal: return "Normal"
        case .unexpectedShutdown, .worn: return "May Be Limited"
        }
    }

    var detail: String {
        switch self {
        case .normal:
            return "No unexpected shutdown on record, so iOS shouldn’t be limiting peak performance."
        case .unexpectedShutdown:
            return
                "An unexpected shutdown is on record. After one, iOS may limit peak performance to keep it from happening again."
        case .worn:
            return "With a worn battery, iOS may limit peak performance to avoid unexpected shutdowns."
        }
    }
}

extension BatteryCondition {
    private var threshold: Int { Self.serviceThresholdPercent }

    /// One or two sentences under the heading.
    var summary: String {
        if permanentFailure {
            return "The battery reports a permanent failure. Have it serviced."
        }
        switch (status, source) {
        case (.normal, _):
            let lead =
                source == .macOS
                ? "macOS reports the battery is working normally." : "The battery doesn’t need service yet."
            guard let points = pointsAboveServiceLevel else { return lead }
            if points == 0 { return "\(lead) Maximum capacity is at the \(threshold)% service level." }
            return
                "\(lead) Maximum capacity is \(points) \(points == 1 ? "point" : "points") above the \(threshold)% service level."
        case (.serviceRecommended, .macOS):
            return
                "macOS recommends service: the battery holds noticeably less charge than when it was new. It is still safe to use; a battery replacement brings back full battery life."
        case (.serviceRecommended, .estimated):
            return
                "Maximum capacity is below \(threshold)%, the level at which Apple considers a battery worn. Expect noticeably shorter battery life; a battery replacement brings it back."
        }
    }

    var rows: [WindowRow] {
        var rows = [
            WindowRow(label: "Maximum Capacity", value: Fmt.percent(maximumCapacityPercent.map(Double.init))),
            WindowRow(label: "Service Level", value: "\(threshold)%"),
        ]
        if let peakPerformance {
            rows.append(WindowRow(label: "Peak Performance", value: peakPerformance.title))
        }
        return rows
    }

    func sourceCaption(deviceName: String) -> String {
        switch source {
        case .macOS:
            return "Condition and maximum capacity as macOS reports them (System Information › Power)."
        case .estimated where deviceName == "Mac":
            return "Estimated from capacity: macOS didn’t report a condition."
        case .estimated:
            return
                "Estimated by BatterySoH from capacity and the shutdown record. The \(deviceName) keeps its own verdict in Settings › Battery › Battery Health; it can differ slightly."
        }
    }
}
