import BatteryKit
import SwiftUI

// PLACEHOLDER — owned by the window work (SPEC F4–F6).

struct MainWindowView: View {
    var body: some View { Text("Battery Buddy").padding() }
}

struct SettingsView: View {
    var body: some View { Text("Settings").padding() }
}

enum WindowRenderEntries {
    @MainActor
    static func all() -> [RenderEntry] {
        let model = BatteryModel(previewSnapshot: .sampleCharging, history: HistorySample.sampleSeries())
        return [RenderEntry("window") { MainWindowView().environment(model) }]
    }
}
