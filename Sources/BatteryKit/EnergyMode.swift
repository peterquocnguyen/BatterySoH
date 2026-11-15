import Foundation

// SPEC F8 — Energy Mode (Automatic / Low Power / High Power), read and written through
// macOS's own `pmset`. Parsing is pure so it is tested with literal `pmset` text.

/// macOS Energy Mode. Raw values are `pmset powermode` values.
public enum EnergyMode: Int, CaseIterable, Codable, Sendable, Identifiable {
    case automatic = 0
    case lowPower = 1
    case highPower = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .lowPower: return "Low Power"
        case .highPower: return "High Power"
        }
    }
}

/// A power source as `pmset` names its settings sections.
public enum PowerSourceKind: String, CaseIterable, Codable, Sendable {
    case battery
    case ac

    /// Section header in `pmset -g custom` ("Battery Power:") and `pmset -g cap`
    /// ("Capabilities for AC Power:").
    public var pmsetSectionName: String {
        switch self {
        case .battery: return "Battery Power"
        case .ac: return "AC Power"
        }
    }

    /// `pmset` flag that scopes a setting to this source.
    public var pmsetFlag: String {
        switch self {
        case .battery: return "-b"
        case .ac: return "-c"
        }
    }

    public var title: String {
        switch self {
        case .battery: return "Battery"
        case .ac: return "Power adapter"
        }
    }
}

/// Energy Mode per power source plus which modes each source supports.
public struct EnergyModeStatus: Equatable, Sendable {
    public var modes: [PowerSourceKind: EnergyMode]
    /// Only sources `pmset -g cap` described (it lists the current source only).
    public var capabilities: [PowerSourceKind: Set<EnergyMode>]

    public init(modes: [PowerSourceKind: EnergyMode], capabilities: [PowerSourceKind: Set<EnergyMode>] = [:]) {
        self.modes = modes
        self.capabilities = capabilities
    }

    /// Modes to offer for `source`, in display order. Without capability data for that source,
    /// assume Automatic + Low Power (every Mac with `powermode` has those).
    public func supportedModes(for source: PowerSourceKind) -> [EnergyMode] {
        let caps = capabilities[source] ?? [.automatic, .lowPower]
        return EnergyMode.allCases.filter { caps.contains($0) }
    }
}

public enum EnergyModeParser {
    /// `pmset -g custom` → mode per source. Reads ` powermode N`; on older systems without
    /// `powermode`, falls back to ` lowpowermode 1` / ` highpowermode 1`.
    public static func parseCustom(_ text: String) -> [PowerSourceKind: EnergyMode] {
        var result: [PowerSourceKind: EnergyMode] = [:]
        var legacy: [PowerSourceKind: EnergyMode] = [:]
        for (source, lines) in sections(text, headerFor: { $0.pmsetSectionName + ":" }) {
            for line in lines {
                // Keys we want are single tokens; "Sleep On Power Button 1" has more parts.
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count == 2, let value = Int(parts[1]) else { continue }
                switch parts[0] {
                case "powermode":
                    if let mode = EnergyMode(rawValue: value) { result[source] = mode }
                case "lowpowermode" where value == 1:
                    legacy[source] = .lowPower
                case "highpowermode" where value == 1:
                    legacy[source] = .highPower
                case "lowpowermode", "highpowermode":
                    if legacy[source] == nil { legacy[source] = .automatic }
                default:
                    break
                }
            }
        }
        return result.merging(legacy) { current, _ in current }
    }

    /// `pmset -g cap` → supported modes per source. Automatic is always supported; Low Power
    /// needs `lowpowermode`, High Power needs `highpowermode`.
    public static func parseCapabilities(_ text: String) -> [PowerSourceKind: Set<EnergyMode>] {
        var result: [PowerSourceKind: Set<EnergyMode>] = [:]
        for (source, lines) in sections(text, headerFor: { "Capabilities for \($0.pmsetSectionName):" }) {
            let keys = Set(lines.map { $0.trimmingCharacters(in: .whitespaces) })
            var modes: Set<EnergyMode> = [.automatic]
            if keys.contains("lowpowermode") { modes.insert(.lowPower) }
            if keys.contains("highpowermode") { modes.insert(.highPower) }
            result[source] = modes
        }
        return result
    }

