import AppKit
import ZCBarCore

/// The questions the app asks before it changes the machine.
@MainActor
enum Alerts {
    /// Lists every change in the plan; deletions get a warning of their own.
    static func confirm(plan: PlanDoc) -> Bool {
        let alert = NSAlert()
        let changes = plan.actions.filter { $0.manual != true }
        alert.messageText = changes.count == 1 ? "Make this change?" : "Make these \(changes.count) changes?"
        let lines = changes.prefix(25).map { "\($0.op)  \($0.resource)" }
        var text = lines.joined(separator: "\n")
        if changes.count > lines.count { text += "\n… and \(changes.count - lines.count) more" }
        if plan.deletes {
            alert.alertStyle = .critical
            text = "This plan deletes things.\n\n" + text
        }
        alert.informativeText = text
        alert.addButton(withTitle: plan.deletes ? "Delete and Apply" : "Apply")
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn
    }

    static func confirm(fix command: String, for title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Fix \(title)?"
        alert.informativeText = "This runs as administrator, after macOS asks for your password:\n\n\(command)"
        alert.addButton(withTitle: "Fix")
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn
    }

    static func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn
    }

    static func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        _ = run(alert)
    }

    /// A menu bar app is never frontmost; the alert must bring it forward.
    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }
}
