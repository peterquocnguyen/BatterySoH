import BatteryKit
import Charts
import SwiftUI

/// F11 — "Insights" tab: a battery level card, Daily Usage (today vs the usual by this time of
/// day, 7-day chart) and health, per device, modelled on iOS Settings › Battery.
/// Pure drawing (Swift Charts renders headlessly); the window wraps it in a ScrollView.
struct InsightsContent: View {
    let subjects: [InsightsSubject]
    @Binding var selection: String
    let now: Date
    var calendar: Calendar = .current

    private var subject: InsightsSubject? {
        subjects.first { $0.id == selection } ?? subjects.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let subject {
                if subjects.count > 1 {
                    InsightsDevicePicker(subjects: subjects, selection: subject.id) { selection = $0 }
                }
                if let level = subject.level {
                    InsightsLevelCard(subject: subject, level: level)
                }
                let summary = ChargeAnalysis.summary(subject.samples, now: now, calendar: calendar)
                if summary.hasAnyData {
                    InsightsUsageCard(summary: summary, subject: subject,
                                      time: now.formatted(date: .omitted, time: .shortened), calendar: calendar)
                } else {
                    InsightsEmptyCard()
                }
                if !subject.healthRows.isEmpty {
                    InsightsHealthCard(rows: subject.healthRows)
                }
                if subject.isMobile {
                    footnote("Per-app battery use for \(subject.kindName) stays on the \(subject.kindName): Settings › Battery.")
                }
            } else {
                InsightsEmptyCard()
            }
        }
        .padding(20)
    }

    private func footnote(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "app.badge")
                .frame(width: 14)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

// MARK: - Subjects

/// One device the Insights tab can show: This Mac, or an iPhone / iPad with a charge log.
struct InsightsSubject: Identifiable {
    /// Charge-log key.
    let id: String
    let name: String
    let symbol: String
    let isMobile: Bool
    /// "iPhone" / "iPad" for the footnote.
    let kindName: String
    let samples: [ChargeSample]
    /// The top card; nil when nothing is known.
    let level: InsightsLevel?
    /// Health rows; empty hides the card (iPhone without a cabled / Wi-Fi read).
    let healthRows: [WindowRow]
}

/// What the top card shows.
struct InsightsLevel {
    var percent: Int
    var isApproximate: Bool
    /// "Charging", "On battery", "Last shared level"…
    var title: String
    /// "full in 58 min", "since 12:03", "at 09:14"…
    var detail: String?
    var symbol: String
    var symbolTint: Color
    var barTint: Color
}

extension InsightsSubject {
    /// This Mac (when it has a battery or a log), then every iPhone / iPad with a log.
    static func all(mac: MacInfo, snapshot: BatterySnapshot?, devices: [DeviceBattery], logs: [ChargeLog],
                    unit: Fmt.TemperatureUnit) -> [InsightsSubject] {
        var out: [InsightsSubject] = []
        let macLog = logs.first(where: \.isThisMac)
        if snapshot != nil || macLog != nil {
            out.append(InsightsSubject(
                id: ChargeLog.thisMacID, name: mac.name,
                symbol: mac.name.localizedCaseInsensitiveContains("book") ? "laptopcomputer" : "desktopcomputer",
                isMobile: false, kindName: "Mac", samples: macLog?.samples ?? [],
                level: snapshot.map(InsightsLevel.init(snapshot:)) ?? macLog.flatMap(InsightsLevel.lastReading),
                healthRows: snapshot.map { $0.insightsHealthRows } ?? []))
        }
        for log in logs where !log.isThisMac {
            let current = devices.first { ChargeLog.key(for: $0) == log.id && $0.percent != nil }
            let kind = current?.kind ?? log.kind ?? .iPhone
            let placeholder = DeviceBattery(id: log.id, name: log.name, kind: kind, percent: nil)
            out.append(InsightsSubject(
                id: log.id,
                name: current.flatMap { $0.isApproximate ? nil : $0.name } ?? log.name,
                symbol: (current ?? placeholder).symbol,
                isMobile: true, kindName: kind == .iPad ? "iPad" : "iPhone", samples: log.samples,
                level: current.flatMap(InsightsLevel.init(device:)) ?? InsightsLevel.lastReading(log),
                healthRows: current.map { $0.hasHealth ? $0.healthRows(unit: unit) : [] } ?? []))
        }
        return out
    }
}

