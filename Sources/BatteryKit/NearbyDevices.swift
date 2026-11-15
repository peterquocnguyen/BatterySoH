import Foundation
import ObjectiveC

/// iPhone / iPad charge without a cable, from the Instant Hotspot browser in Apple's private
/// `Sharing.framework` — the same source as the battery level the Wi-Fi menu shows next to a
/// Personal Hotspot. Works for devices on the same Apple Account with Bluetooth on and a
/// cellular plan that offers Personal Hotspot. Gives name (truncated by the Bluetooth
/// advertisement), model and charge %; no charging state, no health.
///
/// The charge is the level the device last put in its hotspot advertisement, not a live read.
/// Observed on an iPhone 14 Plus: two fresh sessions minutes apart both reported 75 %
/// (`cachedDevice = 0`, `lastSeen = 0`) while the phone showed 91 % and charging. Every result
/// is therefore `isApproximate`; the app restarts browsing (`stop()` + `start()`) about once a
/// minute while visible in case the device re-advertises.
///
/// Private-API use lives only in this file; everything is looked up at runtime, and if the
/// classes are missing the browser is unavailable (`init` returns nil).
///
/// Threading: Sharing calls the delegate on an XPC queue; results hop to the main thread.
/// Browse only while a UI surface is visible (`start()` / `stop()`).
public final class NearbyHotspotBrowser: @unchecked Sendable {
    private let session: NSObject
    private let delegate: Delegate

    /// `onChange` is called on the main thread with the nearby devices.
    public init?(onChange: @escaping ([DeviceBattery]) -> Void) {
        guard dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_LAZY) != nil,
              let cls = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type,
              cls.instancesRespond(to: Sel.setDelegate),
              cls.instancesRespond(to: Sel.startBrowsing),
              cls.instancesRespond(to: Sel.stopBrowsing) else { return nil }
        session = cls.init()
        delegate = Delegate(onChange: onChange)
        // The session holds its delegate weakly; `self.delegate` keeps it alive.
        session.perform(Sel.setDelegate, with: delegate)
    }

    deinit { stop() }

    public func start() { session.perform(Sel.startBrowsing) }

    public func stop() { session.perform(Sel.stopBrowsing) }

    private enum Sel {
        static let setDelegate = NSSelectorFromString("setDelegate:")
        static let startBrowsing = NSSelectorFromString("startBrowsing")
        static let stopBrowsing = NSSelectorFromString("stopBrowsing")
    }

    /// Sharing sends `session:updatedFoundDevices:` without checking `respondsToSelector:`,
    /// so this method must exist under exactly that selector.
    private final class Delegate: NSObject {
        let onChange: ([DeviceBattery]) -> Void

        init(onChange: @escaping ([DeviceBattery]) -> Void) {
            self.onChange = onChange
        }

        @objc(session:updatedFoundDevices:)
        func session(_ session: AnyObject?, updatedFoundDevices list: AnyObject?) {
            let devices = (list as? [NSObject] ?? []).compactMap { d -> DeviceBattery? in
                func value(_ key: String) -> Any? {
                    d.responds(to: NSSelectorFromString(key)) ? d.value(forKey: key) : nil
                }
                return HotspotParser.parse(identifier: value("deviceIdentifier") as? String,
                                           name: value("deviceName") as? String,
                                           model: value("model") as? String,
                                           batteryLife: value("batteryLife"))
            }
            let onChange = self.onChange
            DispatchQueue.main.async { onChange(devices) }
        }
    }
}

/// Pure conversion of one Instant Hotspot advertisement to a `DeviceBattery`.
public enum HotspotParser {
    /// The Bluetooth advertisement carries at most this many UTF-8 bytes of the device name
    /// (observed: a 14-character "…’s iPhone" name arrives cut to its first 12 bytes).
    static let advertisedNameBytes = 12