    /// Splits `pmset` output into indented lines per known section header. Lines under
    /// unknown headers (e.g. "UPS Power:") are dropped.
    static func sections(_ text: String,
                         headerFor: (PowerSourceKind) -> String) -> [(PowerSourceKind, [String])] {
        var out: [(PowerSourceKind, [String])] = []
        var current: PowerSourceKind?
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(raw)
            if let first = line.first, !first.isWhitespace {
                let header = line.trimmingCharacters(in: .whitespaces)
                current = PowerSourceKind.allCases.first { headerFor($0) == header }
                if let current { out.append((current, [])) }
                continue
            }
            guard current != nil, !out.isEmpty else { continue }
            out[out.count - 1].1.append(line)
        }
        return out
    }
}

/// Typed failure of an Energy Mode change.
public enum EnergyModeError: Error, Equatable, Sendable {
    /// The user dismissed the administrator password prompt.
    case cancelledByUser
    /// The prompt or `pmset` failed; message is for display.
    case failed(String)
}

/// Runs `/usr/bin/pmset` (no shell) to read, and asks for an administrator password to write.
public enum EnergyModeControl {
    public static let pmsetPath = "/usr/bin/pmset"

    /// Current modes and capabilities. Two short `pmset` runs; nil if `pmset` is missing or
    /// prints no `powermode` (Macs without Energy Mode).
    public static func read(includeCapabilities: Bool = true) -> EnergyModeStatus? {
        guard let custom = run(["-g", "custom"]) else { return nil }
        let modes = EnergyModeParser.parseCustom(custom)
        guard !modes.isEmpty else { return nil }
        let caps = includeCapabilities ? run(["-g", "cap"]).map(EnergyModeParser.parseCapabilities) ?? [:] : [:]
        return EnergyModeStatus(modes: modes, capabilities: caps)
    }

    /// Shell command for a change. Built only from enum values, never from outside strings,
    /// because it runs as root.
    public static func command(setting mode: EnergyMode, for source: PowerSourceKind) -> String {
        "\(pmsetPath) \(source.pmsetFlag) powermode \(mode.rawValue)"
    }

    /// AppleScript that runs `command(setting:for:)` behind the system admin prompt.
    public static func appleScriptSource(setting mode: EnergyMode, for source: PowerSourceKind) -> String {
        "do shell script \"\(command(setting: mode, for: source))\" with administrator privileges"
    }

    /// Changes the mode for `source`. Uses the password-free sudo rule when it is installed
    /// (`PasswordFreeEnergyMode`), otherwise shows the macOS administrator password prompt and
    /// blocks until it is answered. `NSAppleScript` is not thread-safe: call on the main thread.
    public static func set(_ mode: EnergyMode, for source: PowerSourceKind) throws {
        if PasswordFreeEnergyMode.isInstalled() {
            let args = ["-n", pmsetPath, source.pmsetFlag, "powermode", String(mode.rawValue)]
            if run(args, executable: PasswordFreeEnergyMode.sudoPath) != nil { return }
            // Rule present but sudo refused (e.g. edited by hand): fall back to the prompt.
        }
        try runAsAdmin(command(setting: mode, for: source))
    }

    /// Runs a fixed shell command as root behind the system administrator prompt.
    static func runAsAdmin(_ shellCommand: String) throws {
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
            throw EnergyModeError.failed("Could not prepare the authorization request.")
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }
        let number = errorInfo[NSAppleScript.errorNumber] as? Int
        if number == -128 { throw EnergyModeError.cancelledByUser } // userCanceledErr
        let message = errorInfo[NSAppleScript.errorMessage] as? String
        throw EnergyModeError.failed(message ?? "Command failed (error \(number ?? 0)).")
    }

    /// Runs a tool with fixed arguments (no shell) and returns stdout, or nil on failure.
    static func run(_ arguments: [String], executable: String = pmsetPath) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
