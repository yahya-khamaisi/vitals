import AppKit
import SwiftUI

/// Vitals lives entirely in the menu bar: one combined item, or one item per module.
/// Each item opens the same panel; module items open on their module's page.
@main
struct VitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = Monitor.shared
    @StateObject private var bar = MenuBarState.shared

    init() {
        CLIClient.runIfRequested()
        FanHelper.runDaemonIfRequested()
    }

    var body: some Scene {
        MenuBarExtra(isInserted: bar.binding(nil)) {
            PanelView(initialPage: .main).environmentObject(monitor)
        } label: {
            Image(nsImage: bar.images["combined"] ?? WidgetRenderer.fallback)
        }
        .menuBarExtraStyle(.window)

        extra(.cpu)
        extra(.gpu)
        extra(.memory)
        extra(.disk)
        extra(.network)
        extra(.battery)
        extra(.sensors)
        extra(.bluetooth)
        extra(.clock)
    }

    private func extra(_ m: Module) -> some Scene {
        MenuBarExtra(isInserted: bar.binding(m)) {
            PanelView(initialPage: .module(m)).environmentObject(monitor)
        } label: {
            Image(nsImage: bar.images[m.rawValue] ?? WidgetRenderer.fallback)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The rendered status-item images, updated once per sample so labels redraw once, not per property.
@MainActor
final class MenuBarState: ObservableObject {
    static let shared = MenuBarState()
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var inserted: [String: Bool] = [:]

    /// Which modules draw in the combined item, and which get their own.
    func layout(_ config: Config) -> (combined: [Module], own: [Module]) {
        let visible = config.order.filter { config.isOn($0) && config.widget($0).enabled }
        if !config.combined { return ([], visible) }
        return (visible.filter { !config.widget($0).ownItem }, visible.filter { config.widget($0).ownItem })
    }

    func refresh() {
        let monitor = Monitor.shared
        let (combined, own) = layout(monitor.config)
        var images: [String: NSImage] = [:]
        var inserted: [String: Bool] = ["combined": monitor.config.combined || own.isEmpty]
        images["combined"] = combined.isEmpty ? WidgetRenderer.fallback : WidgetRenderer.image(for: combined, monitor: monitor)
        for m in Module.allCases {
            let on = own.contains(m)
            inserted[m.rawValue] = on
            if on { images[m.rawValue] = WidgetRenderer.image(for: [m], monitor: monitor) }
        }
        self.images = images
        if inserted != self.inserted { self.inserted = inserted }
    }

    func binding(_ m: Module?) -> Binding<Bool> {
        let key = m?.rawValue ?? "combined"
        return Binding(get: { self.inserted[key] ?? (m == nil) }, set: { on in
            // macOS clears this when the person ⌘-drags the item out of the menu bar.
            // SwiftUI also writes `false` back for items that are already hidden; ignore those.
            guard !on, self.inserted[key] == true, let m, Monitor.shared.config.widget(m).enabled else { return }
            self.inserted[key] = false
            Monitor.shared.config.widgets[m]?.enabled = false
        })
    }

    /// Opens the first Vitals menu-bar panel, for the global shortcut and `vitals://open`.
    func openPanel() {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = window.contentView?.subviews.first(where: { $0 is NSStatusBarButton }) as? NSStatusBarButton
                ?? window.contentView as? NSStatusBarButton {
                button.performClick(nil)
                return
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        MainActor.assumeIsolated {
            let monitor = Monitor.shared
            let bar = MenuBarState.shared
            monitor.onSample = { bar.refresh() }
            monitor.onConfigChange = {
                bar.refresh()
                Automation.shared.updateHotKey()
            }
            monitor.start()
            bar.refresh()
            Host.resolveModelName()
            Automation.shared.start()
            #if DEBUG
            if DesignPreview.runIfRequested() { return }
            #endif
            Onboarding.presentIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Monitor.shared.stop()
            FanHelper.shared.releaseAll()
        }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string) else { return }
        MainActor.assumeIsolated { Automation.shared.handle(url: url) }
    }
}

#if DEBUG
/// `-preview <page> [light|dark]` shows a page in a borderless glass panel so it can be
/// captured for design review without opening the menu bar.
enum DesignPreview {
    @MainActor static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-preview"), i + 1 < args.count else { return false }
        let name = args[i + 1]
        if args.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let view: AnyView
        if name == "onboarding" {
            view = AnyView(OnboardingPage(done: {}).frame(width: Metrics.width).environmentObject(Monitor.shared))
        } else {
            let page = Page(name) ?? .main
            view = AnyView(PanelView(initialPage: page).environmentObject(Monitor.shared))
        }
        // Let a few samples arrive so charts have data before the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + (args.contains("now") ? 0 : 0.2)) {
            let panel = GlassPanel(rootView: view)
            panel.title = "Vitals \(name)"
            panel.hasShadow = false
            panel.showUnderMenuBar()
            previewPanel = panel
        }
        return true
    }

    @MainActor private static var previewPanel: GlassPanel?
}
#endif
