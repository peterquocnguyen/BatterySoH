import AppKit
import SwiftUI

// Window plumbing shared by the popover panel and the main window: a tiny NSWindow
// accessor and opt-in hierarchy logging (`BB_DEBUG_WINDOWS=1`).

/// Calls `onWindow` once the hosting view is in a window (and again if it moves windows).
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Next runloop turn: the window has finished installing its content by then.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                self.onWindow?(window)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// `BB_DEBUG_WINDOWS=1 …/BatteryBuddy` prints each window's view hierarchy to stderr once.
enum DebugWindows {
    static let enabled = ProcessInfo.processInfo.environment["BB_DEBUG_WINDOWS"] != nil

    @MainActor private static var logged = Set<String>()

    @MainActor
    static func dumpOnce(_ window: NSWindow, label: String) {
        guard enabled, !logged.contains(label) else { return }
        logged.insert(label)
        dump(window, label: label)
    }

    @MainActor
    static func dump(_ window: NSWindow, label: String) {
        guard enabled else { return }
        log("=== \(label): \(type(of: window)) frame=\(window.frame) styleMask=0x\(String(window.styleMask.rawValue, radix: 16))"
            + " opaque=\(window.isOpaque) bg=\(window.backgroundColor.debugDescription)"
            + " level=\(window.level.rawValue) shadow=\(window.hasShadow)"
            + " appearance=\(window.effectiveAppearance.name.rawValue)"
            + " titlebarTransparent=\(window.titlebarAppearsTransparent)")
        if let root = window.contentView?.superview ?? window.contentView {
            dumpView(root, depth: 0, contentView: window.contentView)
        }
    }

    @MainActor
    private static func dumpView(_ view: NSView, depth: Int, contentView: NSView?) {
        guard depth < 14 else { return }
        var line = String(repeating: "  ", count: depth) + "\(type(of: view))"
        if view === contentView { line += " [contentView]" }
        line += " frame=\(view.frame)"
        if view.isHidden { line += " HIDDEN" }
        if view.alphaValue < 1 { line += " alpha=\(view.alphaValue)" }
        if let effect = view as? NSVisualEffectView {
            line += " material=\(effect.material.rawValue) blending=\(effect.blendingMode.rawValue)"
                + " state=\(effect.state.rawValue) mask=\(effect.maskImage != nil)"
        }
        if #available(macOS 26, *), let glass = view as? NSGlassEffectView {
            line += " glass(style=\(glass.style.rawValue) radius=\(glass.cornerRadius)"
                + " tint=\(glass.tintColor?.debugDescription ?? "nil"))"
        }
        if let layer = view.layer {
            line += " layer=\(type(of: layer))"
            if layer.masksToBounds { line += " masks" }
            if let filters = layer.filters, !filters.isEmpty { line += " filters=\(filters)" }
            if let comp = layer.compositingFilter { line += " comp=\(comp)" }
            if let subs = layer.sublayers, !subs.isEmpty, depth < 3 || view.frame.width > 300 {
                line += " sublayers=[" + subs.prefix(6).map { l in
                    var d = "\(type(of: l))"
                    if let f = l.filters, !f.isEmpty { d += "{filters:\(f)}" }
                    if l.cornerRadius > 0 { d += "{r=\(l.cornerRadius)}" }
                    if let bg = l.backgroundColor { d += "{bg a=\(bg.alpha)}" }
                    return d
                }.joined(separator: ",") + "]"
            }
            if layer.cornerRadius > 0 { line += " layer.radius=\(layer.cornerRadius)" }
            if let bg = layer.backgroundColor { line += " layer.bg=\(bg)" }
            if layer.mask != nil { line += " layer.mask" }
        }
        log(line)
        for sub in view.subviews { dumpView(sub, depth: depth + 1, contentView: contentView) }
    }

    static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

extension View {
    /// With `BB_DEBUG_WINDOWS` set, logs the hosting window's view hierarchy once.
    /// Adds nothing otherwise (ImageRenderer would draw an AppKit view as a placeholder).
    @ViewBuilder
    func debugWindowDump(_ label: String) -> some View {
        if DebugWindows.enabled {
            background(WindowAccessor { DebugWindows.dumpOnce($0, label: label) })
        } else {
            self
        }
    }
}

// MARK: - Liquid Glass gating

private struct RenderHarnessKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True under `--render`: ImageRenderer can't draw glass or materials, so views fall back
    /// to their opaque macOS 14–25 look there.
    var renderHarness: Bool {
        get { self[RenderHarnessKey.self] }
        set { self[RenderHarnessKey.self] = newValue }
    }
}

enum LiquidGlass {
    /// macOS 26+ runtime. The system only draws glass chrome (menu bar panel, title bar) when
    /// the binary also records a 26+ SDK in LC_BUILD_VERSION — `scripts/bundle.sh` ensures that.
    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}
