import Foundation
import IOKit
import IOKit.ps

/// Reads the raw `AppleSmartBattery` registry dictionary.
public enum SmartBatteryRegistry {
    public static func read() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }
}

/// IOPowerSources: macOS's own time estimates and change notifications.
public enum PowerSources {
    public struct Times: Sendable {
        public var minutesToEmpty: Int?
        public var minutesToFull: Int?
    }

    public static func internalBatteryTimes() -> Times? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            func minutes(_ key: String) -> Int? {
                guard let m = desc[key] as? Int, m > 0 else { return nil } // -1 = calculating
                return m
            }
            return Times(minutesToEmpty: minutes(kIOPSTimeToEmptyKey), minutesToFull: minutes(kIOPSTimeToFullChargeKey))
        }
        return nil
    }

    /// Calls `handler` on the main run loop whenever any power source changes
    /// (plug/unplug, percent change). Keep the returned token alive.
    public final class Observer {
        private var source: CFRunLoopSource?
        private let handler: () -> Void

        public init(_ handler: @escaping () -> Void) {
            self.handler = handler
            let context = Unmanaged.passUnretained(self).toOpaque()
            source = IOPSNotificationCreateRunLoopSource({ ctx in
                guard let ctx else { return }
                Unmanaged<Observer>.fromOpaque(ctx).takeUnretainedValue().handler()
            }, context)?.takeRetainedValue()
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        }

        deinit {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        }
    }
}

/// Static facts about this Mac.
public struct MacInfo: Codable, Equatable, Sendable {
    /// e.g. "MacBook Pro"
    public var name: String
    /// e.g. "14-inch, Nov 2024"
    public var detail: String?
    /// e.g. "Apple M4 Pro"
    public var chip: String?
    /// e.g. "Mac16,8"
    public var identifier: String

    public init(name: String, detail: String?, chip: String?, identifier: String) {
        self.name = name
        self.detail = detail
        self.chip = chip
        self.identifier = identifier
    }

    public static func current() -> MacInfo {
        let identifier = sysctlString("hw.model") ?? "Mac"
        let chip = sysctlString("machdep.cpu.brand_string")
        let (name, detail) = splitProductName(productName() ?? identifier)
        return MacInfo(name: name, detail: detail, chip: chip, identifier: identifier)
    }

    /// "MacBook Pro (14-inch, Nov 2024)" → ("MacBook Pro", "14-inch, Nov 2024")
    public static func splitProductName(_ full: String) -> (String, String?) {
        guard let open = full.firstIndex(of: "("), full.hasSuffix(")") else { return (full, nil) }
        let name = full[..<open].trimmingCharacters(in: .whitespaces)
        let detail = full[full.index(after: open)..<full.index(before: full.endIndex)]
        return (name, String(detail))
    }

    static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
        return s.isEmpty ? nil : s
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// One-call snapshot: registry + IOPS times + SMC temperature fallback.
public final class BatteryReader {
    private lazy var smc: SMC? = SMC()

    public init() {}

    public func snapshot(now: Date = Date()) -> BatterySnapshot? {
        guard let dict = SmartBatteryRegistry.read() else { return nil }
        var snap = BatteryParser.parse(dict, now: now)
        if let times = PowerSources.internalBatteryTimes() {
            snap.minutesToEmpty = times.minutesToEmpty ?? (snap.powerState == .onBattery ? snap.minutesToEmpty : nil)
            snap.minutesToFull = times.minutesToFull ?? (snap.powerState == .charging ? snap.minutesToFull : nil)
        }
        if snap.temperatureC == nil {
            snap.temperatureC = smc?.batteryTemperatureC()
        }
        return snap
    }
}
