import Foundation

/// A battery in some other device: an iPhone or iPad seen over USB / Wi-Fi sync, or a
/// Bluetooth / USB accessory (AirPods, Magic Mouse, keyboard, controller…).
/// Every hardware value that might be missing is optional; UIs render `nil` as "—".
public struct DeviceBattery: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case iPhone, iPad, iPod, watch, airPods, headphones, mouse, keyboard, trackpad,
             gameController, pencil, other
    }

    public enum Connection: String, Codable, Sendable {
        /// `nearby`: seen wirelessly through Instant Hotspot (same Apple Account), charge only.
        case usb, wifi, bluetooth, nearby, other
    }

    /// One battery of a multi-battery accessory (AirPods left / right / case).
    public struct Part: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var percent: Int?
        public var isCharging: Bool

        public var id: String { name }

        public init(name: String, percent: Int?, isCharging: Bool = false) {
            self.name = name
            self.percent = percent
            self.isCharging = isCharging
        }
    }

    /// Stable identity for the list (UDID or accessory identifier). Never displayed.
    public var id: String
    public var name: String
    public var kind: Kind
    public var connection: Connection?
    /// Product type, e.g. "iPhone17,1".
    public var model: String?
    /// e.g. "iOS 26.1"
    public var osVersion: String?

    /// Charge the device itself shows (0–100). For multi-part accessories: the lowest bud.
    public var percent: Int?
    public var isCharging: Bool
    public var externalConnected: Bool
    public var parts: [Part]

    // Health — only iPhone / iPad over a trusted connection report these.
    public var fullChargeCapacityMAh: Int?
    public var designCapacityMAh: Int?
    public var cycleCount: Int?
    public var temperatureC: Double?

    /// Why some values are missing, e.g. "Unlock iPhone and tap Trust".
    public var note: String?

    /// True when `percent` is a level the device advertised (Instant Hotspot), not a live read:
    /// it can lag well behind the device, and there is no charging state. UIs show "≈ 75%",
    /// a neutral bar and no charging claims.
    public var isApproximate: Bool
    /// How current `percent` is. Exact reads (USB / Wi-Fi sync): when the read was taken.
    /// Approximate (Instant Hotspot): when this app first saw the current advertised value
    /// ("since 12:03"), carried across updates by `HotspotParser.carryUpdatedAt`.
    /// nil for accessories (read on every UI tick).
    public var updatedAt: Date?
    /// True when the device is not connected and this is its last exact reading, kept by
    /// `LastExactReadingStore` (see `lastKnown`). UIs fade it and say "not connected".
    public var isLastKnown: Bool

    /// Full / design, percent with one decimal.
    public var healthPercent: Double? {
        guard let full = fullChargeCapacityMAh, let design = designCapacityMAh, design > 0, full > 0 else { return nil }
        return (Double(full) / Double(design) * 1000).rounded() / 10
    }

    public init(id: String, name: String, kind: Kind, connection: Connection? = nil,
                model: String? = nil, osVersion: String? = nil, percent: Int?,
                isCharging: Bool = false, externalConnected: Bool = false, parts: [Part] = [],
                fullChargeCapacityMAh: Int? = nil, designCapacityMAh: Int? = nil,
                cycleCount: Int? = nil, temperatureC: Double? = nil, note: String? = nil,
                isApproximate: Bool = false, updatedAt: Date? = nil, isLastKnown: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.connection = connection
        self.model = model
        self.osVersion = osVersion
        self.percent = percent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.parts = parts
        self.fullChargeCapacityMAh = fullChargeCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.cycleCount = cycleCount
        self.temperatureC = temperatureC
        self.note = note
        self.isApproximate = isApproximate
        self.updatedAt = updatedAt
        self.isLastKnown = isLastKnown
    }

    /// iPhone, iPad or iPod (the devices MobileDevice and Instant Hotspot report).
    public var isIOSDevice: Bool { [.iPhone, .iPad, .iPod].contains(kind) }

    /// An exact reading worth remembering once the device disconnects.
    public var isExactReading: Bool { isIOSDevice && !isApproximate && !isLastKnown && percent != nil }

    /// This reading as the last exact one of a device that is no longer connected: no
    /// connection, no charging claim (the charger may be long gone), no trust note.
    public var lastKnown: DeviceBattery {
        var d = self
        d.isLastKnown = true
        d.connection = nil
        d.isCharging = false
        d.externalConnected = false
        d.note = nil
        return d
    }
}

