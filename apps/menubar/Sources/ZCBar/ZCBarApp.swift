import AppKit
import SwiftUI

@main
struct ZCBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: delegate.store)
        } label: {
            StatusLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private lazy var window = PanelWindow(store: store)
    private lazy var hotkey = HotKey { [weak self] in self?.window.toggle() }

    /// SwiftUI takes URL events for itself, so the handler replaces its own
    /// once launched: zcbar://panel, from SketchyBar's item, toggles the
    /// floating panel.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(open(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        store.notifier.onOpen = { [weak self] in self?.window.show() }
        store.hotkeyChanged = { [weak self] on in on ? self?.hotkey.register() : self?.hotkey.unregister() }
        if store.hotkey { hotkey.register() }
        Task { await store.start() }
    }

    @objc private func open(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue.flatMap(URL.init(string:)),
              url.host() == "panel" else { return }
        // zcbar://panel/updates opens a tab, zcbar://panel/overview/home a
        // target in it, zcbar://panel/mac/disk a tile.
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let name = parts.first, let tab = Store.Tab.allCases.first(where: { $0.rawValue.lowercased() == name }) else {
            window.toggle()
            return
        }
        store.tab = tab
        if parts.count > 1 {
            if tab == .mac {
                store.macDetail = Store.MacDetail(rawValue: parts[1])
            } else if store.expanded != parts[1] {
                store.toggle(parts[1])
            }
        }
        window.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}

/// The menu bar icon: a laptop, with a count when something needs attention.
struct StatusLabel: View {
    let store: Store

    var body: some View {
        let count = store.attention
        if store.setupProblem != nil {
            Image(systemName: "laptopcomputer.slash")
        } else if count == 0 {
            Image(systemName: "laptopcomputer")
        } else {
            HStack(spacing: 2) {
                Image(systemName: "laptopcomputer.trianglebadge.exclamationmark")
                Text("\(count)")
            }
        }
    }
}
