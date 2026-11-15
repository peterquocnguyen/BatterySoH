import Foundation

/// Display strings shared by the app and the CLI. `nil` input renders as "—".
public enum Fmt {
    public static let dash = "—"

    /// 47.2 → "47.2 W", 65 → "65 W"
    public static func watts(_ w: Double?, signed: Bool = false) -> String {
        guard let w else { return dash }
        let body = abs(w) >= 10 && abs(w).truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", abs(w)) : String(format: "%.1f", abs(w))
        let sign = signed ? (w > 0 ? "+" : (w < 0 ? "−" : "")) : (w < 0 ? "−" : "")
        return "\(sign)\(body) W"
    }

    /// 20000 → "20 V", 12520 → "12.52 V"
    public static func volts(mV: Int?) -> String {
        guard let mV else { return dash }
        let v = Double(mV) / 1000
        if v.truncatingRemainder(dividingBy: 1) == 0 { return String(format: "%.0f V", v) }
        return trimZeros(String(format: "%.2f", v)) + " V"
    }

    /// 3250 → "3.25 A", -1200 → "1.2 A" (sign dropped; callers say "in"/"out").
    public static func amps(mA: Int?) -> String {
        guard let mA else { return dash }
        return trimZeros(String(format: "%.2f", abs(Double(mA)) / 1000)) + " A"
    }

    /// Short PD chip label: 20000 mV / 3250 mA → "20V/3.25A"
    public static func profile(_ p: PDProfile) -> String {
        "\(trimZeros(String(format: "%.1f", Double(p.voltageMV) / 1000)))V/\(trimZeros(String(format: "%.2f", Double(p.currentMA) / 1000)))A"
    }

    public static func percent(_ p: Double?, decimals: Int = 0) -> String {
        guard let p else { return dash }
        return String(format: "%.\(decimals)f%%", p)
    }

    /// 248 → "4h 8m", 58 → "58 min", nil → "—"
    public static func duration(minutes: Int?) -> String {
        guard let m = minutes, m > 0 else { return dash }
        if m < 60 { return "\(m) min" }
        return "\(m / 60)h \(m % 60)m"
    }

    public enum TemperatureUnit: String, CaseIterable, Codable, Sendable { case celsius, fahrenheit }

    public static func temperature(_ c: Double?, unit: TemperatureUnit = .celsius) -> String {
        guard let c else { return dash }
        switch unit {
        case .celsius: return String(format: "%.1f °C", c)
        case .fahrenheit: return String(format: "%.1f °F", c * 9 / 5 + 32)
        }
    }

    /// 5955 → "5,955 mAh"
    public static func mAh(_ v: Int?) -> String {
        guard let v else { return dash }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return (f.string(from: NSNumber(value: v)) ?? String(v)) + " mAh"
    }

    /// How current a reading is, for "Updated …" / "Last updated …" captions:
    /// under a minute "just now", under an hour "3 min ago", earlier today the time ("12:40"),
    /// another day the date ("14 Nov"; with the year when it isn't this year).
    public static func freshness(_ date: Date, now: Date, calendar: Calendar = .current,
                                 locale: Locale = .current) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return "just now" }
        if age < 3600 { return "\(Int(age / 60)) min ago" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        if calendar.isDate(date, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("jmm")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            f.setLocalizedDateFormatFromTemplate("dMMM")
        } else {
            f.setLocalizedDateFormatFromTemplate("dMMMy")
        }
        return f.string(from: date)
    }

    static func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var out = s
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }
}

public extension BatterySnapshot {
    /// Headline for the popover header.
    var statusTitle: String {
        switch powerState {
        case .charging: return "Charging"
        case .full: return "Fully charged"
        case .onBattery: return "On battery"
        case .onACNotCharging: return isChargeOnHold ? "Charging on hold" : "Charger connected"
        case .drainingOnAC: return "Draining on charger"
        }
    }

    /// "full in 58 min" / "4h 8m left" / "not charging"
    var timeSummary: String {
        switch powerState {
        case .charging:
            return minutesToFull.map { "full in \(Fmt.duration(minutes: $0))" } ?? "calculating…"
        case .onBattery:
            return minutesToEmpty.map { "\(Fmt.duration(minutes: $0)) left" } ?? "calculating…"
        case .full: return "fully charged"
        case .onACNotCharging: return "not charging"
        case .drainingOnAC: return "draining despite charger"
        }
    }
}