// MARK: - Accessories (IOPowerSources)

/// Pure conversion from IOPowerSources accessory descriptions (what `pmset -g accps` lists)
/// to `DeviceBattery` values. Parts sharing a group (AirPods buds + case) become one device.
public enum AccessoryParser {
    public static func parse(_ sources: [[String: Any]]) -> [DeviceBattery] {
        var order: [String] = []
        var groups: [String: [[String: Any]]] = [:]
        for source in sources {
            if BatteryParser.string(source["Type"]) == "InternalBattery" { continue }
            if BatteryParser.string(source["Transport Type"]) == "Internal" { continue }
            if BatteryParser.bool(source["Is Present"]) == false { continue }
            let key = BatteryParser.string(source["Group Identifier"])
                ?? BatteryParser.string(source["Accessory Identifier"])
                ?? BatteryParser.int(source["Power Source ID"]).map(String.init)
                ?? BatteryParser.string(source["Name"])
                ?? UUID().uuidString
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(source)
        }
        return order.compactMap { key in device(id: key, sources: groups[key] ?? []) }
    }

    static func device(id: String, sources: [[String: Any]]) -> DeviceBattery? {
        guard let first = sources.first else { return nil }
        let name = BatteryParser.string(first["Name"]) ?? "Accessory"
        let category = BatteryParser.string(first["Accessory Category"])
        let kind = Self.kind(category: category, name: name)

        var parts: [DeviceBattery.Part] = []
        if sources.count > 1 || partName(first) != nil {
            parts = sources.map { s in
                DeviceBattery.Part(name: partName(s) ?? BatteryParser.string(s["Name"]) ?? "Battery",
                                   percent: percent(s), isCharging: charging(s))
            }
            parts.sort { partRank($0.name) < partRank($1.name) }
        }

        let percent: Int?
        if parts.isEmpty {
            percent = Self.percent(first)
        } else {
            let buds = parts.filter { $0.name != "Case" }.compactMap(\.percent)
            percent = buds.min() ?? parts.compactMap(\.percent).min()
        }
        let isCharging = parts.isEmpty ? charging(first) : parts.contains { $0.isCharging && $0.name != "Case" }

        return DeviceBattery(
            id: id, name: name, kind: kind, connection: connection(first),
            percent: percent, isCharging: isCharging,
            externalConnected: BatteryParser.string(first["Power Source State"]) == "AC Power",
            parts: parts)
    }

    static func percent(_ s: [String: Any]) -> Int? {
        guard let current = BatteryParser.int(s["Current Capacity"]), current >= 0 else { return nil }
        let max = BatteryParser.int(s["Max Capacity"]) ?? 100
        guard max > 0 else { return nil }
        return min(100, Int((Double(current) / Double(max) * 100).rounded()))
    }

    static func charging(_ s: [String: Any]) -> Bool {
        BatteryParser.bool(s["Is Charging"]) ?? false
    }

    /// "Left" / "Right" / "Case" for AirPods-style parts; nil for single-battery accessories.
    static func partName(_ s: [String: Any]) -> String? {
        guard let raw = BatteryParser.string(s["Part Identifier"]) ?? BatteryParser.string(s["Part Name"]) else { return nil }
        let lower = raw.lowercased()
        if lower.contains("left") { return "Left" }
        if lower.contains("right") { return "Right" }
        if lower.contains("case") { return "Case" }
        if lower.contains("single") || lower.contains("combined") { return nil }
        return raw.capitalized
    }

    static func partRank(_ name: String) -> Int {
        switch name {
        case "Left": return 0
        case "Right": return 1
        case "Case": return 2
        default: return 3
        }
    }

    static func connection(_ s: [String: Any]) -> DeviceBattery.Connection? {
        guard let t = BatteryParser.string(s["Transport Type"])?.lowercased() else { return nil }
        if t.contains("bluetooth") { return .bluetooth }
        if t.contains("usb") { return .usb }
        return .other
    }

