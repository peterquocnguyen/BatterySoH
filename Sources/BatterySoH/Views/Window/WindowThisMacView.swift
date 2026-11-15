import BatteryKit
import SwiftUI

/// F4/F5 — the This Mac page: the battery (`WindowThisMacContent`), then its History.
/// Pure drawing, no AppKit controls: the window wraps it in a ScrollView, the render harness
/// draws it directly.
struct WindowMacPage: View {
    let mac: MacInfo
    let snapshot: BatterySnapshot?
    let temperatureUnit: Fmt.TemperatureUnit
    let lowPowerMode: Bool
    @Binding var detailsExpanded: Bool
    let history: [HistorySample]
    /// F11: macOS's condition (or an estimate); nil hides the card.
    var condition: BatteryCondition?
    /// F5 monthly table shown (collapsed by default).
    var historyTableExpanded: Binding<Bool> = .constant(false)
    /// nil hides the export button.
    var onExport: (() -> Void)?
    var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowThisMacContent(
                mac: mac, snapshot: snapshot, temperatureUnit: temperatureUnit,
                lowPowerMode: lowPowerMode, detailsExpanded: $detailsExpanded,
                condition: condition)
            // A Mac without a battery has no history to show.
            if snapshot != nil || !history.isEmpty {
                WindowHistorySection(
                    history: history, tableExpanded: historyTableExpanded, onExport: history.isEmpty ? nil : onExport,
                    exportMessage: exportMessage
                )
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
    }
}

/// F4 — the battery part of the This Mac page.
struct WindowThisMacContent: View {
    let mac: MacInfo
    let snapshot: BatterySnapshot?
    let temperatureUnit: Fmt.TemperatureUnit
    let lowPowerMode: Bool
    @Binding var detailsExpanded: Bool
    var condition: BatteryCondition?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WindowMacHeader(mac: mac)
            if let snapshot {
                WindowBatteryLevels(snapshot: snapshot)
                if let condition {
                    WindowConditionCard(condition: condition, deviceName: "Mac")
                }
                WindowCard {
                    WindowRowList(rows: snapshot.windowMainRows(unit: temperatureUnit, lowPowerMode: lowPowerMode))
                }
                WindowDetailsSection(rows: snapshot.windowDetailRows, expanded: $detailsExpanded)
            } else {
                WindowNoBattery()
            }
        }
        .padding(20)
    }
}

// MARK: - Header

