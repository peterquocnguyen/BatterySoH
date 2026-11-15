import AppKit
import BatteryKit
import SwiftUI

/// Headless visual check: `BatteryBuddy --render <dir>` renders every `RenderEntry`
/// in light and dark appearance to PNGs (2x) and exits. No menu bar item, no window.
///
/// ImageRenderer cannot draw AppKit-backed controls (Table, List, ScrollView, Toggle,
/// Picker…) — they come out as placeholders. Keep the content views custom-drawn and
/// wrap them in scroll views / controls only at the outer layer.
struct RenderEntry {
    let name: String
    let view: AnyView

    init<V: View>(_ name: String, @ViewBuilder _ view: () -> V) {
        self.name = name
        self.view = AnyView(view())
    }
}

@MainActor
enum RenderHarness {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let entries = PopoverRenderEntries.all() + WindowRenderEntries.all()
        for entry in entries {
            for (suffix, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                                 ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    // Background inside the colour-scheme override so it resolves dark too.
                    let content = entry.view
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.renderHarness, true)
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    guard let cg = renderer.cgImage else {
                        print("render failed: \(entry.name)")
                        return
                    }
                    let rep = NSBitmapImageRep(cgImage: cg)
                    let url = dir.appendingPathComponent("\(entry.name)-\(suffix).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    print(url.path)
                }
            }
        }
        exit(0)
    }
}
