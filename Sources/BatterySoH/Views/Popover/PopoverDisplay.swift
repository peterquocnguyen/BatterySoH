import BatteryKit
import SwiftUI

/// Display-ready strings and colours for one snapshot. Keeps the popover views free of
/// formatting logic; every unknown value comes out as `Fmt.dash`.
struct PopoverDisplay {
    let snapshot: BatterySnapshot
    var temperatureUnit: Fmt.TemperatureUnit = .celsius
    /// macOS charge limit (F8), when PowerUI could be read.
    var chargeLimit: ChargeLimitStatus?
    /// F11 battery condition, when known.
    var condition: BatteryCondition?

    var state: PowerState { snapshot.powerState }

    // MARK: Charge limit (F8)

    /// The limit percent when macOS's charge limit is what holds the charge right now.
    var heldAtLimitPercent: Int? {
        guard state == .onACNotCharging || state == .full else { return nil }
        return chargeLimit?.heldAtPercent
    }

    /// "Charge to Full Now" makes sense: on AC, held by the limit, override allowed, not full.
    var canChargeToFull: Bool {
        guard heldAtLimitPercent != nil, let limit = chargeLimit else { return false }
        return snapshot.externalConnected && limit.overrideAllowed && snapshot.chargePercent < 100
    }

    // MARK: Header

    /// BatteryKit's `statusTitle`, refined with the charge limit: "Charged to 80% limit".
    var statusTitle: String {
        if let percent = heldAtLimitPercent { return "Charged to \(percent)% limit" }
        return snapshot.statusTitle
    }

    /// Under the big percent: BatteryKit's summary, or "held at limit".
    var timeSummary: String {
        heldAtLimitPercent != nil ? "held at limit" : snapshot.timeSummary
    }

    var statusIcon: String {
        switch state {
        case .charging: return "bolt.fill"
        case .full: return "checkmark.circle.fill"
        case .onBattery: return "battery.75percent"
        case .onACNotCharging:
            if heldAtLimitPercent != nil { return "checkmark.circle.fill" }
            return snapshot.isChargeOnHold ? "pause.circle.fill" : "powerplug.fill"
        case .drainingOnAC: return "exclamationmark.triangle.fill"
        }
    }

    var statusColor: Color {
        switch state {
        case .charging, .full: return PopoverPalette.charge
        case .onBattery: return PopoverPalette.discharge
        case .onACNotCharging: return PopoverPalette.charger
        case .drainingOnAC: return PopoverPalette.drain
        }
    }

    /// Adapter kind on external power; on battery the title already says "On battery".
    var subtitle: String {
        guard snapshot.externalConnected else { return "Internal battery" }
        return snapshot.adapter?.displayKind ?? "Power adapter"
    }

    /// Big number: into / out of the battery, or what the Mac pulls from the wall.
    var headline: (value: String, caption: String, color: Color) {
        switch state {
        case .charging:
            return (Fmt.watts(snapshot.batteryPowerW, signed: true), "into the battery", PopoverPalette.charge)
        case .onBattery:
            return (Fmt.watts(dischargeW), "out of the battery", PopoverPalette.discharge)
        case .full, .onACNotCharging:
            return (Fmt.watts(powerInW), "Mac draws from charger", PopoverPalette.charger)
        case .drainingOnAC:
            return (Fmt.watts(snapshot.batteryPowerW), "drawn from the battery", PopoverPalette.drain)
        }
    }

    /// Watts leaving the battery on battery power. Right after unplugging macOS still reports
    /// 0 A for a few seconds; then the Mac's own load is the best estimate (nil → "—").
    var dischargeW: Double? {
        if !isEstimatingDischarge, let w = snapshot.batteryPowerW { return abs(w) }
        guard let load = snapshot.macLoadW, load >= 0.05 else { return nil }
        return load
    }

    /// On battery but the gauge has no current reading yet.
    var isEstimatingDischarge: Bool {
        guard state == .onBattery else { return false }
        guard let w = snapshot.batteryPowerW else { return true }
        return abs(w) < 0.05
    }

    /// The percent macOS shows (`CurrentCapacity`); the raw value lives in the window's Details.
    var chargeFraction: Double { Double(snapshot.chargePercent) / 100 }
    var chargeText: String { "\(snapshot.chargePercent)%" }
    var chargeColor: Color { PopoverPalette.chargeLevel(chargeFraction * 100, state: state) }

    // MARK: Flow

    /// Power entering the Mac from the charger. Falls back to load + charge power.
    var powerInW: Double? {
        guard snapshot.externalConnected else { return nil }
        if let inW = snapshot.systemPowerInW, inW > 0 { return inW }
        guard let load = snapshot.macLoadW else { return nil }
        return load + max(0, snapshot.batteryPowerW ?? 0)
    }