private struct WindowMacHeader: View {
    let mac: MacInfo

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: mac.symbol)
                .font(.system(size: 40, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 64, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(mac.name)
                    .font(.title2.weight(.semibold))
                if let line = mac.windowDetailLine {
                    Text(line)
                        .foregroundStyle(.secondary)
                }
                Text(mac.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .padding(.top, 2)
                    .help("Device identifier")
                    .accessibilityLabel("Device identifier \(mac.identifier)")
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Charge and health bars

private struct WindowBatteryLevels: View {
    let snapshot: BatterySnapshot

    var body: some View {
        WindowCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Battery Charge").font(.headline)
                    Spacer()
                    Text(Fmt.mAh(snapshot.currentCapacityMAh))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                WindowMeterBar(
                    fraction: Double(snapshot.chargePercent) / 100,
                    label: "\(snapshot.chargePercent)%",
                    tint: snapshot.windowChargeTint
                )
                .padding(.top, 8)
                HStack(spacing: 5) {
                    Image(systemName: snapshot.windowStatusSymbol)
                        .foregroundStyle(snapshot.windowStatusTint)
                    Text(snapshot.windowStatusLine)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

                HStack(alignment: .firstTextBaseline) {
                    Text("Battery Health").font(.headline)
                    Spacer()
                    Text(snapshot.windowCapacityRatio)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 16)
                if let health = snapshot.healthPercent {
                    WindowMeterBar(
                        fraction: health / 100,
                        label: Fmt.percent(health),
                        tint: Self.healthTint(health)
                    )
                    .padding(.top, 8)
                } else {
                    Text(Fmt.dash).foregroundStyle(.tertiary).padding(.top, 6)
                }
            }
            .padding(14)
        }
    }

    static func healthTint(_ health: Double) -> Color {
        if health >= 80 { return .green }
        if health >= 60 { return .orange }
        return .red
    }
}

// MARK: - Details (collapsible)

private struct WindowDetailsSection: View {
    let rows: [WindowRow]
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Text("Details")
                        .font(.headline)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide details" : "Show details")

            if expanded {
                WindowCard { WindowRowList(rows: rows) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct WindowNoBattery: View {
    var body: some View {
        WindowCard {
            VStack(spacing: 8) {
                Image(systemName: "battery.0percent")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No battery found")
                    .font(.headline)
                Text("This Mac doesn't report an internal battery.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }
}

// MARK: - Derived display values

extension MacInfo {
    /// "14-inch, Nov 2024 · M4 Pro"
    fileprivate var windowDetailLine: String? {
        let parts = [detail, shortChip].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Apple M4 Pro" → "M4 Pro"; drops Intel's ® / ™ noise.
    fileprivate var shortChip: String? {
        guard var c = chip?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
        if c.hasPrefix("Apple ") { c.removeFirst("Apple ".count) }
        for noise in ["(R)", "(TM)", " CPU"] { c = c.replacingOccurrences(of: noise, with: "") }
        return c.replacingOccurrences(of: "  ", with: " ")
    }
}

extension BatterySnapshot {
    fileprivate var windowChargeTint: Color {
        guard powerState == .onBattery || powerState == .drainingOnAC else { return .green }
        if chargePercent <= 10 { return .red }
        if chargePercent <= 20 { return .orange }
        return .green
    }

    fileprivate var windowStatusSymbol: String {
        switch powerState {
        case .charging: return "bolt.fill"
        case .full: return "checkmark.circle.fill"
        case .onACNotCharging: return isChargeOnHold ? "pause.circle.fill" : "powerplug.fill"
        case .onBattery: return "battery.75percent"
        case .drainingOnAC: return "exclamationmark.triangle.fill"
        }
    }

    fileprivate var windowStatusTint: Color {
        switch powerState {
        case .charging, .full: return .green
        case .onACNotCharging: return isChargeOnHold ? .orange : .secondary
        case .onBattery: return .orange
        case .drainingOnAC: return PopoverPalette.drain
        }
    }

    /// "Charging · full in 58 min", "On battery · 4h 8m left", "Charging on hold",
    /// "Draining on charger · 6h 12m left".
    fileprivate var windowStatusLine: String {
        switch powerState {
        case .charging, .onBattery: return "\(statusTitle) · \(timeSummary)"
        case .drainingOnAC:
            guard let minutesToEmpty, minutesToEmpty > 0 else { return statusTitle }
            return "\(statusTitle) · \(Fmt.duration(minutes: minutesToEmpty)) left"
        case .full, .onACNotCharging: return statusTitle
        }
    }

    /// "5,955 of 6,249 mAh" next to the health bar; empty when either side is unknown.
    fileprivate var windowCapacityRatio: String {
        guard let full = fullChargeCapacityMAh ?? nominalChargeCapacityMAh, let designCapacityMAh else { return "" }
        let fullText = Fmt.mAh(full).replacingOccurrences(of: " mAh", with: "")
        return "\(fullText) of \(Fmt.mAh(designCapacityMAh))"
    }

    /// Main F4 rows. Manufacture date only when the registry exposes it.
    func windowMainRows(unit: Fmt.TemperatureUnit, lowPowerMode: Bool) -> [WindowRow] {
        var rows = [
            WindowRow(label: "Full Charge Capacity", value: Fmt.mAh(fullChargeCapacityMAh)),
            WindowRow(label: "Design Capacity", value: Fmt.mAh(designCapacityMAh)),
        ]
        if let manufactureDate {
            rows.append(
                WindowRow(
                    label: "Manufacture Date",
                    value: manufactureDate.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())))
        }
        rows += [
            WindowRow(label: "Charge Cycles", value: windowCycles),
            WindowRow(label: "Battery Temperature", value: Fmt.temperature(temperatureC, unit: unit)),
            windowPowerRow,
            WindowRow(label: "Power Adapter", value: windowAdapter),
            WindowRow(label: "Low Power Mode", value: lowPowerMode ? "On" : "Off"),
        ]
        return rows
    }

    /// Gauge, serial and electrical internals for the collapsible Details section.
    var windowDetailRows: [WindowRow] {
        [
            WindowRow(label: "Gauge", value: gaugeName ?? Fmt.dash),
            WindowRow(label: "Serial Number", value: serial ?? Fmt.dash),
            WindowRow(label: "Raw Charge", value: Fmt.percent(rawChargePercent, decimals: 1)),
            WindowRow(label: "Nominal Capacity", value: Fmt.mAh(nominalChargeCapacityMAh)),
            WindowRow(label: "Voltage", value: Fmt.volts(mV: voltageMV)),
            WindowRow(label: "Amperage", value: windowAmperage),
        ]
    }

    /// "183 of 1000", "183" without a design count, "—" when unknown.
    private var windowCycles: String {
        guard let cycleCount else { return Fmt.dash }
        guard let designCycleCount, designCycleCount > 0 else { return "\(cycleCount)" }
        return "\(cycleCount) of \(designCycleCount)"
    }

    private var windowPowerRow: WindowRow {
        guard let w = batteryPowerW else { return WindowRow(label: "Battery Power", value: Fmt.dash) }
        if w > 0.05 { return WindowRow(label: "Charging with", value: Fmt.watts(w)) }
        if w < -0.05 { return WindowRow(label: "Discharging with", value: Fmt.watts(abs(w))) }
        // Just unplugged: the gauge still reports 0 A for a few seconds.
        if powerState == .onBattery { return WindowRow(label: "Discharging with", value: "estimating…") }
        return WindowRow(label: "Battery Power", value: "Not charging")
    }

    /// "65 W · USB-C Power Delivery" / "Not connected".
    private var windowAdapter: String {
        guard externalConnected else { return "Not connected" }
        guard let adapter else { return "Connected" }
        // "USB-C Power Delivery" truncates in the window next to the label; use "USB-C PD".
        let kind = adapter.profiles.isEmpty ? adapter.displayKind : "USB-C PD"
        guard let watts = adapter.watts, watts > 0 else { return kind }
        return "\(watts) W · \(kind)"
    }

    /// "3.77 A in" / "1 A out" / "0 A".
    private var windowAmperage: String {
        guard let amperageMA else { return Fmt.dash }
        if amperageMA > 0 { return "\(Fmt.amps(mA: amperageMA)) in" }
        if amperageMA < 0 { return "\(Fmt.amps(mA: amperageMA)) out" }
        return Fmt.amps(mA: 0)
    }
}