    static func kind(category: String?, name: String) -> DeviceBattery.Kind {
        let c = category?.lowercased() ?? ""
        let n = name.lowercased()
        if n.contains("airpods") { return .airPods }
        if c.contains("mouse") { return .mouse }
        if c.contains("trackpad") { return .trackpad }
        if c.contains("keyboard") { return .keyboard }
        if c.contains("game") || c.contains("controller") { return .gameController }
        if c.contains("headphone") || c.contains("headset") || c.contains("audio") || c.contains("speaker") { return .headphones }
        if c.contains("watch") { return .watch }
        if c.contains("pencil") || c.contains("stylus") { return .pencil }
        if n.contains("mouse") { return .mouse }
        if n.contains("trackpad") { return .trackpad }
        if n.contains("keyboard") { return .keyboard }
        if n.contains("controller") { return .gameController }
        if n.contains("beats") || n.contains("headphone") || n.contains("buds") { return .headphones }
        return .other
    }
}

// MARK: - iPhone / iPad (lockdown + diagnostics relay)

/// Pure conversion from the values MobileDevice reads off an iPhone / iPad.
/// - `lockdown`: root-domain values (`DeviceName`, `DeviceClass`, `ProductType`, `ProductVersion`).
/// - `battery`: `com.apple.mobile.battery` domain (`BatteryCurrentCapacity`, `BatteryIsCharging`,
///   `ExternalConnected`).
/// - `registry`: diagnostics relay IORegistry dump of the device's `IOPMPowerSource`, when the
///   device is trusted (capacities, cycles, temperature).
public enum MobileBatteryParser {
    public static func parse(id: String, lockdown: [String: Any], battery: [String: Any],
                             registry: [String: Any]?, connection: DeviceBattery.Connection?,
                             note: String? = nil, updatedAt: Date? = nil) -> DeviceBattery {
        let deviceClass = BatteryParser.string(lockdown["DeviceClass"])
        let kind = kind(deviceClass: deviceClass, productType: BatteryParser.string(lockdown["ProductType"]))
        let name = BatteryParser.string(lockdown["DeviceName"]) ?? deviceClass ?? "iOS device"
        let reg = registry ?? [:]
        let batteryData = reg["BatteryData"] as? [String: Any] ?? [:]

        let percent = BatteryParser.int(battery["BatteryCurrentCapacity"]) ?? BatteryParser.int(reg["CurrentCapacity"])
        let charging = BatteryParser.bool(battery["BatteryIsCharging"]) ?? BatteryParser.bool(reg["IsCharging"]) ?? false
        let external = BatteryParser.bool(battery["ExternalConnected"]) ?? BatteryParser.bool(reg["ExternalConnected"]) ?? false

        // Registry's percent-scale values (MaxCapacity = 100) are not mAh; prefer the raw keys.
        let full = BatteryParser.positive(BatteryParser.int(reg["AppleRawMaxCapacity"])
            ?? BatteryParser.int(reg["NominalChargeCapacity"])
            ?? BatteryParser.int(batteryData["FullChargeCapacity"]))
        let design = BatteryParser.positive(BatteryParser.int(reg["DesignCapacity"])
            ?? BatteryParser.int(batteryData["DesignCapacity"]))

        return DeviceBattery(
            id: id, name: name, kind: kind, connection: connection,
            model: BatteryParser.string(lockdown["ProductType"]),
            osVersion: osVersion(kind: kind, version: BatteryParser.string(lockdown["ProductVersion"])),
            percent: percent.map { max(0, min(100, $0)) },
            isCharging: charging, externalConnected: external,
            fullChargeCapacityMAh: full, designCapacityMAh: design,
            cycleCount: BatteryParser.int(reg["CycleCount"]) ?? BatteryParser.int(batteryData["CycleCount"]),
            temperatureC: registry.flatMap(BatteryParser.temperature),
            note: note, updatedAt: updatedAt)
    }