extension InsightsLevel {
    init(snapshot s: BatterySnapshot) {
        let detail: String?
        switch s.powerState {
        case .charging, .onBattery: detail = s.timeSummary
        case .drainingOnAC: detail = s.minutesToEmpty.map { "\(Fmt.duration(minutes: $0)) left" }
        case .full, .onACNotCharging: detail = nil
        }
        let low = s.powerState == .onBattery || s.powerState == .drainingOnAC
        self.init(percent: s.chargePercent, isApproximate: false, title: s.statusTitle, detail: detail,
                  symbol: s.isCharging ? "bolt.fill" : (s.externalConnected ? "powerplug.fill" : "battery.75percent"),
                  symbolTint: s.isCharging ? .green : .secondary,
                  barTint: low ? Self.levelTint(s.chargePercent) : .green)
    }

    init?(device d: DeviceBattery) {
        guard let percent = d.percent else { return nil }
        if d.isApproximate {
            self.init(percent: percent, isApproximate: true, title: "Last shared level",
                      detail: d.levelSince.map { "since \($0.formatted(date: .omitted, time: .shortened))" },
                      symbol: "personalhotspot", symbolTint: .secondary, barTint: .gray)
        } else {
            let title = d.isCharging ? "Charging" : (d.externalConnected ? "Charger connected" : "On battery")
            self.init(percent: percent, isApproximate: false, title: title, detail: nil,
                      symbol: d.isCharging ? "bolt.fill" : (d.externalConnected ? "powerplug.fill" : "battery.75percent"),
                      symbolTint: d.isCharging ? .green : .secondary,
                      barTint: d.isCharging ? .green : Self.levelTint(percent))
        }
    }

    /// The newest logged reading, for a device that isn't in range right now.
    static func lastReading(_ log: ChargeLog) -> InsightsLevel? {
        guard let last = log.samples.last else { return nil }
        let when = last.end
        let at = Calendar.current.isDateInToday(when)
            ? "at \(when.formatted(date: .omitted, time: .shortened))"
            : when.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let percent = Int(last.percent.rounded())
        return InsightsLevel(percent: percent, isApproximate: last.isApproximate,
                             title: last.isApproximate ? "Last shared level" : "Last reading", detail: at,
                             symbol: "clock", symbolTint: .secondary,
                             barTint: last.isApproximate ? .gray : levelTint(percent))
    }

    static func levelTint(_ percent: Int) -> Color {
        if percent <= 10 { return .red }
        if percent <= 20 { return .orange }
        return .green
    }

    var percentText: String { isApproximate ? "≈ \(percent)%" : "\(percent)%" }
}

private extension BatterySnapshot {
    var insightsHealthRows: [WindowRow] {
        let cycles: String = cycleCount.map { c in
            designCycleCount.map { "\(c) of \($0)" } ?? "\(c)"
        } ?? Fmt.dash
        return [
            WindowRow(label: "Maximum Capacity", value: Fmt.percent(healthPercent, decimals: 1)),
            WindowRow(label: "Charge Cycles", value: cycles),
            WindowRow(label: "Full Charge Capacity", value: Fmt.mAh(fullChargeCapacityMAh)),
            WindowRow(label: "Design Capacity", value: Fmt.mAh(designCapacityMAh)),
        ]
    }
}

// MARK: - Device picker

