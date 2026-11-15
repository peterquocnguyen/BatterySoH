import Foundation

/// Optional one-time setup that lets the current user change Energy Mode without typing an
/// administrator password every time.
///
/// It installs `/etc/sudoers.d/batterysoh`, which allows exactly six commands —
/// `/usr/bin/pmset -b|-c powermode 0|1|2` — for this user, without a password. Nothing else
/// gains root. Installing and removing it each ask for the password once. The file is checked
/// with `visudo -c` before it is put in place, so a bad file can never lock out `sudo`.
public enum PasswordFreeEnergyMode {
    public static let sudoersPath = "/etc/sudoers.d/batterysoh"
    /// Where the app installed the rule before it was renamed from Battery Buddy. Removed on
    /// install and uninstall; `isInstalled()` (sudo -l) honours either file meanwhile.
    public static let legacySudoersPath = "/etc/sudoers.d/battery-buddy"
    static let sudoPath = "/usr/bin/sudo"

    /// The exact commands the rule allows.
    public static var allowedCommands: [String] {
        PowerSourceKind.allCases.flatMap { source in
            EnergyMode.allCases.map { EnergyModeControl.command(setting: $0, for: source) }
        }
    }

    /// Short macOS user names only: letters, digits, `.`, `_`, `-`. Anything else is refused
    /// rather than escaped, because the name goes into a sudoers file.
    public static func isValidUserName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64
            && name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
            && name.first != "-"
    }

    public static func sudoersContent(user: String) -> String {
        """
        # Installed by BatterySoH: lets \(user) change Energy Mode without a password.
        # Allows only these pmset commands. Remove in BatterySoH Settings, or with:
        #   sudo rm \(sudoersPath)
        \(user) ALL=(root) NOPASSWD: \(allowedCommands.joined(separator: ", "))

        """
    }

    /// True when `sudo` would run the pmset command without asking for a password.
    /// Uses `sudo -n -l <command>`, which never prompts.
    public static func isInstalled() -> Bool {
        let probe = EnergyModeControl.command(setting: .automatic, for: .ac).split(separator: " ").map(String.init)
        return EnergyModeControl.run(["-n", "-l"] + probe, executable: sudoPath) != nil
    }

    /// Writes the rule after one administrator prompt.
    public static func install(user: String = NSUserName()) throws {
        guard isValidUserName(user) else {
            throw EnergyModeError.failed("Unsupported user name for a sudo rule: \(user)")
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("batterysoh-sudoers-\(UUID().uuidString)")
        try sudoersContent(user: user).write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        let src = shellQuoted(temp.path)
        // Validate first; only then install with root ownership and 0440, as sudo requires.
        try EnergyModeControl.runAsAdmin(
            "/usr/sbin/visudo -cf \(src) && /usr/bin/install -m 0440 -o root -g wheel \(src) \(sudoersPath)"
            + " && /bin/rm -f \(legacySudoersPath)")
    }

    /// Removes the rule after one administrator prompt.
    public static func uninstall() throws {
        try EnergyModeControl.runAsAdmin("/bin/rm -f \(sudoersPath) \(legacySudoersPath)")
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
