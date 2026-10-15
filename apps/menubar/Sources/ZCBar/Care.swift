import AppKit
import Observation
import ZCBarCore

/// The Care window's state: one Smart Care scan over the whole Mac, and the
/// modules it sums up. Changes go through the Store, which asks first.
@MainActor @Observable
final class Care {
    enum Module: String, CaseIterable, Identifiable {
        case smartCare = "Smart Care", cleanup = "Cleanup", apps = "Applications", performance = "Performance"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .smartCare: "sparkles"
            case .cleanup: "trash.fill"
            case .apps: "square.grid.2x2.fill"
            case .performance: "gauge.with.dots.needle.67percent"
            }
        }
    }

    let store: Store
    var module: Module = .smartCare
    var scanning = false
    var scannedAt: Date?
    var largeFiles: [LargeFile] = []
    var scanningFiles = false
    var apps: [InstalledApp] = []
    var loadingApps = false
    var icons: [String: NSImage] = [:]
    var agents: [LaunchAgent] = []
    var background: [NSRunningApplication] = []

    /// Large Files lists files from this size up.
    nonisolated static let largeFile: Int64 = 200 * 1024 * 1024

    init(store: Store) {
        self.store = store
    }

    var monitor: Monitor { store.monitor }
    var junk: Int64 { monitor.junk.values.reduce(0, +) }
    var clutter: Int64 { largeFiles.reduce(0) { $0 + $1.size } }
    var undeclared: [InstalledApp] { apps.filter { $0.declared == nil } }
    var unused: [InstalledApp] { apps.filter { $0.unused() } }
    var startup: [LaunchAgent] { agents.filter { $0.enabled && ($0.runAtLoad || $0.keepAlive) } }

    // MARK: Scan

    /// Reads everything the cards show at once.
    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        async let junk: Void = monitor.scan()
        async let state: Void = store.refresh()
        async let files: Void = scanFiles()
        async let apps: Void = loadApps()
        async let agents: Void = loadAgents()
        _ = await (junk, state, files, apps, agents)
        scannedAt = .now
    }

    /// Smart Care's Run: cleans up, then updates, each after its question.
    func run() async {
        if junk > 0 { await store.cleanAll() }
        if !(store.snapshot?.outdated.isEmpty ?? true) { await store.updateAll() }
    }

    // MARK: Large files

    func scanFiles() async {
        scanningFiles = true
        defer { scanningFiles = false }
        let home = NSHomeDirectory()
        let args = ["-onlyin", home, LargeFiles.query(minimum: Self.largeFile)]
        guard let r = try? await ProcessRunner().run("/usr/bin/mdfind", args, env: [:]) else { return }
        let paths = r.output.split(whereSeparator: \.isNewline).map(String.init)
        largeFiles = await Task.detached { LargeFiles.files(paths: paths, home: home, minimum: Self.largeFile) }.value
    }

    func trash(_ file: LargeFile) {
        guard store.busy == nil, Alerts.confirm("Move \(file.name) to the Trash?",
                                                "\(Store.bytes(file.size)) in \(file.url.deletingLastPathComponent().path).",
                                                button: "Move to Trash") else { return }
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            largeFiles.removeAll { $0 == file }
            monitor.readDisk()
            store.message = Store.Message(text: "\(file.name) is in the Trash.", failed: false)
        } catch {
            store.message = Store.Message(text: error.localizedDescription, failed: true)
        }
    }

    // MARK: Applications

    /// Lists the apps, then fills in sizes and last use as each is read.
    func loadApps() async {
        loadingApps = true
        defer { loadingApps = false }
        var caskApps: [String: String] = [:]
        if let brew = store.program("brew"),
           let r = try? await ProcessRunner().run(brew, ["info", "--json=v2", "--installed", "--cask"], env: store.loginEnv) {
            caskApps = AppCatalog.caskApps(brewInfo: r.stdout)
        }
        let items = (try? await store.cli?.items()) ?? []
        let folder = URL(fileURLWithPath: "/Applications")
        let found = await Task.detached { AppCatalog.apps(in: folder, caskApps: caskApps, items: items) }.value
        let old = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        apps = found.map { app in
            var app = app
            app.size = old[app.id]?.size
            app.lastUsed = old[app.id]?.lastUsed
            return app
        }
        for app in apps where icons[app.id] == nil {
            icons[app.id] = NSWorkspace.shared.icon(forFile: app.url.path)
        }
        await withTaskGroup(of: (String, Int64, Date?).self) { group in
            for url in found.map(\.url) {
                group.addTask(priority: .utility) {
                    let used = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
                    return (url.path, DiskUsage.allocated(url), used)
                }
            }
            for await (id, size, used) in group {
                guard let i = apps.firstIndex(where: { $0.id == id }) else { continue }
                apps[i].size = size
                apps[i].lastUsed = used
            }
        }
    }

    /// Removes the app and what it left in the Library. A Brewfile app goes
    /// through zc-workstation remove, which drops it from the manifest too;
    /// the rest go to the Trash, where they can be put back.
    func uninstall(_ app: InstalledApp) async {
        guard store.busy == nil else { return }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL == app.url }) {
            store.message = Store.Message(text: "Quit \(app.name) first.", failed: true)
            return
        }
        let leftovers = Leftovers.paths(bundleID: app.bundleID, name: app.name, home: NSHomeDirectory())
        var how: String
        switch (app.declared, app.source) {
        case (let item?, _): how = "zc-workstation removes \(item.resource) and drops it from the Brewfile."
        case (nil, .cask(let token)): how = "Homebrew uninstalls the cask \(token)."
        default: how = "The app moves to the Trash."
        }
        if !leftovers.isEmpty {
            how += "\n\nIts files move to the Trash:\n" + leftovers.map { ($0 as NSString).abbreviatingWithTildeInPath }
                .joined(separator: "\n")
        }
        guard Alerts.confirm("Uninstall \(app.name)?", how, button: "Uninstall") else { return }
        store.busy = "Uninstalling \(app.name)"
        defer { store.busy = nil }
        var failure: String?
        switch (app.declared, app.source) {
        case (let item?, _):
            guard let cli = store.cli, let target = item.target else { return }
            let r = try? await cli.run(["remove", "-target", target, item.resource])
            if r?.status != 0 { failure = lastLine(r?.stderr) ?? "remove failed" }
        case (nil, .cask(let token)):
            guard let brew = store.program("brew") else { return }
            let r = try? await ProcessRunner().run(brew, ["uninstall", "--cask", token], env: store.loginEnv)
            if r?.status != 0 { failure = lastLine(r?.stderr) ?? "brew uninstall failed" }
        default:
            failure = await recycle([app.url])
        }
        if failure == nil, !leftovers.isEmpty {
            failure = await recycle(leftovers.map(URL.init(fileURLWithPath:)))
        }
        if let failure {
            store.message = Store.Message(text: "\(app.name): \(failure)", failed: true)
        } else {
            apps.removeAll { $0.id == app.id }
            store.message = Store.Message(text: "\(app.name) is uninstalled.", failed: false)
        }
        monitor.readDisk()
    }

    /// Moves to the Trash; the Finder asks for a password when the app
    /// belongs to the system, as App Store apps do.
    private func recycle(_ urls: [URL]) async -> String? {
        do {
            _ = try await NSWorkspace.shared.recycle(urls)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func lastLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).last.map(String.init)
    }

    // MARK: Performance

    private var domain: String { "gui/\(getuid())" }

    func loadAgents() async {
        let home = NSHomeDirectory()
        var found = await Task.detached {
            LaunchAgent.read(folders: [home + "/Library/LaunchAgents", "/Library/LaunchAgents"])
        }.value
        async let disabledOut = try? ProcessRunner().run("/bin/launchctl", ["print-disabled", domain], env: [:])
        async let listOut = try? ProcessRunner().run("/bin/launchctl", ["list"], env: [:])
        let disabled = Launchd.parseDisabled(await disabledOut?.output ?? "")
        let running = Launchd.parseRunning(await listOut?.output ?? "")
        for i in found.indices {
            if let off = disabled[found[i].label] { found[i].enabled = !off }
            found[i].running = running.contains(found[i].label)
        }
        agents = found
        readBackground()
    }

    /// Apps that run without a Dock icon, such as menu bar extras; macOS's
    /// own helpers are left out.
    func readBackground() {
        let me = Bundle.main.bundleIdentifier
        background = NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .accessory, app.bundleIdentifier != me,
                      let path = app.bundleURL?.path else { return false }
                return !["/System/", "/usr/", "/Library/Apple/"].contains(where: path.hasPrefix)
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// Turns an agent off for good, or back on: launchctl's override
    /// outlives the plist, and the agent stops or starts now too.
    func setEnabled(_ agent: LaunchAgent, _ on: Bool) async {
        guard store.busy == nil else { return }
        store.busy = "\(on ? "Enabling" : "Disabling") \(agent.label)"
        defer { store.busy = nil }
        let target = domain + "/" + agent.label
        let steps = on
            ? [["enable", target], ["bootstrap", domain, agent.path]]
            : [["bootout", target], ["disable", target]]
        var failed: String?
        for args in steps {
            let r = try? await ProcessRunner().run("/bin/launchctl", args, env: [:])
            // bootout fails when the agent is not loaded, bootstrap when it is.
            if r?.status != 0, args[0] == "enable" || args[0] == "disable" { failed = lastLine(r?.stderr) ?? "launchctl failed" }
        }
        store.message = failed.map { Store.Message(text: "\(agent.label): \($0)", failed: true) }
            ?? Store.Message(text: "\(agent.label) is \(on ? "on" : "off").", failed: false)
        await loadAgents()
    }

    func quit(_ app: NSRunningApplication) {
        app.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            readBackground()
        }
    }
}