/// This Mac / iPhone / iPad switcher, custom-drawn (renders headlessly, unlike Picker).
private struct InsightsDevicePicker: View {
    let subjects: [InsightsSubject]
    let selection: String
    let onSelect: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(subjects) { s in
                let selected = s.id == selection
                Button { onSelect(s.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: s.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(s.name)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            Capsule()
                                .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white)
                                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 1.5, y: 0.5)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

// MARK: - Level card

private struct InsightsLevelCard: View {
    let subject: InsightsSubject
    let level: InsightsLevel

    var body: some View {
        WindowCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: subject.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                    Text(subject.name)
                        .lineLimit(1)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

                Text(level.percentText)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.top, 4)
                HStack(spacing: 5) {
                    Image(systemName: level.symbol)
                        .foregroundStyle(level.symbolTint)
                    Text(level.title)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    if let detail = level.detail {
                        Text("· \(detail)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                .lineLimit(1)

                InsightsLevelBar(fraction: Double(level.percent) / 100, tint: level.barTint)
                    .padding(.top, 12)
                HStack {
                    Text("0%")
                    Spacer()
                    Text("50%")
                    Spacer()
                    Text("100%")
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

                if level.isApproximate {
                    Text("Last level the \(subject.kindName) shared over Personal Hotspot. It can lag well behind the \(subject.kindName == "iPhone" ? "phone" : subject.kindName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
            .padding(14)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Thin rounded bar to 100 %.
private struct InsightsLevelBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.gradient)
                    .frame(width: max(8, geo.size.width * max(0, min(1, fraction))))
            }
        }
        .frame(height: 10)
    }
}

// MARK: - Daily Usage

private struct InsightsUsageCard: View {
    let summary: UsageSummary
    let subject: InsightsSubject
    /// Current time of day, e.g. "12:07".
    let time: String
    let calendar: Calendar

    var body: some View {
        WindowCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Daily Usage")
                    .font(.headline)
                Text(ChargeAnalysis.sentence(summary.comparison, time: time))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                HStack(alignment: .top, spacing: 28) {
                    stat("Average", summary.averageByCutoff)
                    stat("Today", summary.today?.usedByCutoff)
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)

                InsightsUsageChart(summary: summary, calendar: calendar)
                    .frame(height: 150)
                    .padding(.top, 12)

                InsightsLegend(time: time)
                    .padding(.top, 10)

                if summary.usesApproximateData {
                    Label("Based on levels the \(subject.kindName) shared over Personal Hotspot, which can lag behind it, so usage is rough.",
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
            .padding(14)
        }
    }

    private func stat(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value.map { "\(Int($0.rounded()))%" } ?? Fmt.dash)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .tertiary : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}

enum InsightsPalette {
    /// "Daily by 12:07" (darker) and "All Day" (lighter, stacked on top).
    static let byNow = Color.green
    static let allDay = Color.green.opacity(0.32)
}

private struct InsightsUsageChart: View {
    let summary: UsageSummary
    let calendar: Calendar

    private var yMax: Double {
        let top = summary.days.map { max($0.usedAllDay, $0.usedByCutoff) }.max() ?? 0
        let withAverage = max(top, summary.averageByCutoff ?? 0)
        return max(20, (withAverage / 20).rounded(.up) * 20)
    }

    private var xDomain: ClosedRange<Date> {
        let first = summary.days.first?.start ?? summary.now
        let last = summary.days.last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0.start) } ?? summary.now
        return first...last
    }

    var body: some View {
        let top = yMax
        Chart {
            ForEach(summary.days) { day in
                if day.hasData || (day.isToday && day.covered > 0) {
                    BarMark(x: .value("Day", day.start, unit: .day),
                            yStart: .value("Used", 0), yEnd: .value("Used", day.usedByCutoff), width: .ratio(0.62))
                        .foregroundStyle(InsightsPalette.byNow)
                    if !day.isToday, day.usedAllDay > day.usedByCutoff {
                        BarMark(x: .value("Day", day.start, unit: .day),
                                yStart: .value("Used", day.usedByCutoff), yEnd: .value("Used", day.usedAllDay),
                                width: .ratio(0.62))
                            .foregroundStyle(InsightsPalette.allDay)
                    }
                }
            }
            if let average = summary.averageByCutoff {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...top)
        .chartXAxis {
            // A centred label sits between its tick and the next one, so the domain end is a
            // tick too (unlabelled), or "Today" would be dropped.
            AxisMarks(values: summary.days.map(\.start) + [xDomain.upperBound]) { value in
                AxisValueLabel(centered: true) {
                    if let date = value.as(Date.self), date < xDomain.upperBound {
                        Text(label(date))
                            .fontWeight(calendar.isDate(date, inSameDayAs: summary.now) ? .semibold : .regular)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, top / 2, top]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))%").monospacedDigit() }
                }
            }
        }
        .accessibilityLabel("Battery used per day, last 7 days and today")
    }

    /// "S", "M", … and "Today".
    private func label(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: summary.now) { return "Today" }
        let weekday = calendar.component(.weekday, from: date)
        return calendar.veryShortWeekdaySymbols[weekday - 1]
    }
}

private struct InsightsLegend: View {
    let time: String

    var body: some View {
        HStack(spacing: 14) {
            swatch(InsightsPalette.allDay, "All Day")
            swatch(InsightsPalette.byNow, "Daily by \(time)")
            HStack(spacing: 5) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 1))
                    p.addLine(to: CGPoint(x: 14, y: 1))
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                .frame(width: 14, height: 2)
                Text("Average")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
        }
    }
}

// MARK: - Health and empty state

private struct InsightsHealthCard: View {
    let rows: [WindowRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Battery Health")
                .font(.headline)
                .foregroundStyle(.secondary)
            WindowCard { WindowRowList(rows: rows) }
        }
    }
}

private struct InsightsEmptyCard: View {
    var body: some View {
        WindowCard {
            VStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)
                Text("No insights yet")
                    .font(.headline)
                Text("Insights fill in as Battery Buddy runs. Keep it open in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 36)
        }
    }
}
