import Foundation

/// One USB Power Delivery profile the charger advertises (e.g. 20 V / 3.25 A).
public struct PDProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var voltageMV: Int
    public var currentMA: Int

    public var id: Int { index }
    public var watts: Double { Double(voltageMV) * Double(currentMA) / 1_000_000 }

    public init(index: Int, voltageMV: Int, currentMA: Int) {
        self.index = index
        self.voltageMV = voltageMV
        self.currentMA = currentMA
    }
}

/// The connected power adapter, as reported by `AppleSmartBattery.AdapterDetails`.
public struct PowerAdapter: Codable, Equatable, Sendable {
    public var watts: Int?
    public var voltageMV: Int?
    public var currentMA: Int?
    public var description: String?
    public var isWireless: Bool
    public var profiles: [PDProfile]
    public var activeProfileIndex: Int?

    public var activeProfile: PDProfile? {
        guard let i = activeProfileIndex else { return nil }
        return profiles.first { $0.index == i }
    }

    /// "USB-C Power Delivery" when the adapter advertises PD profiles, else the raw description.
    public var displayKind: String {
        if !profiles.isEmpty { return "USB-C Power Delivery" }
        if isWireless { return "Wireless charger" }
        if let d = description, !d.isEmpty { return d.capitalized }
        return "Power adapter"
    }

    public init(watts: Int? = nil, voltageMV: Int? = nil, currentMA: Int? = nil,
                description: String? = nil, isWireless: Bool = false,
                profiles: [PDProfile] = [], activeProfileIndex: Int? = nil) {
        self.watts = watts
        self.voltageMV = voltageMV
        self.currentMA = currentMA
        self.description = description
        self.isWireless = isWireless
        self.profiles = profiles
        self.activeProfileIndex = activeProfileIndex
    }
}

public enum PowerState: String, Codable, Sendable {
    /// External power connected and battery is charging.
    case charging
    /// External power connected, battery not charging (full, optimized hold, charge limit).
    case onACNotCharging
    /// Running from the battery.
    case onBattery
    /// Fully charged on AC.
    case full
    /// Charger connected, but the Mac draws more than the charger supplies, so the battery
    /// discharges anyway (weak charger, heavy load).
    case drainingOnAC
}

/// Everything Battery Buddy knows about the battery at one moment.
/// Every hardware value that might be missing is optional; UIs render `nil` as "—".
public struct BatterySnapshot: Codable, Equatable, Sendable {
    public var timestamp: Date

    // Charge
    /// Percent macOS shows (0–100).
    public var chargePercent: Int
    /// Precise percent from raw mAh, e.g. 79.0.
    public var rawChargePercent: Double?
    public var currentCapacityMAh: Int?
    public var fullChargeCapacityMAh: Int?
    public var nominalChargeCapacityMAh: Int?
    public var designCapacityMAh: Int?

    // Wear
    public var cycleCount: Int?
    public var designCycleCount: Int?

    // Electrical
    public var voltageMV: Int?
    /// Signed: positive = into battery, negative = out of battery.
    public var amperageMA: Int?
    public var temperatureC: Double?

    // State
    public var isCharging: Bool
    public var externalConnected: Bool
    public var fullyCharged: Bool
    /// Non-zero when macOS is holding the charge (optimized charging, charge limit…).
    public var notChargingReason: Int?

    /// Minutes, nil when unknown / calculating.
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?

    // Power flow
    public var adapter: PowerAdapter?
    /// Whole-system draw in watts (PowerTelemetryData.SystemLoad).
    public var systemLoadW: Double?
    /// Power entering the Mac from the wall, in watts (PowerTelemetryData.SystemPowerIn).
    public var systemPowerInW: Double?

    // Identity
    public var serial: String?
    public var gaugeName: String?
    public var manufactureDate: Date?

    public init(timestamp: Date = Date(), chargePercent: Int, rawChargePercent: Double? = nil,
                currentCapacityMAh: Int? = nil, fullChargeCapacityMAh: Int? = nil,
                nominalChargeCapacityMAh: Int? = nil, designCapacityMAh: Int? = nil,
                cycleCount: Int? = nil, designCycleCount: Int? = nil,
                voltageMV: Int? = nil, amperageMA: Int? = nil, temperatureC: Double? = nil,
                isCharging: Bool = false, externalConnected: Bool = false, fullyCharged: Bool = false,
                notChargingReason: Int? = nil, minutesToEmpty: Int? = nil, minutesToFull: Int? = nil,
                adapter: PowerAdapter? = nil, systemLoadW: Double? = nil, systemPowerInW: Double? = nil,
                serial: String? = nil, gaugeName: String? = nil, manufactureDate: Date? = nil) {
        self.timestamp = timestamp
        self.chargePercent = chargePercent
        self.rawChargePercent = rawChargePercent
        self.currentCapacityMAh = currentCapacityMAh
        self.fullChargeCapacityMAh = fullChargeCapacityMAh
        self.nominalChargeCapacityMAh = nominalChargeCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.voltageMV = voltageMV
        self.amperageMA = amperageMA
        self.temperatureC = temperatureC
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.fullyCharged = fullyCharged
        self.notChargingReason = notChargingReason
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.adapter = adapter
        self.systemLoadW = systemLoadW
        self.systemPowerInW = systemPowerInW
        self.serial = serial
        self.gaugeName = gaugeName
        self.manufactureDate = manufactureDate
    }
}

// MARK: - Derived values

public extension BatterySnapshot {
    /// Battery discharge (W) on AC above which we call it "draining", not idle noise.
    static let drainThresholdW = 0.5

    var powerState: PowerState {
        if !externalConnected { return .onBattery }
        if isCharging { return .charging }
        if let w = batteryPowerW, w <= -Self.drainThresholdW { return .drainingOnAC }
        if fullyCharged { return .full }
        return .onACNotCharging
    }

    /// Battery health 0–100: full-charge capacity vs design capacity.
    var healthPercent: Double? {
        guard let design = designCapacityMAh, design > 0 else { return nil }
        guard let full = fullChargeCapacityMAh ?? nominalChargeCapacityMAh, full > 0 else { return nil }
        return min(100, Double(full) / Double(design) * 100)
    }

    /// Signed battery power in watts: + charging, − discharging.
    var batteryPowerW: Double? {
        guard let v = voltageMV, let a = amperageMA else { return nil }
        return Double(v) * Double(a) / 1_000_000
    }

    /// Power the Mac itself uses, in watts.
    var macLoadW: Double? {
        if let load = systemLoadW, load > 0 { return load }
        switch powerState {
        case .onBattery:
            return batteryPowerW.map { abs($0) }
        case .drainingOnAC:
            guard let inW = systemPowerInW ?? adapter?.watts.map(Double.init) else { return batteryPowerW.map { abs($0) } }
            return inW + abs(batteryPowerW ?? 0)
        default:
            guard let inW = systemPowerInW else { return nil }
            return max(0, inW - max(0, batteryPowerW ?? 0))
        }
    }

    /// Minutes for whichever direction is relevant right now.
    var minutesRemaining: Int? {
        switch powerState {
        case .onBattery, .drainingOnAC: return minutesToEmpty
        case .charging: return minutesToFull
        default: return nil
        }
    }

    var isChargeOnHold: Bool {
        externalConnected && !isCharging && !fullyCharged && (notChargingReason ?? 0) != 0
            && powerState != .drainingOnAC
    }

    /// Watts the Mac needs beyond what the charger supplies (only when draining on AC).
    var chargerDeficitW: Double? {
        guard powerState == .drainingOnAC, let w = batteryPowerW else { return nil }
        return abs(w)
    }
}
