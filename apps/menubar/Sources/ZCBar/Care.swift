import AppKit
import Observation
import ZCBarCore

/// The Care window's state: one Smart Care scan over the whole Mac, and the
/// modules it sums up. Changes go through the Store, which asks first.
@MainActor @Observable
final class Care {
    enum Module: String, CaseIterable, Identifiable {
        case smartCare = "Smart Care", cleanup = "Cleanup", clutter = "My Clutter", apps = "Applications"
        case performance = "Performance", protection = "Protection", spaceLens = "Space Lens"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .smartCare: "sparkles"
            case .cleanup: "trash.fill"
            case .clutter: "doc.on.doc.fill"
            case .apps: "square.grid.2x2.fill"
            case .performance: "gauge.with.dots.needle.67percent"
            case .protection: "lock.shield.fill"
            case .spaceLens: "chart.pie.fill"
            }
        }
    }

    let store: Store
    var module: Module = .smartCare
    var scanning = false
    var scannedAt: Date?
    var largeFiles: [LargeFile] = []
    var duplicates: [DuplicateGroup] = []
    var oldDownloads: [LargeFile] = []
    var scanningFiles = false
    /// Each app bundle's cask, from Homebrew's index: what an app installed
    /// by hand can be adopted as.
    var casks: [String: String] = [:]
    var backgroundItems: [BackgroundItem] = []
    var assessments: [String: Assessment] = [:]
    var gatekeeper: Bool?
    /// Nil until read; the TCC databases need Full Disk Access.
    var permissions: [Permission]?
    var loadingProtection = false
    var loadingBackground = false
    var space: SpaceScan?
    var scanningSpace = false
    var apps: [InstalledApp] = []
    var loadingApps = false
    var icons: [String: NSImage] = [:]
    var agents: [LaunchAgent] = []
    var background: [NSRunningApplication] = []
    /// False until a scan runs in this launch: what shows before came from disk.
    var fresh = false

    /// Large Files lists files from this size up.
    nonisolated static let largeFile: Int64 = 200 * 1024 * 1024
    /// Duplicates are looked for from this size up: hashing smaller files
    /// costs more than they waste.
    nonisolated static let duplicateFile: Int64 = 10 * 1024 * 1024

    init(store: Store) {
        self.store = store
        restore()
    }

    var monitor: Monitor { store.monitor }
    var junk: Int64 { monitor.junk.values.reduce(0, +) }
    /// Large files and old downloads, each once, and what duplicates waste.
    var clutter: Int64 {
        let files = Dictionary((largeFiles + oldDownloads).map { ($0.id, $0.size) }, uniquingKeysWith: { a, _ in a })
        return files.values.reduce(0, +) + duplicates.reduce(0) { $0 + $1.wasted }
    }
    var adoptable: [InstalledApp] {
        apps.filter { $0.declared == nil && $0.source == .other && casks[$0.url.lastPathComponent] != nil }
    }
    var untrusted: [InstalledApp] { apps.filter { assessments[$0.id].map { !$0.trusted } ?? false } }
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
        fresh = true
        save()
    }

    // MARK: Last scan

    private static let saved = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.zoolcoder.zcbar/care.json")

    /// Shows the last scan at once; the window starts a fresh one.
    private func restore() {
        guard let last = CareScan.load(from: Self.saved) else { return }
        scannedAt = last.scannedAt
        if monitor.junk.isEmpty { monitor.junk = last.junk }
        largeFiles = last.largeFiles
        duplicates = last.duplicates ?? []
        oldDownloads = last.oldDownloads ?? []
        apps = last.apps
        agents = last.agents
        for app in apps { icons[app.id] = NSWorkspace.shared.icon(forFile: app.url.path) }
        readBackground()
        space = SpaceScan.load(from: Self.savedSpace)
    }

    private func save() {
        guard let scannedAt else { return }
        var scan = CareScan(scannedAt: scannedAt, junk: monitor.junk, largeFiles: largeFiles, apps: apps, agents: agents)
        scan.duplicates = duplicates
        scan.oldDownloads = oldDownloads
        try? scan.save(to: Self.saved)
    }

    // MARK: Weekly scan

    /// Looks every hour whether a week has passed since the last scan, and
    /// scans then; what it finds worth knowing becomes a notification.
    func startSchedule() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.scheduledScan()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private var schedule: Task<Void, Never>?

    private func scheduledScan() async {
        guard store.weeklyScan, !scanning, CareSchedule.due(last: scannedAt) else { return }
        await scan()
        guard store.notifies else { return }
        store.notifier.post(CareSchedule.alerts(junk: junk, outdated: store.snapshot?.outdated.count ?? 0,
                                                findings: store.findings.count))
    }

    /// Smart Care's Run: cleans up, then updates, each after its question.
    func run() async {
        if junk > 0 { await store.cleanAll() }
        if !(store.snapshot?.outdated.isEmpty ?? true) { await store.updateAll() }
    }

    // MARK: Large files

    /// Large files and duplicates come from one Spotlight query, old
    /// downloads from the folder itself.
    func scanFiles() async {
        scanningFiles = true
        defer { scanningFiles = false }
        let home = NSHomeDirectory()
        let args = ["-onlyin", home, LargeFiles.query(minimum: Self.duplicateFile)]
        guard let r = try? await ProcessRunner().run("/usr/bin/mdfind", args, env: [:]) else { return }
        let paths = r.output.split(whereSeparator: \.isNewline).map(String.init)
        let downloads = URL(fileURLWithPath: home + "/Downloads")
        async let large = Task.detached { LargeFiles.files(paths: paths, home: home, minimum: Self.largeFile) }.value
        async let same = Task.detached(priority: .utility) { Duplicates.groups(paths: paths, home: home, minimum: Self.duplicateFile) }.value
        async let old = Task.detached { OldDownloads.files(in: downloads) }.value
        (largeFiles, duplicates, oldDownloads) = await (large, same, old)
    }

    func trash(_ file: LargeFile) {
        guard store.busy == nil, Alerts.confirm("Move \(file.name) to the Trash?",
                                                "\(Store.bytes(file.size)) in \(file.url.deletingLastPathComponent().path).",
                                                button: "Move to Trash") else { return }
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            largeFiles.removeAll { $0.id == file.id }
            oldDownloads.removeAll { $0.id == file.id }
            duplicates = duplicates.compactMap { group in
                var group = group
                group.files.removeAll { $0.id == file.id }
                return group.files.count > 1 ? group : nil
            }
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
        self.items = items
        if casks.isEmpty { casks = await Task.detached { Self.readCaskIndex() }.value }
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
        let method = Uninstall.method(declared: app.declared, source: app.source)
        var how: String
        switch method {
        case .remove(_, let resource): how = "zc-workstation removes \(resource) and drops it from the Brewfile."
        case .cask(let token): how = "Homebrew uninstalls the cask \(token)."
        case .trash: how = "The app moves to the Trash."
        }
        if !leftovers.isEmpty {
            how += "\n\nIts files move to the Trash:\n" + leftovers.map { ($0 as NSString).abbreviatingWithTildeInPath }
                .joined(separator: "\n")
        }
        guard Alerts.confirm("Uninstall \(app.name)?", how, button: "Uninstall") else { return }
        store.busy = "Uninstalling \(app.name)"
        defer { store.busy = nil }
        var failure: String?
        switch method {
        case .remove(let target, let resource):
            guard let cli = store.cli else { return }
            let r = try? await cli.run(["remove", "-target", target, resource])
            if r?.status != 0 { failure = lastLine(r?.stderr) ?? "remove failed" }
        case .cask(let token):
            guard let brew = store.program("brew") else { return }
            let r = try? await ProcessRunner().run(brew, ["uninstall", "--cask", token], env: store.loginEnv)
            if r?.status != 0 { failure = lastLine(r?.stderr) ?? "brew uninstall failed" }
        case .trash:
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

    // MARK: Adopting

    private var items: [Item] = []

    private nonisolated static func readCaskIndex() -> [String: String] {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Homebrew/api/internal")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        guard let name = files.first(where: { $0.hasPrefix("packages.") && $0.hasSuffix(".jws.json") }),
              let data = try? Data(contentsOf: cache.appendingPathComponent(name)) else { return [:] }
        return CaskIndex.apps(jws: data)
    }

    /// Hands an app installed by hand to Homebrew, which takes over the copy
    /// in place, and declares the cask so the Brewfile knows it.
    func adopt(_ app: InstalledApp) async {
        guard store.busy == nil, let token = casks[app.url.lastPathComponent],
              let brew = store.program("brew"), let cli = store.cli else { return }
        guard let target = CaskIndex.target(items: items) else {
            store.message = Store.Message(text: "No target declares casks to adopt \(app.name) into.", failed: true)
            return
        }
        guard Alerts.confirm("Adopt \(app.name) as cask \(token)?",
                             "Homebrew takes over the app in /Applications, and zc-workstation adds cask:\(token) to the \(target) target.",
                             button: "Adopt") else { return }
        store.busy = "Adopting \(app.name)"
        defer { store.busy = nil }
        let install = try? await ProcessRunner().run(brew, ["install", "--cask", "--adopt", token], env: store.loginEnv)
        guard install?.status == 0 else {
            store.message = Store.Message(text: "\(app.name): \(lastLine(install?.stderr) ?? "brew install failed")", failed: true)
            return
        }
        let add = try? await cli.run(["add", "-target", target, "-why", "Adopted from /Applications by ZC Care", "cask:" + token])
        store.message = add?.status == 0
            ? Store.Message(text: "\(app.name) is now cask \(token) in \(target).", failed: false)
            : Store.Message(text: "Homebrew adopted \(app.name), but add failed: \(lastLine(add?.stderr) ?? "")", failed: true)
        await loadApps()
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
        var failed: String?
        for args in Launchd.toggleSteps(domain: domain, label: agent.label, plist: agent.path, on: on) {
            let r = try? await ProcessRunner().run("/bin/launchctl", args, env: [:])
            if r?.status != 0, Launchd.mustSucceed(args) { failed = lastLine(r?.stderr) ?? "launchctl failed" }
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

    // MARK: Protection

    /// How Gatekeeper sees each app, and the privacy permissions apps
    /// hold, all read-only.
    func loadProtection() async {
        guard !loadingProtection else { return }
        loadingProtection = true
        defer { loadingProtection = false }
        if apps.isEmpty { await loadApps() }
        async let status = try? ProcessRunner().run("/usr/sbin/spctl", ["--status"], env: [:])
        async let tcc = readPermissions()
        gatekeeper = await status.map { $0.output.contains("assessments enabled") }
        permissions = await tcc
        await withTaskGroup(of: (String, Assessment).self) { group in
            for app in apps where assessments[app.id] == nil {
                group.addTask {
                    let r = try? await ProcessRunner().run("/usr/sbin/spctl", ["--assess", "-v", app.url.path], env: [:])
                    return (app.id, Assessment.parse(r?.stderr ?? ""))
                }
            }
            for await (id, a) in group { assessments[id] = a }
        }
    }

    /// What runs with the session, as Background Task Management keeps it.
    /// sfltool asks for an administrator's password when an app runs it,
    /// so this waits for a click.
    func loadBackgroundItems() async {
        guard !loadingBackground else { return }
        loadingBackground = true
        defer { loadingBackground = false }
        guard let r = try? await ProcessRunner().run("/usr/bin/sfltool", ["dumpbtm"], env: [:]), r.status == 0 else {
            store.message = Store.Message(text: "Background items not read: the password was not given.", failed: true)
            return
        }
        backgroundItems = BackgroundItems.parse(r.output, uid: getuid())
            .sorted { ($0.developer ?? "~", $0.name) < ($1.developer ?? "~", $1.name) }
    }

    /// Nil without Full Disk Access: macOS keeps both databases from apps
    /// that lack it.
    private func readPermissions() async -> [Permission]? {
        let dbs = [NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
                   "/Library/Application Support/com.apple.TCC/TCC.db"]
        var rows: [Permission]?
        for db in dbs {
            guard let r = try? await ProcessRunner().run("/usr/bin/sqlite3", ["-readonly", "-separator", "|", db, Privacy.query], env: [:]),
                  r.status == 0 else { continue }
            rows = (rows ?? []) + Privacy.parse(r.output)
        }
        return rows?.sorted { ($0.service, $0.client) < ($1.service, $1.client) }
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
    }

    // MARK: Space Lens

    private static let savedSpace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.zoolcoder.zcbar/space.json")

    /// du over the home folder, three levels down, on this volume only: it
    /// takes minutes, so the last one stays on disk.
    func scanSpace() async {
        guard !scanningSpace else { return }
        scanningSpace = true
        defer { scanningSpace = false }
        let home = NSHomeDirectory()
        guard let r = try? await ProcessRunner().run("/usr/bin/du", ["-k", "-d", "3", "-x", home], env: [:]) else { return }
        let text = r.output
        guard let root = await Task.detached(operation: { SpaceLens.parse(du: text, root: home) }).value else {
            store.message = Store.Message(text: "Space Lens could not read \(home).", failed: true)
            return
        }
        let scan = SpaceScan(scannedAt: .now, root: root)
        space = scan
        try? scan.save(to: Self.savedSpace)
    }
}
