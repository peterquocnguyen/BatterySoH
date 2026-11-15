import Foundation

/// iPhone / iPad batteries over USB or Wi-Fi sync, through Apple's private
/// `MobileDevice.framework` (the same layer Finder uses to sync devices).
///
/// Private-API use lives only in this file. Everything is looked up at runtime with
/// `dlopen` / `dlsym`; if a symbol is missing the monitor is simply unavailable (`init` returns nil)
/// and the Devices tab shows accessories only.
///
/// Flow per attached device: connect → (if trusted) start session → read the
/// `com.apple.mobile.battery` lockdown domain → start `com.apple.mobile.diagnostics_relay`
/// → ask for the `IOPMPowerSource` IORegistry entry (capacities, cycles, temperature).
/// Untrusted devices still report name and model; the UI asks the user to tap Trust.
///
/// Threading: notifications arrive on the main run loop; all bookkeeping is main-thread only.
/// Device I/O runs on a private serial queue; results hop back to main.
public final class MobileDeviceMonitor: @unchecked Sendable {
    private let api: API
    private let onChange: ([DeviceBattery]) -> Void
    private var subscription: UnsafeMutableRawPointer?
    /// UDID → attached interfaces (a device can be on USB and Wi-Fi at once).
    private var attached: [String: [Attachment]] = [:]
    private var results: [String: DeviceBattery] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "BatteryBuddy.MobileDevice", qos: .utility)

    private struct Attachment {
        let device: UnsafeMutableRawPointer // retained AMDeviceRef
        let connection: DeviceBattery.Connection
    }

    /// `onChange` is called on the main thread with the current device list.
    /// Returns nil when MobileDevice.framework (or a needed symbol) is unavailable.
    public init?(onChange: @escaping ([DeviceBattery]) -> Void) {
        guard let api = API.load() else { return nil }
        self.api = api
        self.onChange = onChange
    }

    deinit {
        if let subscription { _ = api.unsubscribe?(subscription) }
        for list in attached.values { for a in list { Unmanaged<AnyObject>.fromOpaque(a.device).release() } }
    }

    /// Subscribe to attach / detach notifications. Call on the main thread.
    public func start() {
        guard subscription == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: API.Callback = { info, context in
            guard let info, let context else { return }
            let device = info.load(as: UnsafeMutableRawPointer?.self)
            let message = info.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)
            let monitor = Unmanaged<MobileDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            if Thread.isMainThread {
                monitor.handle(device: device, message: message)
            } else if let device {
                // Bookkeeping is main-thread only; keep the device alive across the hop.
                let held = Unmanaged<AnyObject>.fromOpaque(device).retain().toOpaque()
                DispatchQueue.main.async {
                    monitor.handle(device: held, message: message)
                    Unmanaged<AnyObject>.fromOpaque(held).release()
                }
            }
        }
        var note: UnsafeMutableRawPointer?
        if let withOptions = api.subscribeWithOptions {
            // Also report devices with "Show this iPhone when on Wi-Fi" turned on.
            let options = ["NotificationOptionSearchForPairedDevices": true] as CFDictionary
            _ = withOptions(callback, 0, 0, context, &note, options)
        } else {
            _ = api.subscribe(callback, 0, 0, context, &note)
        }
        subscription = note
    }

    /// Re-read every attached device (skips ones still being read). Call on the main thread.
    public func refresh() {
        for udid in attached.keys { query(udid) }
    }

    // MARK: - Notifications (main thread)

    private func handle(device: UnsafeMutableRawPointer?, message: UInt32) {
        guard let device else { return }
        guard let udid = api.copyIdentifier(device)?.takeRetainedValue() as String?, !udid.isEmpty else { return }
        switch message {
        case 1: // connected
            let connection: DeviceBattery.Connection = switch api.interfaceType(device) {
            case 1: .usb
            case 2: .wifi
            default: .other
            }
            let retained = Unmanaged<AnyObject>.fromOpaque(device).retain().toOpaque()
            attached[udid, default: []].append(Attachment(device: retained, connection: connection))
            query(udid)
        case 2: // disconnected
            guard var list = attached[udid] else { return }
            if let i = list.firstIndex(where: { $0.device == device }) {
                Unmanaged<AnyObject>.fromOpaque(list[i].device).release()
                list.remove(at: i)
            }
            if list.isEmpty {
                attached[udid] = nil
                results[udid] = nil
                publish()
            } else {
                attached[udid] = list
                query(udid)
            }
        default:
            break
        }
    }

    private func query(_ udid: String) {
        guard !inFlight.contains(udid),
              let best = attached[udid]?.min(by: { rank($0.connection) < rank($1.connection) }) else { return }
        inFlight.insert(udid)
        // Keep the device alive across the hop even if it detaches meanwhile.
        let device = Unmanaged<AnyObject>.fromOpaque(best.device).retain().toOpaque()
        let api = self.api
        let connection = best.connection
        queue.async { [weak self] in
            let result = Self.read(api: api, device: device, udid: udid, connection: connection)
            Unmanaged<AnyObject>.fromOpaque(device).release()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(udid)
                guard self.attached[udid] != nil else { return }
                if let result { self.results[udid] = result } // keep the last good read on a hiccup
                self.publish()
            }
        }
    }

    private func rank(_ c: DeviceBattery.Connection) -> Int { c == .usb ? 0 : 1 }

    private func publish() {
        onChange(results.values.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) })
    }

    // MARK: - Device I/O (background queue)

    private static func read(api: API, device: UnsafeMutableRawPointer, udid: String,
                             connection: DeviceBattery.Connection) -> DeviceBattery? {
        guard api.connect(device) == 0 else { return nil }
        defer { _ = api.disconnect(device) }

        func value(_ domain: String?, _ key: String?) -> Any? {
            api.copyValue(device, domain as CFString?, key as CFString?)?.takeRetainedValue()
        }
        func lockdownValues() -> [String: Any] {
            var out: [String: Any] = [:]
            for key in ["DeviceName", "DeviceClass", "ProductType", "ProductVersion"] {
                if let v = value(nil, key) { out[key] = v }
            }
            return out
        }

        let trusted = api.isPaired(device) == 1 && api.validatePairing(device) == 0
        guard trusted, api.startSession(device) == 0 else {
            // Without a session lockdown still answers a few public keys (class, model).
            let lockdown = lockdownValues()
            let name = lockdown["DeviceClass"] as? String ?? "the device"
            return MobileBatteryParser.parse(
                id: udid, lockdown: lockdown, battery: [:], registry: nil, connection: connection,
                note: "Unlock \(name) and tap Trust to see its battery.")
        }

        let lockdown = lockdownValues()
        let battery = value("com.apple.mobile.battery", nil) as? [String: Any] ?? [:]
        var service: UnsafeMutableRawPointer?
        let started = api.startService(device, "com.apple.mobile.diagnostics_relay" as CFString, nil, &service)
        _ = api.stopSession(device)

        var registry: [String: Any]?
        if started == 0, let service {
            registry = diagnosticsRegistry(api: api, service: service)
            _ = api.invalidate(service)
            Unmanaged<AnyObject>.fromOpaque(service).release()
        }
        if ProcessInfo.processInfo.environment["BB_DEBUG_MOBILE"] != nil {
            // Field names for fixture capture / debugging; values only for scalars.
            for (k, v) in (registry ?? [:]).sorted(by: { $0.key < $1.key }) {
                let shown = (v is NSNumber || v is String) ? "\(v)" : "<\(type(of: v))>"
                FileHandle.standardError.write("registry \(k) = \(shown)\n".data(using: .utf8)!)
                if let nested = v as? [String: Any] {
                    for (nk, nv) in nested.sorted(by: { $0.key < $1.key }) where nv is NSNumber {
                        FileHandle.standardError.write("registry \(k).\(nk) = \(nv)\n".data(using: .utf8)!)
                    }
                }
            }
            for (k, v) in battery.sorted(by: { $0.key < $1.key }) {
                FileHandle.standardError.write("battery \(k) = \(v)\n".data(using: .utf8)!)
            }
        }
        return MobileBatteryParser.parse(id: udid, lockdown: lockdown, battery: battery,
                                         registry: registry, connection: connection)
    }

    /// diagnostics_relay: `{Request: IORegistry, EntryClass: IOPMPowerSource}` →
    /// `{Status: Success, Diagnostics: {IORegistry: {…}}}`.
    private static func diagnosticsRegistry(api: API, service: UnsafeMutableRawPointer) -> [String: Any]? {
        let xml: Int = 100 // kCFPropertyListXMLFormat_v1_0
        let request = ["Request": "IORegistry", "EntryClass": "IOPMPowerSource"] as CFDictionary
        guard api.send(service, request, xml) == 0 else { return nil }
        var reply: Unmanaged<CFPropertyList>?
        var format: Int = 0
        guard api.receive(service, &reply, &format) == 0,
              let dict = reply?.takeRetainedValue() as? [String: Any] else { return nil }
        _ = api.send(service, ["Request": "Goodbye"] as CFDictionary, xml)
        guard (dict["Status"] as? String) == "Success" else { return nil }
        return (dict["Diagnostics"] as? [String: Any])?["IORegistry"] as? [String: Any]
    }

    // MARK: - Symbols

    struct API: @unchecked Sendable {
        typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        typealias Subscribe = @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?,
                                              UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        typealias SubscribeWithOptions = @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?,
                                                         UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                                                         CFDictionary?) -> Int32
        typealias DeviceCall = @convention(c) (UnsafeMutableRawPointer) -> Int32
        typealias CopyString = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
        typealias CopyValue = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
        typealias StartService = @convention(c) (UnsafeMutableRawPointer, CFString, CFDictionary?,
                                                 UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        typealias Send = @convention(c) (UnsafeMutableRawPointer, CFPropertyList, Int) -> Int32
        typealias Receive = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFPropertyList>?>,
                                            UnsafeMutablePointer<Int>) -> Int32

        let subscribe: Subscribe
        let subscribeWithOptions: SubscribeWithOptions?
        let unsubscribe: DeviceCall?
        let connect: DeviceCall
        let disconnect: DeviceCall
        let isPaired: DeviceCall
        let validatePairing: DeviceCall
        let startSession: DeviceCall
        let stopSession: DeviceCall
        let interfaceType: DeviceCall
        let copyIdentifier: CopyString
        let copyValue: CopyValue
        let startService: StartService
        let send: Send
        let receive: Receive
        let invalidate: DeviceCall

        static func load() -> API? {
            guard let h = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_LAZY)
            else { return nil }
            func sym<T>(_ name: String, _: T.Type) -> T? {
                dlsym(h, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let subscribe = sym("AMDeviceNotificationSubscribe", Subscribe.self),
                  let connect = sym("AMDeviceConnect", DeviceCall.self),
                  let disconnect = sym("AMDeviceDisconnect", DeviceCall.self),
                  let isPaired = sym("AMDeviceIsPaired", DeviceCall.self),
                  let validatePairing = sym("AMDeviceValidatePairing", DeviceCall.self),
                  let startSession = sym("AMDeviceStartSession", DeviceCall.self),
                  let stopSession = sym("AMDeviceStopSession", DeviceCall.self),
                  let interfaceType = sym("AMDeviceGetInterfaceType", DeviceCall.self),
                  let copyIdentifier = sym("AMDeviceCopyDeviceIdentifier", CopyString.self),
                  let copyValue = sym("AMDeviceCopyValue", CopyValue.self),
                  let startService = sym("AMDeviceSecureStartService", StartService.self),
                  let send = sym("AMDServiceConnectionSendMessage", Send.self),
                  let receive = sym("AMDServiceConnectionReceiveMessage", Receive.self),
                  let invalidate = sym("AMDServiceConnectionInvalidate", DeviceCall.self)
            else { return nil }
            return API(subscribe: subscribe,
                       subscribeWithOptions: sym("AMDeviceNotificationSubscribeWithOptions", SubscribeWithOptions.self),
                       unsubscribe: sym("AMDeviceNotificationUnsubscribe", DeviceCall.self),
                       connect: connect, disconnect: disconnect, isPaired: isPaired,
                       validatePairing: validatePairing, startSession: startSession, stopSession: stopSession,
                       interfaceType: interfaceType, copyIdentifier: copyIdentifier, copyValue: copyValue,
                       startService: startService, send: send, receive: receive, invalidate: invalidate)
        }
    }
}
