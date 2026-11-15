import AppKit
import BatteryKit
import SwiftUI
import UniformTypeIdentifiers

/// F4/F5/F10 — the main window, device first: a sidebar with one row per device (This Mac,
/// iPhone / iPad, accessories) and that device's page as the detail.
/// Pages are custom-drawn views; only this outer layer adds the List and the ScrollView.
struct MainWindowView: View {
    @Environment(BatteryModel.self) private var model
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnit: Fmt.TemperatureUnit = .celsius
    /// `WindowSidebarItem.id` of the selected row; may name a device that isn't around right now.
    @AppStorage(WindowStorageKey.selection) private var storedSelection = WindowSidebarItem.thisMacID
    @AppStorage(WindowStorageKey.detailsExpanded) private var detailsExpanded = false
    @AppStorage(WindowStorageKey.historyTableExpanded) private var historyTableExpanded = false
    @State private var exportMessage: String?

    var body: some View {
        NavigationSplitView {
            WindowSidebar(sections: sections, selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: WindowLayout.sidebarMinWidth,
                                                ideal: WindowLayout.sidebarWidth,
                                                max: WindowLayout.sidebarMaxWidth)
        } detail: {
            ScrollView { detail }
                .scrollBounceBehavior(.basedOnSize)
                .navigationSplitViewColumnWidth(min: WindowLayout.detailMinWidth, ideal: WindowLayout.detailWidth)
        }
        .frame(minWidth: WindowLayout.minWidth, idealWidth: WindowLayout.idealWidth, maxWidth: WindowLayout.maxWidth,
               minHeight: WindowLayout.minHeight, idealHeight: WindowLayout.idealHeight, maxHeight: .infinity)
        .debugWindowDump("main window")
        .onAppear { model.surfaceAppeared() }
        .onDisappear { model.surfaceDisappeared() }
        .onChange(of: model.devices) { old, new in
            storedSelection = WindowSelection.afterChange(stored: storedSelection, old: old, new: new)
        }
    }

    private var sections: [WindowSidebarSection] {
        WindowSidebarSection.all(mac: model.mac, snapshot: model.snapshot, devices: model.devices)
    }

    /// The stored device when it is listed, else This Mac (the stored id is kept, so a device
    /// that shows up a little after launch is selected again).
    private var selection: String {
        WindowSelection.resolve(stored: storedSelection, available: model.devices.map(\.id))
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { selection }, set: { if let id = $0 { storedSelection = id } })
    }

    @ViewBuilder
    private var detail: some View {
        if let device = model.devices.first(where: { $0.id == selection }) {
            WindowDevicePage(device: device, temperatureUnit: temperatureUnit, onOpenFinder: Self.openFinder)
                .id(device.id)
        } else {
            WindowMacPage(mac: model.mac, snapshot: model.snapshot, temperatureUnit: temperatureUnit,
                          lowPowerMode: model.isLowPowerMode, detailsExpanded: $detailsExpanded,
                          history: model.history, condition: model.macCondition,
                          historyTableExpanded: $historyTableExpanded, onExport: exportCSV, exportMessage: exportMessage)
        }
    }

    /// Wi-Fi sync is turned on in Finder's sidebar device page.
    static func openFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export Battery History"
        panel.nameFieldStringValue = "BatterySoH History.csv"
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
    static let sidebarWidth: CGFloat = 200
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 280
    static let detailWidth: CGFloat = 460
    static let detailMinWidth: CGFloat = 420
    static let minWidth: CGFloat = sidebarMinWidth + detailMinWidth
    static let idealWidth: CGFloat = sidebarWidth + detailWidth
    static let maxWidth: CGFloat = 1000
    static let minHeight: CGFloat = 480
    static let idealHeight: CGFloat = 640
}

private enum WindowStorageKey {
    static let selection = "window.selectedDevice"
    static let detailsExpanded = "window.thisMac.detailsExpanded"
    static let historyTableExpanded = "window.thisMac.historyTableExpanded"
}

/// Which sidebar row is selected, given what is stored and what is listed.
enum WindowSelection {
    static func resolve(stored: String, available: [String]) -> String {
        available.contains(stored) ? stored : WindowSidebarItem.thisMacID
    }