    static func kind(deviceClass: String?, productType: String?) -> DeviceBattery.Kind {
        let s = (deviceClass ?? productType ?? "").lowercased()
        if s.hasPrefix("iphone") { return .iPhone }
        if s.hasPrefix("ipad") { return .iPad }
        if s.hasPrefix("ipod") { return .iPod }
        if s.hasPrefix("watch") { return .watch }
        return .other
    }

    static func osVersion(kind: DeviceBattery.Kind, version: String?) -> String? {
        guard let version else { return nil }
        switch kind {
        case .iPad: return "iPadOS \(version)"
        case .watch: return "watchOS \(version)"
        default: return "iOS \(version)"
        }
    }
}

// MARK: - Last exact reading per device

/// The last exact (USB / Wi-Fi sync) reading of each iPhone / iPad, so a device that
/// disconnects (phone asleep, off the network) keeps showing its real level — faded, "not
/// connected" — instead of the far older Instant Hotspot value. One small JSON file,
/// `~/Library/Application Support/BatteryBuddy/last-exact-readings.json`, written atomically.
///
/// Cheap by design: a read only writes the file when something other than the time changed,
/// or `writeInterval` has passed; `flush()` writes the rest (on disconnect and on quit).
public final class LastExactReadingStore {
    public let fileURL: URL
    /// By device id (UDID).
    public private(set) var readings: [String: DeviceBattery] = [:]
    private var lastWrite = Date.distantPast
    private var dirty = false

    public static let writeInterval: TimeInterval = 5 * 60
    /// A device not read for this long (sold, replaced, Wi-Fi sync off) is forgotten.
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// True when `reading` is older than `maxAge`. Readings without a time are kept.
    public static func isExpired(_ reading: DeviceBattery, now: Date = Date()) -> Bool {
        guard let updated = reading.updatedAt else { return false }
        return now.timeIntervalSince(updated) > maxAge
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BatteryBuddy", isDirectory: true)
            .appendingPathComponent("last-exact-readings.json")
    }

    public init(fileURL: URL = LastExactReadingStore.defaultURL, now: Date = Date()) {
        self.fileURL = fileURL
        load(now: now)
    }

    /// Remembered readings younger than `maxAge`, by name.
    public var devices: [DeviceBattery] { devices(now: Date()) }

    public func devices(now: Date) -> [DeviceBattery] {
        readings.values.filter { !Self.isExpired($0, now: now) }.sorted { a, b in
            a.name.localizedStandardCompare(b.name) == .orderedAscending || (a.name == b.name && a.id < b.id)
        }
    }

    private struct File: Codable {
        var version = 1
        var devices: [DeviceBattery]
    }

    public func load(now: Date = Date()) {
        readings = [:]
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? Self.decoder.decode(File.self, from: data) else { return }
        for d in file.devices where d.isExactReading {
            if Self.isExpired(d, now: now) { dirty = true } else { readings[d.id] = d }
        }
        // Drop expired devices from disk right away.
        if dirty { try? write(now: now) }
    }

    /// Keeps every exact reading in `devices` (others are ignored). Returns true when the
    /// file was written.
    @discardableResult
    public func remember(_ devices: [DeviceBattery], now: Date = Date()) throws -> Bool {
        var changed = false
        for d in devices where d.isExactReading {
            let old = readings[d.id]
            guard old != d else { continue }
            readings[d.id] = d
            dirty = true
            if !Self.sameExceptTime(old, d) { changed = true }
        }
        guard dirty, changed || now.timeIntervalSince(lastWrite) >= Self.writeInterval else { return false }
        try write(now: now)
        return true
    }

    /// Writes readings that are only in memory.
    public func flush(now: Date = Date()) throws {
        guard dirty else { return }
        try write(now: now)
    }

    private func write(now: Date) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        readings = readings.filter { !Self.isExpired($0.value, now: now) }
        try Self.encoder.encode(File(devices: devices(now: now))).write(to: fileURL, options: .atomic)
        lastWrite = now
        dirty = false
    }

    private static func sameExceptTime(_ a: DeviceBattery?, _ b: DeviceBattery) -> Bool {
        guard var a else { return false }
        a.updatedAt = b.updatedAt
        return a == b
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
