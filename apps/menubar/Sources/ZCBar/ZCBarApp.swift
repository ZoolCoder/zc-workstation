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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await store.start() }
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