    /// The selected device left the list: pick the entry that replaced it (a hotspot-only iPhone
    /// that is now read exactly has a new id but the same kind and model), else This Mac.
    /// Anything else keeps the stored id.
    static func afterChange(stored: String, old: [DeviceBattery], new: [DeviceBattery]) -> String {
        guard let gone = old.first(where: { $0.id == stored }), !new.contains(where: { $0.id == stored }) else {
            return stored
        }
        let oldIDs = Set(old.map(\.id))
        let successor = new.first { d in
            !oldIDs.contains(d.id) && d.kind == gone.kind && d.model != nil && d.model == gone.model
        }
        return successor?.id ?? WindowSidebarItem.thisMacID
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
        let end = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 15)) ?? Date()
        let history = HistorySample.sampleSeries(endingAt: end)
        let now = DeviceBattery.sampleNow
        // Live iPhone (USB, charging), the last exact reading of a sleeping one, a hotspot-only
        // one, AirPods and a mouse.
        let devices: [DeviceBattery] = [.sampleIPhone, DeviceBattery.sampleRememberedIPhone.lastKnown,
                                        .sampleNearbyIPhone, .sampleAirPods, .sampleMouse]
        let sections = WindowSidebarSection.all(mac: mac, snapshot: .sampleCharging, devices: devices)

        return [
            RenderEntry("window-sidebar") {
                sidebar(sections, selection: WindowSidebarItem.thisMacID)
            },
            RenderEntry("window-sidebar-mac-only") {
                sidebar(WindowSidebarSection.all(mac: mac, snapshot: onBattery, devices: [.sampleMouse]),
                        selection: WindowSidebarItem.thisMacID)
            },
            RenderEntry("window-split-iphone") {
                // Sidebar and page side by side, the way the window lays them out.
                HStack(spacing: 0) {
                    sidebar(sections, selection: DeviceBattery.sampleIPhone.id, height: nil)
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                    page {
                        WindowDevicePage(device: .sampleIPhone, temperatureUnit: .celsius, now: now)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            },
            RenderEntry("window-mac-charging") {
                page {
                    WindowMacPage(mac: mac, snapshot: .sampleCharging, temperatureUnit: .celsius, lowPowerMode: false,
                                  detailsExpanded: .constant(true), history: history,
                                  condition: BatteryCondition.mac(.sampleCharging, reported: .sampleGood), onExport: {})
                }
            },
            RenderEntry("window-mac-history-table") {
                page {
                    WindowHistorySection(history: history, tableExpanded: .constant(true), onExport: {})
                        .padding(20)
                }
            },
            RenderEntry("window-mac-onbattery-nohistory") {
                page {
                    WindowMacPage(mac: mac, snapshot: onBattery, temperatureUnit: .fahrenheit, lowPowerMode: true,
                                  detailsExpanded: .constant(false), history: [],
                                  condition: BatteryCondition.mac(.sampleWorn, reported: .sampleService), onExport: {})
                }
            },
            RenderEntry("window-mac-nobattery") {
                page {
                    WindowMacPage(mac: MacInfo(name: "Mac mini", detail: "2024", chip: "Apple M4", identifier: "Mac16,10"),
                                  snapshot: nil, temperatureUnit: .celsius, lowPowerMode: false,
                                  detailsExpanded: .constant(false), history: [])
                }
            },
            RenderEntry("window-iphone-live") {
                page { WindowDevicePage(device: .sampleIPhone, temperatureUnit: .celsius, now: now) }
            },
            RenderEntry("window-iphone-worn") {
                page { WindowDevicePage(device: .sampleWornIPhone, temperatureUnit: .celsius, now: now) }
            },
            RenderEntry("window-iphone-remembered") {
                page {
                    WindowDevicePage(device: DeviceBattery.sampleRememberedIPhone.lastKnown, temperatureUnit: .celsius,
                                     now: now)
                }
            },
            RenderEntry("window-iphone-hotspot") {
                page { WindowDevicePage(device: .sampleNearbyIPhone, temperatureUnit: .celsius, now: now) }
            },
            RenderEntry("window-ipad-untrusted") {
                page { WindowDevicePage(device: .sampleIPadUntrusted, temperatureUnit: .celsius, now: now) }
            },
            RenderEntry("window-accessory-airpods") {
                page { WindowDevicePage(device: .sampleAirPods, temperatureUnit: .celsius, now: now) }
            },
            RenderEntry("window-accessory-keyboard") {
                page { WindowDevicePage(device: .sampleKeyboard, temperatureUnit: .celsius, now: now) }
            },
        ] + SettingsRenderEntries.all(mac: mac)
    }

    /// The sidebar rows at sidebar width, on a slightly tinted ground like a source list.
    @MainActor
    private static func sidebar(_ sections: [WindowSidebarSection], selection: String,
                                height: CGFloat? = 420) -> some View {
        WindowSidebarRendering(sections: sections, selection: selection)
            .frame(width: WindowLayout.sidebarWidth, height: height, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.primary.opacity(0.035))
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// A detail page at its ideal width, without the ScrollView (which can't render headlessly).
    @MainActor
    private static func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .frame(width: WindowLayout.detailWidth)
        // Inside the entry so it resolves with the entry's colour scheme.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
