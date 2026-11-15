import BatteryKit
import SwiftUI

/// Display-ready strings and colours for one snapshot. Keeps the popover views free of
/// formatting logic; every unknown value comes out as `Fmt.dash`.
struct PopoverDisplay {
    let snapshot: BatterySnapshot
    var temperatureUnit: Fmt.TemperatureUnit = .celsius

    var state: PowerState { snapshot.powerState }
    var isOnHoldOrFull: Bool { state == .full || state == .onACNotCharging }

    // MARK: Header

    var statusIcon: String {
        switch state {
        case .charging: return "bolt.fill"
        case .full: return "checkmark.circle.fill"
        case .onBattery: return "battery.75percent"
        case .onACNotCharging: return snapshot.isChargeOnHold ? "pause.circle.fill" : "powerplug.fill"
        }
    }

    var statusColor: Color {
        switch state {
        case .charging, .full: return PopoverPalette.charge
        case .onBattery: return PopoverPalette.discharge
        case .onACNotCharging: return PopoverPalette.charger
        }
    }

    var subtitle: String { snapshot.adapter?.displayKind ?? "Battery" }

    /// Big number: into / out of the battery, or what the Mac pulls from the wall.
    var headline: (value: String, caption: String, color: Color) {
        switch state {
        case .charging:
            return (Fmt.watts(snapshot.batteryPowerW, signed: true), "into the battery", PopoverPalette.charge)
        case .onBattery:
            return (Fmt.watts(snapshot.batteryPowerW.map { abs($0) }), "out of the battery", PopoverPalette.discharge)
        case .full, .onACNotCharging:
            return (Fmt.watts(powerInW), "Mac draws from charger", PopoverPalette.charger)
        }
    }

    var chargeFraction: Double { (snapshot.rawChargePercent ?? Double(snapshot.chargePercent)) / 100 }
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

    var macNodeValue: String { "uses \(Fmt.watts(snapshot.macLoadW))" }

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
            return (Fmt.watts(snapshot.batteryPowerW.map { abs($0) }), "\(Fmt.amps(mA: snapshot.amperageMA)) out")
        case .full:
            return ("idle", "fully charged")
        case .onACNotCharging:
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

    var preciseCharge: Double { snapshot.rawChargePercent ?? Double(snapshot.chargePercent) }

    var timeRow: (label: String, value: String) {
        switch state {
        case .onBattery: return ("Time until empty", Fmt.duration(minutes: snapshot.minutesToEmpty))
        case .charging: return ("Time until full", Fmt.duration(minutes: snapshot.minutesToFull))
        case .full: return ("Time until full", "Fully charged")
        case .onACNotCharging: return ("Time until full", snapshot.isChargeOnHold ? "On hold" : "Not charging")
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
