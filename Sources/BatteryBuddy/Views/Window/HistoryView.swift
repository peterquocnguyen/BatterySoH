import BatteryKit
import Charts
import SwiftUI

/// F5 — "History" tab content: health chart, monthly table, CSV export.
/// Pure drawing (Swift Charts renders headlessly); the window wraps it in a ScrollView.
struct HistoryContent: View {
    let history: [HistorySample]
    /// Group title for the table, e.g. "This Mac (MacBook Pro)".
    let deviceTitle: String
    /// nil hides the export button (empty state).
    var onExport: (() -> Void)?
    var exportMessage: String?

    private var samples: [HistorySample] { history.sorted { $0.date < $1.date } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if samples.isEmpty {
                HistoryEmptyState()
            } else {
                header
                WindowCard {
                    HistoryChart(samples: samples)
                        .frame(height: 170)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                }
                HistoryMonthTable(title: deviceTitle,
                                  months: HistoryAggregator.monthly(samples).reversed())
            }
        }
        .padding(20)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Battery Health").font(.headline)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let onExport {
                Button("Export CSV…", action: onExport)
                    .buttonStyle(WindowPillButtonStyle())
                    .help("Save every daily sample as a CSV file")
            }
        }
    }

    /// "22 samples since Jan 2025 · now 89.5%"
    private var summary: String {
        guard let first = samples.first, let last = samples.last else { return "" }
        let count = samples.count == 1 ? "1 sample" : "\(samples.count) samples"
        let since = first.date.formatted(.dateTime.month(.abbreviated).year())
        return "\(count) since \(since) · now \(Fmt.percent(last.healthPercent, decimals: 1))"
    }
}

// MARK: - Chart

struct HistoryChart: View {
    let samples: [HistorySample]

    private var yDomain: ClosedRange<Double> {
        let low = samples.map(\.healthPercent).min() ?? 100
        let floor = max(0, ((low - 2) / 5).rounded(.down) * 5)
        return min(floor, 95)...100
    }

    var body: some View {
        let domain = yDomain
        Chart(samples) { sample in
            AreaMark(x: .value("Date", sample.date, unit: .day),
                     yStart: .value("Floor", domain.lowerBound),
                     yEnd: .value("Health", sample.healthPercent))
                .interpolationMethod(.monotone)
                .foregroundStyle(.linearGradient(colors: [Color.green.opacity(0.28), Color.green.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Date", sample.date, unit: .day),
                     y: .value("Health", sample.healthPercent))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.green)
            if samples.count <= 24 {
                PointMark(x: .value("Date", sample.date, unit: .day),
                          y: .value("Health", sample.healthPercent))
                    .symbolSize(samples.count == 1 ? 40 : 14)
                    .foregroundStyle(Color.green)
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 18))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))%").monospacedDigit() }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits), anchor: .top)
            }
        }
        .accessibilityLabel("Battery health over time")
    }
}

// MARK: - Monthly table

struct HistoryMonthTable: View {
    let title: String
    /// Newest first.
    let months: [MonthSummary]

    private let healthWidth: CGFloat = 96
    private let cyclesWidth: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            WindowCard {
                VStack(spacing: 0) {
                    row(month: "Month", health: "Ø Health", cycles: "Cycles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 7)
                    WindowHairline()
                    ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
                        row(month: month.period,
                            health: Fmt.percent(month.averageHealthPercent, decimals: 1),
                            cycles: "\(month.maxCycleCount)")
                            .monospacedDigit()
                            .padding(.vertical, 5)
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func row(month: String, health: String, cycles: String) -> some View {
        HStack(spacing: 0) {
            Text(month).frame(maxWidth: .infinity, alignment: .leading)
            Text(health).frame(width: healthWidth, alignment: .trailing)
            Text(cycles).frame(width: cyclesWidth, alignment: .trailing)
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Empty state

struct HistoryEmptyState: View {
    var body: some View {
        WindowCard {
            VStack(spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)
                Text("No history yet")
                    .font(.headline)
                Text("History starts today — Battery Buddy records one sample per day.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
        }
    }
}
