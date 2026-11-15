import Foundation

/// One-time move of data from the app's previous name, Battery Buddy, to BatterySoH.
///
/// - `~/Library/Application Support/BatteryBuddy` → `…/BatterySoH` (history, remembered
///   iPhone/iPad readings), only when the new folder does not exist yet.
/// - Preferences of the old bundle id `com.batterybuddy.app` are copied into the current
///   domain for keys that are not set yet. The old preferences file is left in place.
///
/// Safe to call on every launch: it does nothing once done.
public enum LegacyMigration {
    public static let legacyBundleID = "com.batterybuddy.app"
    public static let legacyFolderName = "BatteryBuddy"
    public static let folderName = "BatterySoH"
    static let doneKey = "migration.fromBatteryBuddy.done"

    public static func run(defaults: UserDefaults = .standard,
                           applicationSupport: URL = defaultApplicationSupport,
                           legacyPreferences: () -> [String: Any] = readLegacyPreferences) {
        moveDataFolder(in: applicationSupport)
        guard !defaults.bool(forKey: doneKey) else { return }
        for (key, value) in legacyPreferences() where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }

    public static var defaultApplicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Moves the old data folder when only the old one exists. Returns true when it moved.
    @discardableResult
    static func moveDataFolder(in base: URL) -> Bool {
        let fm = FileManager.default
        let old = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        let new = base.appendingPathComponent(folderName, isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        return (try? fm.moveItem(at: old, to: new)) != nil
    }

    /// Only the old app's own keys (not the global domain), via CFPreferences.
    public static func readLegacyPreferences() -> [String: Any] {
        let app = legacyBundleID as CFString
        guard let keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty,
              let values = CFPreferencesCopyMultiple(keys as CFArray, app, kCFPreferencesCurrentUser,
                                                     kCFPreferencesAnyHost) as? [String: Any]
        else { return [:] }
        // Window frames and AppKit state belong to the old app; keep only our settings.
        return values.filter { !$0.key.hasPrefix("NS") }
    }
}
