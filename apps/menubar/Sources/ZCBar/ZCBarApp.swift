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

    /// SwiftUI takes URL events for itself, so the handler replaces its own
    /// once launched: zcbar://panel, from SketchyBar's item, toggles the
    /// floating panel.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(open(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        Task { await store.start() }
    }

    @objc private func open(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue.flatMap(URL.init(string:))
        if url?.host() == "panel" {
            window.toggle()
        }
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
