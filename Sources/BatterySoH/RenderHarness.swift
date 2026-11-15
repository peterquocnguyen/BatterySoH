import AppKit
import BatteryKit
import SwiftUI

/// Headless visual check: `BatterySoH --render <dir>` renders every `RenderEntry`
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
        var failures = 0
        for entry in entries {
            for (suffix, scheme, appearance) in [
                ("light", ColorScheme.light, NSAppearance.Name.aqua),
                ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
            ] {
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    // Background inside the colour-scheme override so it resolves dark too.
                    let content = entry.view
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.renderHarness, true)
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    let url = dir.appendingPathComponent("\(entry.name)-\(suffix).png")
                    guard let cg = renderer.cgImage,
                        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
                        (try? png.write(to: url)) != nil
                    else {
                        FileHandle.standardError.write(Data("render failed: \(entry.name)-\(suffix)\n".utf8))
                        failures += 1
                        return
                    }
                    print(url.path)
                }
            }
        }
        // Non-zero exit so CI (scripts/ci/render-smoke.sh) fails when a view can't draw.
        exit(failures == 0 ? 0 : 1)
    }
}
