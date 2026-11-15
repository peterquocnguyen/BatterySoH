import BatteryKit
import SwiftUI

// PLACEHOLDER — owned by the popover work (SPEC F1–F3).

struct MenuBarLabel: View {
    @Environment(BatteryModel.self) private var model
    var body: some View {
        Text(model.snapshot.map { "\($0.chargePercent)%" } ?? "—")
    }
}

struct PopoverView: View {
    @Environment(BatteryModel.self) private var model
    var body: some View {
        VStack(alignment: .leading) {
            Text(model.snapshot?.statusTitle ?? "No battery")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .onAppear { model.surfaceAppeared() }
        .onDisappear { model.surfaceDisappeared() }
    }
}

enum PopoverRenderEntries {
    @MainActor
    static func all() -> [RenderEntry] {
        BatterySnapshot.allSamples.map { sample in
            RenderEntry("popover-\(sample.name)") {
                PopoverView().environment(BatteryModel(previewSnapshot: sample.snapshot, history: []))
            }
        }
    }
}
