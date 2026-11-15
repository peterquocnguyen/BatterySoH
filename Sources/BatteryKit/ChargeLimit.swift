import Foundation
import ObjectiveC

// SPEC F8 — Charge limit status and "Charge to Full Now".
//
// PRIVATE API: this file is the only place BatterySoH touches PowerUI.framework
// (`PowerUISmartChargeClient`, the client behind the native Battery menu's charge-limit items).
// Everything is looked up at runtime and every call checks that the class, the selector and its
// exact ObjC type encoding are present before calling, so a macOS change makes these features
// disappear (nil / `.unavailable`) instead of crashing. Delete this file to drop the feature.
//
// Allowed calls, by design: reads (`isMCLCurrentlyEnabled:`, `getMCLLimitWithError:`,
// `isOBCEngaged:isMaxChargeLimited:chargingOverrideAllowed:withError:`) and the native
// menu's one-shot override `temporarilyDisableMCL:`. Never `setMCLLimit:error:`,
// `enableMCL:` or `disableMCL:` — BatterySoH does not change the user's limit setting.

/// Manual Charge Limit (MCL) state as macOS reports it.
public struct ChargeLimitStatus: Equatable, Codable, Sendable {
    /// The user turned on a charge limit in System Settings › Battery.
    public var isEnabled: Bool
    /// The limit, e.g. 80. Nil when it could not be read.
    public var limitPercent: Int?
    /// macOS is holding the charge (optimized / limited charging engaged).
    public var isHoldingCharge: Bool
    /// macOS allows "Charge to Full Now" right now.
    public var overrideAllowed: Bool

    public init(isEnabled: Bool, limitPercent: Int?, isHoldingCharge: Bool, overrideAllowed: Bool) {
        self.isEnabled = isEnabled
        self.limitPercent = limitPercent
        self.isHoldingCharge = isHoldingCharge
        self.overrideAllowed = overrideAllowed
    }

    /// Limit percent to show when the limit is what holds the charge, else nil.
    public var heldAtPercent: Int? {
        guard isEnabled, isHoldingCharge else { return nil }
        return limitPercent
    }
}

public enum ChargeLimitError: Error, Equatable, Sendable {
    /// PowerUI or the needed method is missing on this macOS.
    case unavailable
    case failed(String)
}

/// Thin runtime wrapper over `PowerUISmartChargeClient`. Thread-safe; calls block briefly
/// (they talk to powerd), so prefer calling off the main thread.
public final class ChargeLimit: @unchecked Sendable {
    public static let shared = ChargeLimit()

    static let frameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
    static let className = "PowerUISmartChargeClient"
    static let clientName = "com.batterysoh.app"

    /// Selector → exact type encoding we cast the IMP to.
    enum Signature {
        static let isEnabled = ("isMCLCurrentlyEnabled:", "Q24@0:8^@16")
        static let limit = ("getMCLLimitWithError:", "C24@0:8^@16")
        static let obc = (
            "isOBCEngaged:isMaxChargeLimited:chargingOverrideAllowed:withError:", "B48@0:8^B16^B24^B32^@40"
        )
        static let disableTemporarily = ("temporarilyDisableMCL:", "B24@0:8^@16")
    }

    private typealias ErrorOut = AutoreleasingUnsafeMutablePointer<NSError?>?
    private typealias UInt64ErrorFn = @convention(c) (AnyObject, Selector, ErrorOut) -> UInt64
    private typealias UInt8ErrorFn = @convention(c) (AnyObject, Selector, ErrorOut) -> UInt8
    private typealias BoolErrorFn = @convention(c) (AnyObject, Selector, ErrorOut) -> Bool
    private typealias OBCFn =
        @convention(c) (
            AnyObject, Selector, UnsafeMutablePointer<Bool>?,
            UnsafeMutablePointer<Bool>?, UnsafeMutablePointer<Bool>?,
            ErrorOut
        ) -> Bool

    private let lock = NSLock()
    private var didLoad = false
    private var client: NSObject?

    public init() {}

    /// Current limit state, or nil when PowerUI or the read methods are unavailable.
    public func status() -> ChargeLimitStatus? {
        guard let client = loadClient() else { return nil }

        var enabled: Bool?
        if let fn: UInt64ErrorFn = method(client, Signature.isEnabled) {
            var error: NSError?
            let value = fn(client, NSSelectorFromString(Signature.isEnabled.0), &error)
            if error == nil { enabled = value != 0 }
        }

        var limit: Int?
        if let fn: UInt8ErrorFn = method(client, Signature.limit) {
            var error: NSError?
            let value = fn(client, NSSelectorFromString(Signature.limit.0), &error)
            if error == nil, (1...100).contains(value) { limit = Int(value) }
        }

        var engaged = false
        var maxLimited = false
        var overrideAllowed = false
        var obcOK = false
        if let fn: OBCFn = method(client, Signature.obc) {
            var error: NSError?
            obcOK = fn(client, NSSelectorFromString(Signature.obc.0), &engaged, &maxLimited, &overrideAllowed, &error)
        }

        guard enabled != nil || obcOK else { return nil }
        return ChargeLimitStatus(
            isEnabled: enabled ?? false, limitPercent: limit,
            isHoldingCharge: obcOK && (engaged || maxLimited),
            overrideAllowed: obcOK && overrideAllowed)
    }

    /// Same as the native Battery menu's "Charge to Full Now": lifts the limit until the
    /// battery is full, then macOS restores it by itself.
    public func chargeToFullNow() throws {
        guard let client = loadClient(),
            let fn: BoolErrorFn = method(client, Signature.disableTemporarily)
        else {
            throw ChargeLimitError.unavailable
        }
        var error: NSError?
        let ok = fn(client, NSSelectorFromString(Signature.disableTemporarily.0), &error)
        guard ok else {
            throw ChargeLimitError.failed(error?.localizedDescription ?? "macOS refused to charge to full.")
        }
    }

    // MARK: Runtime lookup

    private func loadClient() -> NSObject? {
        lock.lock()
        defer { lock.unlock() }
        if didLoad { return client }
        didLoad = true
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil,
            let cls = NSClassFromString(Self.className) as? NSObject.Type
        else { return nil }
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithClientName:")
        guard cls.responds(to: allocSel), cls.instancesRespond(to: initSel),
            // alloc returns +1 which init consumes; init returns +1 which we own.
            let allocated = cls.perform(allocSel)?.takeUnretainedValue() as? NSObject,
            let instance = allocated.perform(initSel, with: Self.clientName)?.takeRetainedValue() as? NSObject
        else { return nil }
        client = instance
        return instance
    }

    /// The method's IMP cast to `F`, only if the selector exists with exactly `signature.1`.
    private func method<F>(_ object: NSObject, _ signature: (String, String)) -> F? {
        let sel = NSSelectorFromString(signature.0)
        guard object.responds(to: sel),
            let cls = object_getClass(object),
            let method = class_getInstanceMethod(cls, sel),
            let encoding = method_getTypeEncoding(method),
            String(cString: encoding) == signature.1
        else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: F.self)
    }
}
