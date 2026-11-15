@testable import BatteryKit
import Foundation
import Testing

@Suite("Legacy migration (Battery Buddy → BatterySoH)")
struct LegacyMigrationTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("soh-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func freshDefaults() -> UserDefaults {
        let name = "soh-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func movesOldDataFolderOnce() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("BatteryBuddy")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: old.appendingPathComponent("history.json"))

        LegacyMigration.run(defaults: freshDefaults(), applicationSupport: base, legacyPreferences: { [:] })
        let moved = base.appendingPathComponent("BatterySoH/history.json")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func neverOverwritesExistingNewFolder() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["BatteryBuddy", "BatterySoH"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(!LegacyMigration.moveDataFolder(in: base))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("BatteryBuddy").path))
    }

    @Test func copiesOnlyUnsetPreferencesOnce() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let d = freshDefaults()
        d.set(5.0, forKey: "refreshInterval")
        var calls = 0
        let legacy: () -> [String: Any] = {
            calls += 1
            return ["refreshInterval": 1.0, "menuBar.showWatts": true]
        }
        LegacyMigration.run(defaults: d, applicationSupport: base, legacyPreferences: legacy)
        #expect(d.double(forKey: "refreshInterval") == 5.0) // already set: kept
        #expect(d.bool(forKey: "menuBar.showWatts"))
        LegacyMigration.run(defaults: d, applicationSupport: base, legacyPreferences: legacy)
        #expect(calls == 1)
    }

    @Test func sudoRuleNamesAreValidSudoersFileNames() {
        // sudo ignores files in sudoers.d whose names contain '.' or end in '~'.
        for path in [PasswordFreeEnergyMode.sudoersPath, PasswordFreeEnergyMode.legacySudoersPath] {
            let name = (path as NSString).lastPathComponent
            #expect(!name.contains(".") && !name.hasSuffix("~"))
        }
    }
}