    var chargerNodeValue: String {
        guard snapshot.externalConnected else { return "unplugged" }
        return Fmt.watts(snapshot.adapter?.watts.map(Double.init))
    }

    var macNodeValue: String {
        // Whole watts while draining so the node matches the "about 74 W" banner.
        if state == .drainingOnAC, let load = snapshot.macLoadW { return "uses \(Fmt.watts(load.rounded()))" }
        return "uses \(Fmt.watts(snapshot.macLoadW))"
    }

    /// "The Mac uses about 74 W — more than the charger's 65 W, so the battery drains anyway."
    var drainExplanation: String? {
        guard state == .drainingOnAC else { return nil }
        let load = snapshot.macLoadW.map { Fmt.watts($0.rounded()) }
        let charger = (snapshot.adapter?.watts.map(Double.init) ?? powerInW).map { Fmt.watts($0.rounded()) }
        switch (load, charger) {
        case let (load?, charger?):
            return "The Mac uses about \(load) — more than the charger's \(charger), so the battery drains anyway."
        case let (load?, nil):
            return "The Mac uses about \(load) — more than the charger supplies, so the battery drains anyway."
        default:
            return "The Mac uses more power than the charger supplies, so the battery drains anyway."
        }
    }

    /// "20 V · 3.25 A" from the negotiated profile, else the adapter's own V/A.
    var chargerElectrical: String {
        let profile = snapshot.adapter?.activeProfile
        let mV = profile?.voltageMV ?? snapshot.adapter?.voltageMV
        let mA = profile?.currentMA ?? snapshot.adapter?.currentMA
        guard mV != nil || mA != nil else { return Fmt.dash }
        return "\(Fmt.volts(mV: mV)) · \(Fmt.amps(mA: mA))"
    }

    var batteryElectrical: String {
        guard snapshot.voltageMV != nil || snapshot.amperageMA != nil else { return Fmt.dash }
        return "\(Fmt.volts(mV: snapshot.voltageMV)) · \(Fmt.amps(mA: snapshot.amperageMA))"
    }

    /// Mac ↔ battery link labels.
    var batteryLink: (top: String, bottom: String) {
        switch state {
        case .charging:
            return (Fmt.watts(snapshot.batteryPowerW, signed: true), "\(Fmt.amps(mA: snapshot.amperageMA)) in")
        case .onBattery:
            if isEstimatingDischarge { return (Fmt.watts(dischargeW), "estimating…") }
            return (Fmt.watts(dischargeW), "\(Fmt.amps(mA: snapshot.amperageMA)) out")
        case .drainingOnAC:
            return (Fmt.watts(snapshot.batteryPowerW), "\(Fmt.amps(mA: snapshot.amperageMA)) out")
        case .full:
            return ("idle", "fully charged")
        case .onACNotCharging:
            if let percent = heldAtLimitPercent { return ("idle", "at \(percent)% limit") }
            return ("idle", snapshot.isChargeOnHold ? "on hold" : "not charging")
        }
    }

    // MARK: Tiles

    var chargerTile: String {
        guard snapshot.externalConnected else { return "Unplugged" }
        return Fmt.watts(snapshot.adapter?.watts.map(Double.init))
    }

    var profileTile: String { snapshot.externalConnected ? chargerElectrical : Fmt.dash }

    var temperature: String { Fmt.temperature(snapshot.temperatureC, unit: temperatureUnit) }

    var profiles: [PDProfile] {
        guard snapshot.externalConnected else { return [] }
        return snapshot.adapter?.profiles ?? []
    }

    var activeProfileIndex: Int? { snapshot.adapter?.activeProfileIndex }

    // MARK: Summary

    var timeRow: (label: String, value: String) {
        switch state {
        case .onBattery, .drainingOnAC: return ("Time until empty", Fmt.duration(minutes: snapshot.minutesToEmpty))
        case .charging: return ("Time until full", Fmt.duration(minutes: snapshot.minutesToFull))
        case .full: return ("Time until full", "Fully charged")
        case .onACNotCharging:
            if let percent = heldAtLimitPercent { return ("Time until full", "Held at \(percent)% limit") }
            return ("Time until full", snapshot.isChargeOnHold ? "On hold" : "Not charging")
        }
    }

    var cycles: String {
        guard let count = snapshot.cycleCount else { return Fmt.dash }
        if let design = snapshot.designCycleCount, design > 0 { return "\(count) of \(design)" }
        return "\(count)"
    }

    // MARK: Animation

    /// Seconds per dot cycle: more watts → faster dots, clamped to stay readable.
    static func period(forWatts watts: Double?) -> Double {
        let w = abs(watts ?? 0)
        return min(2.4, max(0.9, 2.4 - w * 0.025))
    }
}
