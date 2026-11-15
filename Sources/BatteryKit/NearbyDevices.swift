import Foundation
import ObjectiveC

/// iPhone / iPad charge without a cable, from the Instant Hotspot browser in Apple's private
/// `Sharing.framework` — the same source as the battery level the Wi-Fi menu shows next to a
/// Personal Hotspot. Works for devices on the same Apple Account with Bluetooth on and a
/// cellular plan that offers Personal Hotspot. Gives name (truncated by the Bluetooth
/// advertisement), model and charge %; no charging state, no health.
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
                             note: "Charge only. Connect by cable for health and cycles.")
    }

    /// Cabled reads win: drop a nearby entry when a cabled device has the same model and a
    /// name that starts with the advertised (truncated) name.
    public static func merge(cabled: [DeviceBattery], nearby: [DeviceBattery]) -> [DeviceBattery] {
        let extra = nearby.filter { n in
            let stem = n.name.hasSuffix("…") ? String(n.name.dropLast()) : n.name
            return !cabled.contains { $0.model == n.model && $0.name.hasPrefix(stem) }
        }
        return cabled + extra
    }
}
