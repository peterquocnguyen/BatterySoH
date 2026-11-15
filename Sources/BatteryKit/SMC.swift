import Foundation
import IOKit

/// Minimal read-only client for the `AppleSMC` user client.
/// Used only for battery temperature when the registry does not report it.
public final class SMC {
    private var connection: io_connect_t = 0

    // Matches the kernel's SMCParamStruct layout (80 bytes).
    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        // Swift lays the next field out after `size` (9), C after `stride` (12): pad explicitly.
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    static var paramStructSize: Int { MemoryLayout<ParamStruct>.size }

    private struct ParamStruct {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var pLimitData: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) =
                (
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                )
    }

    private static let kernelIndex: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadKeyInfo: UInt8 = 9

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Reads a numeric SMC key ("TB0T" etc.). Supports `flt `, `sp78`, `ui8 `, `ui16`.
    public func readDouble(_ key: String) -> Double? {
        guard let code = Self.fourCC(key) else { return nil }

        var input = ParamStruct()
        input.key = code
        input.data8 = Self.cmdReadKeyInfo
        guard let info = call(&input) else { return nil }

        var read = ParamStruct()
        read.key = code
        read.keyInfo.dataSize = info.keyInfo.dataSize
        read.data8 = Self.cmdReadBytes
        guard let out = call(&read) else { return nil }

        let size = Int(info.keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(size)) }
        guard bytes.count == size else { return nil }

        switch Self.string(fromFourCC: info.keyInfo.dataType) {
        case "flt " where size == 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78" where size == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8 " where size == 1:
            return Double(bytes[0])
        case "ui16" where size == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            return nil
        }
    }

    /// Average of the battery temperature sensors that report a plausible value.
    public func batteryTemperatureC() -> Double? {
        let values = ["TB0T", "TB1T", "TB2T"].compactMap(readDouble).filter { $0 > 5 && $0 < 90 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func call(_ input: inout ParamStruct) -> ParamStruct? {
        var output = ParamStruct()
        var outSize = MemoryLayout<ParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection, Self.kernelIndex,
            &input, MemoryLayout<ParamStruct>.stride,
            &output, &outSize)
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    static func fourCC(_ s: String) -> UInt32? {
        let scalars = Array(s.utf8)
        guard scalars.count == 4 else { return nil }
        return scalars.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(fromFourCC v: UInt32) -> String {
        let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }
}
