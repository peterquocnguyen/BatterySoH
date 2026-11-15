import BatteryKit
import SwiftUI

@main
struct BatteryBuddyApp: App {
    @State private var model: BatteryModel

    init() {
        RenderHarness.runIfRequested()
        _model = State(initialValue: BatteryModel())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Battery Buddy", id: WindowID.main) {
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
        }
    }
}

enum WindowID {
    static let main = "main"
}
