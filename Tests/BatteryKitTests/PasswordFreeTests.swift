import Foundation
import Testing

@testable import BatteryKit

@Suite("Password-free Energy Mode")
struct PasswordFreeTests {
    @Test func allowsExactlySixPmsetCommands() {
        let cmds = PasswordFreeEnergyMode.allowedCommands
        #expect(cmds.count == 6)
        #expect(Set(cmds).count == 6)
        #expect(cmds.allSatisfy { $0.hasPrefix("/usr/bin/pmset -") && $0.contains(" powermode ") })
        #expect(cmds.contains("/usr/bin/pmset -c powermode 2"))
        #expect(cmds.contains("/usr/bin/pmset -b powermode 1"))
    }

    @Test func rejectsUnsafeUserNames() {
        #expect(PasswordFreeEnergyMode.isValidUserName("quoc.nguyenphu"))
        #expect(PasswordFreeEnergyMode.isValidUserName("peter_q-1"))
        for bad in [
            "", "-rf", "a b", "root,ALL", "x\nALL ALL=(ALL) ALL", "a=b", "%admin", String(repeating: "a", count: 65),
        ] {
            #expect(!PasswordFreeEnergyMode.isValidUserName(bad), "\(bad)")
        }
    }

    @Test func sudoersContentPassesVisudo() throws {
        let content = PasswordFreeEnergyMode.sudoersContent(user: "quoc.nguyenphu")
        #expect(content.contains("quoc.nguyenphu ALL=(root) NOPASSWD: /usr/bin/pmset -b powermode 0, "))
        #expect(content.hasSuffix("\n"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bb-sudoers-\(UUID().uuidString)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        p.arguments = ["-cf", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func shellQuoting() {
        #expect(PasswordFreeEnergyMode.shellQuoted("/tmp/a b") == "'/tmp/a b'")
        #expect(PasswordFreeEnergyMode.shellQuoted("it's") == "'it'\\''s'")
    }
}
