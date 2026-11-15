import AppKit
import BatteryKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// F4/F5/F9 — the main window: a tab switcher over "This Mac", "History" and "About".
/// Tab contents are custom-drawn views; only this outer layer adds the ScrollView.
struct MainWindowView: View {
    @Environment(BatteryModel.self) private var model
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnit: Fmt.TemperatureUnit = .celsius
    @AppStorage(WindowStorageKey.selectedTab) private var tab: WindowTab = .thisMac
    @AppStorage(WindowStorageKey.detailsExpanded) private var detailsExpanded = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var exportMessage: String?

    var body: some View {
        layout
            .frame(width: WindowLayout.width)
            .frame(minHeight: 480, idealHeight: WindowLayout.height, maxHeight: 900)
            .debugWindowDump("main window")
            .onAppear { model.surfaceAppeared() }
        .onDisappear { model.surfaceDisappeared() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    @ViewBuilder
    private var layout: some View {
        if #available(macOS 26, *) {
            // Native Tahoe layout: the switcher is a segmented control in the window toolbar, so
            // the system places it in the title bar, gives it Liquid Glass, and fades content that
            // scrolls under the toolbar (scroll edge effect) instead of overlapping it.
            scrollContent
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Section", selection: $tab) {
                            ForEach(WindowTab.allCases) { tab in
                                Text(tab.title).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .containerBackground(.thinMaterial, for: .window)
        } else {
            VStack(spacing: 0) {
                WindowTabBar(selection: $tab)
                WindowHairline()
                scrollContent
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var scrollContent: some View {
        ScrollView {
            switch tab {
            case .thisMac:
                WindowThisMacContent(mac: model.mac, snapshot: model.snapshot,
                                     temperatureUnit: temperatureUnit, lowPowerMode: lowPowerMode,
                                     detailsExpanded: $detailsExpanded)
            case .history:
                HistoryContent(history: model.history, deviceTitle: "This Mac (\(model.mac.name))",
                               onExport: model.history.isEmpty ? nil : exportCSV,
                               exportMessage: exportMessage)
            case .about:
                AboutContent(info: .current(mac: model.mac)) {
                    AboutDiagnostics.report(info: .current(mac: model.mac), snapshot: model.snapshot,
                                            lowPowerMode: lowPowerMode)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export Battery History"
        panel.nameFieldStringValue = "Battery Buddy History.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let csv = model.exportCSV()
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                exportMessage = "Saved \(url.lastPathComponent)"
            } catch {
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }
}

enum WindowLayout {
    static let width: CGFloat = 420
    static let height: CGFloat = 640
}

private enum WindowStorageKey {
    static let selectedTab = "window.selectedTab"
    static let detailsExpanded = "window.thisMac.detailsExpanded"
}

enum WindowTab: String, CaseIterable, Identifiable {
    case thisMac, history, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMac: return "This Mac"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .thisMac: return "laptopcomputer"
        case .history: return "chart.xyaxis.line"
        case .about: return "info.circle"
        }
    }
}

/// This Mac / History / About switcher. macOS 26+: a compact glass capsule with segments (like a
/// Tahoe segmented control). macOS 14–25: the toolbar-style icon-over-label tabs.
/// Custom-drawn either way so `--render` can capture it.
struct WindowTabBar: View {
    @Binding var selection: WindowTab
    @Environment(\.renderHarness) private var renderHarness

    var body: some View {
        if LiquidGlass.isSupported {
            HStack(spacing: 2) {
                ForEach(WindowTab.allCases) { tab in
                    WindowSegmentButton(tab: tab, isSelected: tab == selection) { selection = tab }
                }
            }
            .padding(3)
            .modifier(WindowGlassCapsule(live: !renderHarness))
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 4)
        } else {
            HStack(spacing: 6) {
                ForEach(WindowTab.allCases) { tab in
                    WindowTabButton(tab: tab, isSelected: tab == selection) { selection = tab }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

/// Glass capsule behind the segments; a flat translucent capsule where glass can't draw.
private struct WindowGlassCapsule: ViewModifier {
    var live: Bool

    func body(content: Content) -> some View {
        if live, #available(macOS 26, *) {
            GlassEffectContainer {
                content.glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            content
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}

/// One segment of the glass switcher: icon + title, the selected one raised.
private struct WindowSegmentButton: View {
    let tab: WindowTab
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(tab.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(selectionFill)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var selectionFill: some View {
        if isSelected {
            Capsule()
                .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.92))
                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.10), radius: 1.5, y: 0.5)
        } else if hovering {
            Capsule().fill(Color.primary.opacity(0.06))
        }
    }
}

/// Toolbar-style icon-over-label tab (macOS 14–25).
private struct WindowTabButton: View {
    let tab: WindowTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 18, weight: .regular))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: 84, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.07 : (hovering ? 0.04 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Render entries

enum WindowRenderEntries {
    @MainActor
    static func all() -> [RenderEntry] {
        let mac = MacInfo(name: "MacBook Pro", detail: "14-inch, Nov 2024", chip: "Apple M4 Pro", identifier: "Mac16,8")
        var onBattery = BatterySnapshot.sampleOnBattery
        onBattery.manufactureDate = Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: 2024, month: 10, day: 17))
        let aboutInfo = AboutInfo(version: AboutInfo.fallbackVersion, build: AboutInfo.fallbackBuild,
                                  copyright: AboutInfo.fallbackCopyright, osVersion: "macOS 27.2 (27C61)",
                                  mac: mac, icon: AboutInfo.appIcon())
        let end = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 15)) ?? Date()

        return [
            RenderEntry("window-thismac-charging") {
                frame(.thisMac) {
                    WindowThisMacContent(mac: mac, snapshot: .sampleCharging, temperatureUnit: .celsius,
                                         lowPowerMode: false, detailsExpanded: .constant(true))
                }
            },
            RenderEntry("window-thismac-onbattery") {
                frame(.thisMac) {
                    WindowThisMacContent(mac: mac, snapshot: onBattery, temperatureUnit: .fahrenheit,
                                         lowPowerMode: true, detailsExpanded: .constant(false))
                }
            },
            RenderEntry("window-thismac-draining") {
                frame(.thisMac) {
                    WindowThisMacContent(mac: mac, snapshot: .sampleDraining, temperatureUnit: .celsius,
                                         lowPowerMode: false, detailsExpanded: .constant(true))
                }
            },
            RenderEntry("window-thismac-just-unplugged") {
                frame(.thisMac) {
                    WindowThisMacContent(mac: mac, snapshot: .sampleJustUnplugged, temperatureUnit: .celsius,
                                         lowPowerMode: false, detailsExpanded: .constant(false))
                }
            },
            RenderEntry("window-thismac-nobattery") {
                frame(.thisMac) {
                    WindowThisMacContent(mac: MacInfo(name: "Mac mini", detail: "2024", chip: "Apple M4",
                                                      identifier: "Mac16,10"),
                                         snapshot: nil, temperatureUnit: .celsius,
                                         lowPowerMode: false, detailsExpanded: .constant(false))
                }
            },
            RenderEntry("window-history") {
                frame(.history) {
                    HistoryContent(history: HistorySample.sampleSeries(endingAt: end),
                                   deviceTitle: "This Mac (MacBook Pro)", onExport: {})
                }
            },
            RenderEntry("window-history-empty") {
                frame(.history) {
                    HistoryContent(history: [], deviceTitle: "This Mac (MacBook Pro)")
                }
            },
            RenderEntry("window-about") {
                frame(.about) {
                    AboutContent(info: aboutInfo, diagnostics: { "" })
                }
            },
            RenderEntry("window-about-copied") {
                frame(.about) {
                    AboutContent(info: aboutInfo, diagnostics: { "" }, showsCopied: true)
                }
            },
            RenderEntry("settings") {
                SettingsView()
                    .environment(BatteryModel(previewSnapshot: .sampleCharging, history: []))
                    .background(Color(nsColor: .windowBackgroundColor))
            },
        ]
    }

    /// Tab bar + content at window width, without the ScrollView (which can't render headlessly).
    @MainActor
    private static func frame<Content: View>(_ tab: WindowTab, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            WindowTabBar(selection: .constant(tab))
            if !LiquidGlass.isSupported { WindowHairline() }
            content()
            Spacer(minLength: 0)
        }
        .frame(width: WindowLayout.width)
        // Inside the entry so it resolves with the entry's colour scheme.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
