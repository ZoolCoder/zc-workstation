import AppKit
import Observation
import ZCBarCore

/// The Care window's state: one Smart Care scan over the whole Mac, and the
/// modules it sums up. Changes go through the Store, which asks first.
@MainActor @Observable
final class Care {
    enum Module: String, CaseIterable, Identifiable {
        case smartCare = "Smart Care", cleanup = "Cleanup", protection = "Protection", performance = "Performance"
        case apps = "Applications", clutter = "My Clutter", spaceLens = "Space Lens", developer = "Developer"
        case tools = "My Tools", activity = "My Activity"

        /// The sidebar's two groups, as CleanMyMac splits them.
        static let modules: [Module] = [.smartCare, .cleanup, .protection, .performance, .apps, .clutter, .spaceLens, .developer]
        static let extras: [Module] = [.tools, .activity]

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .smartCare: "sparkles"
            case .cleanup: "trash.fill"
            case .clutter: "doc.on.doc.fill"
            case .developer: "hammer.fill"
            case .apps: "square.grid.2x2.fill"
            case .performance: "gauge.with.dots.needle.67percent"
            case .protection: "lock.shield.fill"
            case .spaceLens: "chart.pie.fill"
            case .tools: "square.grid.3x3.fill"
            case .activity: "chart.bar.xaxis"
            }
        }
    }

    let store: Store
    var module: Module = .smartCare
    var scanning = false
    var scannedAt: Date?
    var largeFiles: [LargeFile] = []
    var duplicates: [DuplicateGroup] = []
    /// Nil until looked for: comparing every photo takes a while.
    var similar: [SimilarGroup]?
    var scanningImages = false
    var oldDownloads: [LargeFile] = []
    var diskImages: [LargeFile] = []
    /// node_modules and the like in projects left alone for 90 days.
    var dependencies: [LargeFile] = []
    var models: [AIModel] = []
    /// Caches, logs, temp files and old versions AI tools leave.
    var aiJunk: [AIJunk] = []
    var scanningAI = false
    var scanningDeveloper = false
    /// Nil until looked for: what removed apps left in the Library.
    var orphans: [Orphan]?
    var loadingOrphans = false
    var maintenance: [MaintenanceTask] = []
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
    /// History, cookies and caches per browser; nil until read.
    var browserTraces: [BrowserTrace]?
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
    /// Modules past their intro in this launch.
    var entered: Set<Module> = []

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
    /// Large files, old downloads and installers, each once, and what duplicates waste.
    var clutter: Int64 {
        let files = Dictionary((largeFiles + oldDownloads + diskImages).map { ($0.id, $0.size) }, uniquingKeysWith: { a, _ in a })
        return files.values.reduce(0, +) + duplicates.reduce(0) { $0 + $1.wasted }
    }
    var adoptable: [InstalledApp] {
        apps.filter { $0.declared == nil && $0.source == .other && casks[$0.url.lastPathComponent] != nil }
    }
    var untrusted: [InstalledApp] { apps.filter { assessments[$0.id].map { !$0.trusted } ?? false } }
    var undeclared: [InstalledApp] { apps.filter { $0.declared == nil } }
    var unused: [InstalledApp] { apps.filter { $0.unused() } }
    var ai: Int64 { aiJunk.reduce(0) { $0 + $1.size } }
    var developer: Int64 { dependencies.reduce(0) { $0 + $1.size } + models.reduce(0) { $0 + $1.size } }
    var startup: [LaunchAgent] { agents.filter { $0.enabled && ($0.runAtLoad || $0.keepAlive) } }

    /// A module opens on its intro until its Scan is pressed; those Smart
    /// Care fills skip it once any scan has run.
    func showsIntro(_ m: Module) -> Bool {
        guard !entered.contains(m) else { return false }
        switch m {
        case .smartCare, .cleanup, .clutter, .apps, .performance, .developer: return scannedAt == nil && !scanning
        case .spaceLens: return space == nil && !scanningSpace
        case .protection: return true
        case .tools, .activity: return false
        }
    }

    /// The intro's Scan: leaves the intro and reads what the module shows.
    /// Protection and Performance read on appearing.
    func enter(_ m: Module) async {
        entered.insert(m)
        switch m {
        case .smartCare: await scan()
        case .cleanup:
            async let junk: Void = monitor.scan()
            async let ai: Void = scanAI()
            _ = await (junk, ai)
        case .clutter: await scanFiles()
        case .developer: await scanDeveloper()
        case .apps: await loadApps()
        case .spaceLens: await scanSpace()
        case .protection, .performance, .tools, .activity: break
        }
    }

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
        async let developer: Void = scanDeveloper()
        async let ai: Void = scanAI()
        _ = await (junk, state, files, apps, agents, developer, ai)
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
        diskImages = last.diskImages ?? []
        dependencies = last.dependencies ?? []
        models = last.models ?? []
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
        scan.diskImages = diskImages
        scan.dependencies = dependencies
        scan.models = models
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
        let installers = [downloads, URL(fileURLWithPath: home + "/Desktop")]
        async let large = Task.detached { LargeFiles.files(paths: paths, home: home, minimum: Self.largeFile) }.value
        async let same = Task.detached(priority: .utility) { Duplicates.groups(paths: paths, home: home, minimum: Self.duplicateFile) }.value
        async let old = Task.detached { OldDownloads.files(in: downloads) }.value
        async let images = Task.detached { DiskImages.files(in: installers) }.value
        (largeFiles, duplicates, oldDownloads, diskImages) = await (large, same, old, images)
    }

    func trash(_ file: LargeFile) {
        guard store.busy == nil, Alerts.confirm("Move \(file.name) to the Trash?",
                                                "\(Store.bytes(file.size)) in \(file.url.deletingLastPathComponent().path).",
                                                button: "Move to Trash") else { return }
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            largeFiles.removeAll { $0.id == file.id }
            oldDownloads.removeAll { $0.id == file.id }
            diskImages.removeAll { $0.id == file.id }
            dependencies.removeAll { $0.id == file.id }
            duplicates = duplicates.compactMap { group in
                var group = group
                group.files.removeAll { $0.id == file.id }
                return group.files.count > 1 ? group : nil
            }
            drop([file.id])
            monitor.readDisk()
            store.record(.files, file.name, freed: file.size)
            store.message = Store.Message(text: "\(file.name) is in the Trash.", failed: false)
        } catch {
            store.message = Store.Message(text: error.localizedDescription, failed: true)
        }
    }

    // MARK: Similar images

    /// Photos in Pictures, Desktop, Downloads and Documents, grouped by how
    /// alike Vision finds them.
    func scanImages() async {
        guard !scanningImages else { return }
        scanningImages = true
        defer { scanningImages = false }
        let home = NSHomeDirectory()
        let args = SimilarImages.folders(home: home).flatMap { ["-onlyin", $0] } + [SimilarImages.query]
        guard let r = try? await ProcessRunner().run("/usr/bin/mdfind", args, env: [:]) else { return }
        let paths = r.output.split(whereSeparator: \.isNewline).map(String.init)
        similar = await Task.detached(priority: .utility) { SimilarImages.groups(paths: paths, home: home) }.value
    }

    /// Moves every image but the best of a group to the Trash.
    func trashOthers(_ group: SimilarGroup) {
        let others = group.others
        guard store.busy == nil, Alerts.confirm("Move \(others.count) similar images to the Trash?",
                                                "\(Store.bytes(group.wasted)). \(group.best.name) stays.",
                                                button: "Move to Trash") else { return }
        var moved: [LargeFile] = []
        for file in others where (try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)) != nil {
            moved.append(file)
        }
        drop(Set(moved.map(\.id)))
        monitor.readDisk()
        let freed = moved.reduce(0) { $0 + $1.size }
        store.record(.files, "Similar to \(group.best.name)", freed: freed)
        store.message = Store.Message(text: "\(moved.count) of \(others.count) images are in the Trash.", failed: moved.count < others.count)
    }

    private func drop(_ ids: Set<String>) {
        similar = similar?.compactMap { group in
            var group = group
            group.files.removeAll { ids.contains($0.id) }
            return group.files.count > 1 ? group : nil
        }
    }

    // MARK: Developer

    /// Stale project dependencies and local AI models: both walk folders,
    /// so they run off the main actor.
    func scanDeveloper() async {
        scanningDeveloper = true
        defer { scanningDeveloper = false }
        let home = NSHomeDirectory()
        async let stale = Task.detached(priority: .utility) {
            ProjectDependencies.find(roots: ProjectDependencies.roots(home: home))
        }.value
        async let found = Task.detached(priority: .utility) { AIModels.find(home: home) }.value
        (dependencies, models) = await (stale, found)
    }

    func trashDependencies(_ folders: [LargeFile]) async {
        guard store.busy == nil, !folders.isEmpty else { return }
        let total = folders.reduce(0) { $0 + $1.size }
        let names = folders.prefix(8).map { ($0.url.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
        guard Alerts.confirm("Move \(folders.count) dependency folders to the Trash?",
                             "\(Store.bytes(total)). The next install in each project brings them back.\n\n" + names
                                 + (folders.count > 8 ? "\nand \(folders.count - 8) more" : ""),
                             button: "Move to Trash") else { return }
        store.busy = "Moving dependencies to the Trash"
        defer { store.busy = nil }
        let failure = await recycle(folders.map(\.url))
        let gone = Set(folders.map(\.id))
        dependencies.removeAll { gone.contains($0.id) && !FileManager.default.fileExists(atPath: $0.url.path) }
        if failure == nil { store.record(.developer, "Project Dependencies", freed: total) }
        store.message = failure.map { Store.Message(text: $0, failed: true) }
            ?? Store.Message(text: "\(Store.bytes(total)) of dependencies are in the Trash.", failed: false)
        monitor.readDisk()
    }

    func trash(_ model: AIModel) async {
        guard store.busy == nil, Alerts.confirm("Move \(model.name) to the Trash?",
                                                "\(Store.bytes(model.size)) of \(model.source.rawValue) model files. "
                                                    + "Pulling the model again downloads it.",
                                                button: "Move to Trash") else { return }
        store.busy = "Removing \(model.name)"
        defer { store.busy = nil }
        if let failure = await recycle(model.paths) {
            store.message = Store.Message(text: "\(model.name): \(failure)", failed: true)
        } else {
            models.removeAll { $0.id == model.id }
            store.record(.developer, model.name, freed: model.size)
            store.message = Store.Message(text: "\(model.name) is in the Trash.", failed: false)
        }
        monitor.readDisk()
    }

    // MARK: Recommendations

    struct Recommendation: Identifiable {
        let symbol: String
        let title: String
        let module: Module
        var id: String { title }
    }

    /// What the last scan found worth doing, for My Activity.
    var recommendations: [Recommendation] {
        var r: [Recommendation] = []
        if scannedAt.map({ Date.now.timeIntervalSince($0) > 7 * 86400 }) ?? true {
            r.append(Recommendation(symbol: "sparkles", title: "Run Smart Care: no scan this week", module: .smartCare))
        }
        if junk > 500_000_000 { r.append(Recommendation(symbol: "trash.fill", title: "Clean \(Store.bytes(junk)) of system junk", module: .cleanup)) }
        if ai > 200_000_000 { r.append(Recommendation(symbol: "brain.head.profile", title: "Clear \(Store.bytes(ai)) of AI clutter", module: .cleanup)) }
        let outdated = store.snapshot?.outdated.count ?? 0
        if outdated > 0 { r.append(Recommendation(symbol: "arrow.down.circle.fill", title: "Update \(outdated) packages", module: .apps)) }
        let findings = store.findings.count
        if findings > 0 { r.append(Recommendation(symbol: "stethoscope", title: findings == 1 ? "Look at 1 health finding" : "Look at \(findings) health findings", module: .smartCare)) }
        if !untrusted.isEmpty {
            r.append(Recommendation(symbol: "exclamationmark.shield.fill", title: "Check \(untrusted.count) apps Gatekeeper rejects", module: .protection))
        }
        let idle = dependencies.reduce(0) { $0 + $1.size }
        if idle > 1_000_000_000 {
            r.append(Recommendation(symbol: "shippingbox.fill", title: "Remove \(Store.bytes(idle)) of idle project dependencies", module: .developer))
        }
        if clutter > 1_000_000_000 { r.append(Recommendation(symbol: "doc.on.doc.fill", title: "Review \(Store.bytes(clutter)) of large files", module: .clutter)) }
        if !unused.isEmpty { r.append(Recommendation(symbol: "square.grid.2x2.fill", title: "Uninstall \(unused.count) unused apps", module: .apps)) }
        if startup.count > 10 { r.append(Recommendation(symbol: "power", title: "Review \(startup.count) login items", module: .performance)) }
        return r
    }

    /// Opens a module, past its intro, scanning what it shows if nothing has.
    func open(_ m: Module) {
        module = m
        if showsIntro(m) { Task { await enter(m) } }
    }

    // MARK: AI Clutter

    func scanAI() async {
        scanningAI = true
        defer { scanningAI = false }
        let home = NSHomeDirectory()
        let temp = "/private/tmp/claude-\(getuid())"
        aiJunk = await Task.detached(priority: .utility) { AIClutter.find(home: home, claudeTemp: temp) }.value
    }

    /// Deletes the picked junk for good, as Cleanup clears caches: each tool
    /// makes it again when it needs it.
    func cleanAI(_ picked: [AIJunk]) async {
        guard store.busy == nil, !picked.isEmpty else { return }
        let total = picked.reduce(0) { $0 + $1.size }
        let list = picked.map { "\($0.tool), \($0.kind): \(Store.bytes($0.size))" }.joined(separator: "\n")
        guard Alerts.confirm("Clear \(Store.bytes(total)) of AI clutter?",
                             list + "\n\nChats, settings, sessions and the running Claude Code version stay.",
                             button: "Clear") else { return }
        store.busy = "Clearing AI clutter"
        defer { store.busy = nil }
        let paths = picked.flatMap(\.paths)
        let stuck = await Task.detached {
            paths.filter { (try? FileManager.default.removeItem(at: $0)) == nil }.count
        }.value
        await scanAI()
        let freed = max(total - picked.reduce(0) { sum, p in sum + (aiJunk.first { $0.id == p.id }?.size ?? 0) }, 0)
        store.record(.ai, picked.count == 1 ? picked[0].tool : "AI Clutter", freed: freed)
        monitor.readDisk()
        store.message = Store.Message(text: "AI clutter: freed \(Store.bytes(freed))" + (stuck > 0 ? "; \(stuck) in use stayed." : "."),
                                      failed: false)
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
            store.record(.apps, app.name, freed: app.size ?? 0)
            store.message = Store.Message(text: "\(app.name) is uninstalled.", failed: false)
        }
        monitor.readDisk()
    }

    // MARK: Leftovers

    /// Library entries named for apps Launch Services no longer knows.
    func loadOrphans() async {
        guard !loadingOrphans else { return }
        loadingOrphans = true
        defer { loadingOrphans = false }
        let home = NSHomeDirectory()
        orphans = await Task.detached(priority: .utility) {
            Leftovers.orphans(home: home) { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        }.value
    }

    func trashOrphans(_ picked: [Orphan]) async {
        guard store.busy == nil, !picked.isEmpty else { return }
        let total = picked.reduce(0) { $0 + $1.size }
        let names = picked.prefix(10).map(\.bundleID).joined(separator: "\n")
        guard Alerts.confirm("Move what \(picked.count) removed apps left to the Trash?",
                             "\(Store.bytes(total)) in caches, settings and support files:\n\n" + names
                                 + (picked.count > 10 ? "\nand \(picked.count - 10) more" : ""),
                             button: "Move to Trash") else { return }
        store.busy = "Removing leftovers"
        defer { store.busy = nil }
        let failure = await recycle(picked.flatMap { $0.paths.map(URL.init(fileURLWithPath:)) })
        let gone = Set(picked.map(\.id))
        orphans?.removeAll { o in gone.contains(o.id) && !o.paths.contains(where: FileManager.default.fileExists) }
        if failure == nil { store.record(.apps, "App Leftovers", freed: total) }
        store.message = failure.map { Store.Message(text: $0, failed: true) }
            ?? Store.Message(text: "Leftovers of \(picked.count) apps are in the Trash.", failed: false)
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

    // MARK: Maintenance

    func loadMaintenance() {
        let xcode = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
        maintenance = Maintenance.tasks(brew: store.program("brew"), docker: store.program("docker"), xcode: xcode)
    }

    /// Runs one task after asking; admin tasks go through osascript, which
    /// asks for the password itself.
    func run(_ task: MaintenanceTask) async {
        guard store.busy == nil,
              Alerts.confirm("\(task.title)?", task.detail + (task.admin ? "\n\nmacOS asks for your password." : ""),
                             button: "Run") else { return }
        store.busy = task.title
        defer { store.busy = nil }
        var failure: String?
        if task.admin {
            let r = try? await ProcessRunner().run("/usr/bin/osascript", ["-e", Maintenance.adminScript(task.steps)], env: [:])
            if r?.status != 0 { failure = lastLine(r?.stderr) ?? "osascript failed" }
        } else {
            for step in task.steps {
                let r = try? await ProcessRunner().run(step[0], Array(step.dropFirst()), env: store.loginEnv)
                if r?.status != 0 { failure = lastLine(r?.stderr) ?? "\(step[0]) failed"; break }
            }
        }
        if failure == nil { store.record(.maintenance, task.title) }
        store.message = failure.map { Store.Message(text: "\(task.title): \($0)", failed: true) }
            ?? Store.Message(text: "\(task.title): done.", failed: false)
        monitor.readDisk()
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
        await loadBrowserTraces()
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

    func loadBrowserTraces() async {
        let home = NSHomeDirectory()
        browserTraces = await Task.detached(priority: .utility) { BrowserPrivacy.find(home: home) }.value
    }

    func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Deletes one browser's history, cookies or cache, only while that
    /// browser is closed: an open one holds the databases and writes them back.
    func clearBrowser(_ trace: BrowserTrace) async {
        guard store.busy == nil else { return }
        guard !isRunning(trace.bundleID) else {
            store.message = Store.Message(text: "Quit \(trace.browser) first, then clear its \(trace.kind.lowercased()).", failed: true)
            return
        }
        let effect = switch trace.kind {
        case BrowserPrivacy.cookies: "You will be signed out of websites in \(trace.browser)."
        case BrowserPrivacy.history: "\(trace.browser) forgets the pages you visited; bookmarks and passwords stay."
        default: "\(trace.browser) downloads pages again as you visit them."
        }
        guard Alerts.confirm("Clear \(trace.browser)'s \(trace.kind.lowercased())?",
                             "This deletes \(trace.paths.count) items, \(Store.bytes(trace.size)).\n\n" + effect,
                             button: "Clear") else { return }
        store.busy = "Clearing \(trace.browser) \(trace.kind.lowercased())"
        defer { store.busy = nil }
        let stuck = await Task.detached { BrowserPrivacy.clear(trace) }.value
        await loadBrowserTraces()
        let left = browserTraces?.first { $0.id == trace.id }?.size ?? 0
        store.record(.privacy, "\(trace.browser) \(trace.kind)", freed: max(trace.size - left, 0))
        monitor.readDisk()
        store.message = Store.Message(text: "\(trace.browser) \(trace.kind.lowercased()) cleared" + (stuck > 0 ? "; \(stuck) items stayed." : "."),
                                      failed: stuck > 0)
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