    public static func parse(identifier: String?, name: String?, model: String?, batteryLife: Any?) -> DeviceBattery? {
        let model = BatteryParser.string(model)
        let kind = MobileBatteryParser.kind(deviceClass: nil, productType: model)
        let fallback = kind == .other ? "Nearby device" : kind.rawValue
        var display = BatteryParser.string(name) ?? fallback
        if display.utf8.count >= advertisedNameBytes { display += "…" }
        // 0 is what a device advertises before it knows its level; a phone at 0 % is off.
        let percent = BatteryParser.int(batteryLife).flatMap { (1...100).contains($0) ? $0 : nil }
        guard let id = BatteryParser.string(identifier) ?? model.map({ "\($0)-\(display)" }) else { return nil }
        return DeviceBattery(id: "hotspot-\(id)", name: display, kind: kind, connection: .nearby,
                             model: model, percent: percent,
                             note: approximateNote(kind: kind), isApproximate: true)
    }

    /// Caption for an approximate (advertised) level.
    public static func approximateNote(kind: DeviceBattery.Kind) -> String {
        let device = kind == .iPad ? "iPad" : (kind == .iPhone ? "iPhone" : "device")
        return "Last level the \(device) shared over Personal Hotspot. It can lag well behind the \(device == "iPhone" ? "phone" : device)."
    }

    /// The part of a device name an Instant Hotspot advertisement carries: at most
    /// `advertisedNameBytes` UTF-8 bytes, cut at a character boundary, without the "…" marker.
    /// "Peter’s iPhone" and the advertised "Peter’s iP…" give the same stem, so a phone's
    /// cabled and hotspot readings can share one charge log.
    public static func advertisedStem(_ name: String) -> String {
        let trimmed = name.hasSuffix("…") ? String(name.dropLast()) : name
        var out = ""
        var bytes = 0
        for ch in trimmed {
            let n = String(ch).utf8.count
            if bytes + n > advertisedNameBytes { break }
            out.append(ch)
            bytes += n
        }
        return out
    }

    /// Keeps `updatedAt` from the previous list while a device's advertised percent is
    /// unchanged; stamps `now` when the device or its percent is new (so it is "first seen").
    public static func carryUpdatedAt(previous: [DeviceBattery], current: [DeviceBattery], now: Date) -> [DeviceBattery] {
        current.map { device in
            var d = device
            if let old = previous.first(where: { $0.id == d.id }), old.percent == d.percent, let since = old.updatedAt {
                d.updatedAt = since
            } else {
                d.updatedAt = d.percent == nil ? nil : now
            }
            return d
        }
    }

    /// iPhone / iPad list in order of trust: exact connected reads (live level, charging state,
    /// health) > the last exact reading of a device that is no longer connected (`lastKnown`)
    /// > an Instant Hotspot level for a device never read exactly.
    ///
    /// A remembered reading is dropped when the same device (id) is connected. A hotspot entry is
    /// dropped when a connected or remembered device has the same model and a name that starts
    /// with the advertised name stem. `knownNames` are other exact device names (e.g. from the
    /// charge log) used only to fix the "…" on an advertised name that wasn't cut after all.
    public static func merge(connected: [DeviceBattery], remembered: [DeviceBattery] = [],
                             nearby: [DeviceBattery], knownNames: [String] = []) -> [DeviceBattery] {
        let connectedIDs = Set(connected.map(\.id))
        let lastKnown = remembered.filter { !connectedIDs.contains($0.id) && $0.isExactReading }.map(\.lastKnown)
        let exact = connected + lastKnown
        let names = Set(exact.map(\.name) + knownNames)
        let extra = nearby
            .filter { n in
                let stem = advertisedStem(n.name)
                return !exact.contains { $0.model == n.model && $0.name.hasPrefix(stem) }
            }
            .map { untruncated($0, knownNames: names) }
        return exact + extra
    }

    /// The advertisement keeps at most `advertisedNameBytes` bytes, so `parse` marks a name that
    /// long with "…". A name that is exactly that long and equals a known exact device name was
    /// not cut: drop the marker.
    public static func untruncated(_ device: DeviceBattery, knownNames: Set<String>) -> DeviceBattery {
        guard device.name.hasSuffix("…") else { return device }
        let raw = String(device.name.dropLast())
        guard raw.utf8.count == advertisedNameBytes, knownNames.contains(raw) else { return device }
        var d = device
        d.name = raw
        return d
    }
}
