import BatteryKit
import SwiftUI

@main
struct BatterySoHApp: App {
    @State private var model: BatteryModel
    @State private var updates: UpdateModel

    init() {
        RenderHarness.runIfRequested()
        // Before BatteryModel loads history / remembered readings from Application Support.
        LegacyMigration.run()
        _model = State(initialValue: BatteryModel())
        _updates = State(initialValue: UpdateModel())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .environment(updates)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("BatterySoH", id: WindowID.main) {
            MainWindowView()
                .environment(model)
        }
        // Resizable between the content's min and max size; SwiftUI remembers the frame.
        .windowResizability(.contentSize)
        .defaultSize(width: WindowLayout.idealWidth, height: WindowLayout.idealHeight)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(model)
                .environment(updates)
        }
    }
}

enum WindowID {
    static let main = "main"
}
