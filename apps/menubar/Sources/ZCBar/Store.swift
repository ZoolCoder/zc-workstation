import AppKit
import Observation
import ServiceManagement
import UniformTypeIdentifiers
import ZCBarCore

/// The app's state and every action the menu offers. All work goes through
/// the CLI; the app only reads its JSON and asks before it changes anything.
@MainActor @Observable
final class Store {
    var snapshot: Snapshot? {
        didSet { publish() }
    }
    var refreshedAt: Date?
    var refreshing = false
    /// What a running change is doing, such as "Updating tmux".
    var busy: String?
    /// The outcome of the last change, or why it failed.
    var message: Message?
    /// The plan Plan last showed.
    var plan: PlanDoc?
    /// Why the CLI cannot run: no binary, or no config.
    var setupProblem: String? {
        didSet { publish() }
    }
    var ignored: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(ignored).sorted(), forKey: Keys.ignored)
            publish()
        }
    }

    var tab: Tab = .mac
    /// Disk, memory, CPU and the rest, for the Mac tab.
    let monitor = Monitor()
    /// The Mac tab's open tile: what Free Up clears, or the busiest apps.
    var macDetail: MacDetail? {
        didSet {
            monitor.order = macDetail == .memory ? .memory : macDetail == .cpu ? .cpu : nil
            if macDetail == .disk, monitor.junk.isEmpty { Task { await monitor.scan() } }
        }
    }

    enum MacDetail: String { case disk, memory, cpu }
    /// The target whose items the overview shows, and what they are.
    var expanded: String?
    var targetItems: [String: [Item]] = [:]
    /// What ZC Care cleaned and ran, for My Activity.
    var activity = ActivityLog.load(from: Store.activityFile)
    /// Launch agents that run on a calendar, such as the weekly upkeep.
    var jobs: [Job] = []

    enum Tab: String, CaseIterable {
        case mac = "Mac", overview = "Overview", updates = "Updates", health = "Health", services = "Services"
    }

    struct Message: Equatable {
        var text: String
        var failed: Bool
        var log: URL?
    }

    private enum Keys {
        static let config = "configPath"
        static let ignored = "ignoredChecks"
        static let notifies = "notifies"
        static let hotkey = "hotkey"
        static let weeklyScan = "weeklyScan"
    }

    private var workstation: Workstation?
    private var env: [String: String] = [:]
    private var dashboard: Process?
    private var ticker: Task<Void, Never>?
    private let planFile = FileManager.default.temporaryDirectory.appendingPathComponent("zcbar-plan.json").path
    let notifier = Notifier()
    /// Set by the app delegate, which owns the hotkey.
    var hotkeyChanged: ((Bool) -> Void)?
    /// Set by the app delegate, which owns the Care window.
    var openCare: (() -> Void)?

    init() {
        ignored = Set(UserDefaults.standard.stringArray(forKey: Keys.ignored) ?? [])
        UserDefaults.standard.register(defaults: [Keys.notifies: true, Keys.hotkey: true, Keys.weeklyScan: true])
        notifies = UserDefaults.standard.bool(forKey: Keys.notifies)
        hotkey = UserDefaults.standard.bool(forKey: Keys.hotkey)
        weeklyScan = UserDefaults.standard.bool(forKey: Keys.weeklyScan)
    }

    /// Smart Care scans by itself once a week.
    var weeklyScan: Bool {
        didSet { UserDefaults.standard.set(weeklyScan, forKey: Keys.weeklyScan) }
    }

    var notifies: Bool {
        didSet {
            UserDefaults.standard.set(notifies, forKey: Keys.notifies)
            if notifies { Task { await notifier.authorize() } }
        }
    }

    /// ⌃⌥Z opens the panel from anywhere.
    var hotkey: Bool {
        didSet {
            UserDefaults.standard.set(hotkey, forKey: Keys.hotkey)
            hotkeyChanged?(hotkey)
        }
    }

    var attention: Int { snapshot?.attention(ignoring: ignored) ?? 0 }
    var findings: [Check] { snapshot?.findings(ignoring: ignored) ?? [] }
    var ignoredFindings: [Check] { snapshot?.findings.filter { ignored.contains($0.name) } ?? [] }
    var configPath: String? { workstation?.config }
    /// The CLI and the login environment, for the Care window.
    var cli: Workstation? { workstation }
    var loginEnv: [String: String] { env }

    /// A program on the login PATH, or in Homebrew's folder.
    func program(_ name: String) -> String? {
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin"]
        return dirs.map { $0 + "/" + name }.first(where: FileManager.default.isExecutableFile)
    }

    // MARK: Refresh

    func start() async {
        if notifies { await notifier.authorize() }
        await connect()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                await self?.refresh()
            }
        }
    }

    /// Finds the CLI and the config, then reads the machine.
    func connect() async {
        env = await Discovery.loginEnvironment()
        let home = NSHomeDirectory()
        guard let binary = Discovery.binary(env: env, home: home) else {
            setupProblem = "zc-workstation is not installed. Run make install in the zc-workstation repository."
            return
        }
        let chosen = UserDefaults.standard.string(forKey: Keys.config)
        guard let config = Discovery.config(chosen: chosen, env: env, home: home) else {
            setupProblem = "Choose your zc-workstation.yaml to start."
            return
        }
        setupProblem = nil
        workstation = Workstation(binary: binary, config: config, env: env)
        await refresh()
    }

    func refresh() async {
        guard let workstation, !refreshing else { return }
        refreshing = true
        let old = snapshot
        let new = await workstation.snapshot()
        snapshot = new
        refreshedAt = .now
        jobs = await readJobs(new.services)
        targetItems = [:]
        if let expanded { await loadItems(expanded) }
        refreshing = false
        // The first read has nothing to compare with: what is already
        // outstanding at launch is the badge's to show.
        if notifies, let old { notifier.post(new.alerts(since: old, ignoring: ignored)) }
    }

    /// Opening the menu reads again once the last read is a few minutes old.
    func refreshIfStale() {
        guard let refreshedAt, Date.now.timeIntervalSince(refreshedAt) > 120 else { return }
        Task { await refresh() }
    }

    func chooseConfig() {
        let panel = NSOpenPanel()
        panel.title = "Choose your zc-workstation config"
        panel.allowedContentTypes = [.yaml]
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Keys.config)
        Task { await connect() }
    }

    // MARK: Targets

    /// Opens or closes a target's list of what is not in place.
    func toggle(_ target: String) {
        expanded = expanded == target ? nil : target
        if let expanded, targetItems[expanded] == nil { Task { await loadItems(expanded) } }
    }

    func loadItems(_ target: String) async {
        guard let workstation else { return }
        do {
            targetItems[target] = try await workstation.items(targets: [target], states: ["missing", "differs", "manual"])
        } catch {
            message = Message(text: error.localizedDescription, failed: true)
        }
    }

    // MARK: Changes

    /// Upgrades one package, which its Update button already asked for.
    func update(_ item: Item) async {
        await changeItem(item, upgrade: true, label: "Updating \(item.name)")
    }

    /// Puts one missing or differing item in place.
    func fix(_ item: Item) async {
        await changeItem(item, upgrade: false, label: "Fixing \(item.name)")
    }

    func fixTarget(_ target: String) async {
        await change("Applying \(target)", confirm: true) {
            (try await $0.plan(targets: [target], savingTo: self.planFile), false)
        }
    }

    func updateAll() async {
        await change("Updating \(snapshot?.outdated.count ?? 0) packages", confirm: true) {
            (try await $0.plan(upgrade: true, savingTo: self.planFile), false)
        }
    }

    func apply() async {
        await change("Applying", confirm: true) { (try await $0.plan(savingTo: self.planFile), false) }
    }

    /// Plans just the item. When no change carries one of its names, the
    /// whole target is planned instead, and the owner sees what that holds.
    private func changeItem(_ item: Item, upgrade: Bool, label: String) async {
        guard let target = item.target else { return }
        await change(label, confirm: false) { ws in
            let doc = try await ws.plan(upgrade: upgrade, targets: [target], only: item.planNames, savingTo: self.planFile)
            if doc.actions.contains(where: { $0.manual != true }) { return (doc, false) }
            return (try await ws.plan(upgrade: upgrade, targets: [target], savingTo: self.planFile), true)
        }
    }

    /// Shows what apply would change, without changing anything.
    func showPlan() async {
        guard let workstation else { return }
        busy = "Planning"
        defer { busy = nil }
        do {
            plan = try await workstation.plan(savingTo: planFile)
        } catch {
            message = Message(text: error.localizedDescription, failed: true)
        }
    }

    /// Plans, asks when confirm is set, the plan widened, or it deletes,
    /// then applies exactly the plan that was shown.
    private func change(_ label: String, confirm: Bool,
                        plan make: @escaping (Workstation) async throws -> (PlanDoc, widened: Bool)) async {
        guard let workstation, busy == nil else { return }
        busy = label
        defer { busy = nil }
        do {
            let (doc, widened) = try await make(workstation)
            let executable = doc.actions.filter { $0.manual != true }
            guard !executable.isEmpty else {
                message = Message(text: "Nothing to change.", failed: false)
                return
            }
            if confirm || widened || doc.deletes, !Alerts.confirm(plan: doc) { return }
            let result = try await workstation.apply(saved: planFile)
            let log = writeLog(result)
            plan = nil
            message = result.status == 0
                ? Message(text: "\(label): done and verified.", failed: false, log: log)
                : Message(text: lastLine(of: result) ?? "\(label) failed.", failed: true, log: log)
        } catch {
            message = Message(text: error.localizedDescription, failed: true)
        }
        await refresh()
    }

    private func lastLine(of r: CommandResult?) -> String? {
        guard let r else { return nil }
        return (r.output + r.stderr).split(whereSeparator: \.isNewline).last { $0.contains("fail") || $0.contains("error") }
            .map(String.init)
    }

    /// Keeps the last change's whole output, for the Show log link.
    private func writeLog(_ r: CommandResult) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ZCBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("last-change.log")
        let text = r.output + (r.stderr.isEmpty ? "" : "\n--- stderr\n" + r.stderr)
        return (try? text.write(to: file, atomically: true, encoding: .utf8)) == nil ? nil : file
    }

    // MARK: Services

    func service(_ item: Item, _ action: ServiceAction) async {
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin"]
        let brew = dirs.map { $0 + "/brew" }.first(where: FileManager.default.isExecutableFile) ?? "/opt/homebrew/bin/brew"
        guard busy == nil,
              let (program, args) = Launchd.command(action, for: item, uid: getuid(), home: NSHomeDirectory(), brew: brew)
        else { return }
        busy = "\(action.rawValue.capitalized) \(item.name)"
        defer { busy = nil }
        let r = try? await ProcessRunner().run(program, args, env: env)
        message = r?.status == 0
            ? Message(text: "\(item.name): \(action == .run ? "started" : action.rawValue + " done").", failed: false)
            : Message(text: "\(item.name): \(lastLine(of: r) ?? "\(action.rawValue) failed").", failed: true)
        await refresh()
    }

    func run(_ job: Job) async {
        await service(Item(name: job.label, kind: "agent", state: "in place"), .run)
    }

    /// The scheduled agents among the services, with what launchd says of
    /// their last run; launchctl is asked about every agent at once.
    private func readJobs(_ services: [Item]) async -> [Job] {
        var jobs: [Job] = []
        let home = NSHomeDirectory()
        var plists: [(String, [String: Any], [DateComponents])] = []
        for agent in services where agent.kind == "agent" {
            let path = Launchd.plistPath(agent.name, home: home)
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            let schedule = Launchd.schedule(plist: plist)
            if !schedule.isEmpty { plists.append((agent.name, plist, schedule)) }
        }
        let uid = getuid()
        let prints = await withTaskGroup(of: (String, String?).self) { group in
            for (label, _, _) in plists {
                group.addTask {
                    let r = try? await ProcessRunner().run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"], env: [:])
                    return (label, r?.output)
                }
            }
            var outputs: [String: String] = [:]
            for await (label, output) in group { outputs[label] = output }
            return outputs
        }
        for (label, plist, schedule) in plists {
            var job = Job(label: label, schedule: schedule)
            if let output = prints[label] {
                (job.running, job.lastExit) = Launchd.parsePrint(output)
            }
            let log = Launchd.log(label: label, plist: plist, home: home)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: log) {
                job.log = URL(fileURLWithPath: log)
                job.lastRun = attrs[.modificationDate] as? Date
            }
            jobs.append(job)
        }
        return jobs
    }

    // MARK: Findings

    func fix(_ check: Check) async {
        switch Fix(for: check) {
        case .command(let command):
            guard Alerts.confirm(fix: command, for: check.title) else { return }
            busy = "Fixing \(check.title)"
            defer { busy = nil }
            let script = adminScript(command)
            let r = try? await ProcessRunner().run("/usr/bin/osascript", ["-e", script], env: [:])
            message = r?.status == 0
                ? Message(text: "\(check.title): fixed.", failed: false)
                : Message(text: "\(check.title): not changed. \(r?.stderr ?? "")", failed: true)
            await refresh()
        case .settings(let url, let what):
            NSWorkspace.shared.open(url)
            message = Message(text: what, failed: false)
        case .info(let text):
            Alerts.info(check.title, text)
        }
    }

    func ignore(_ check: Check) { ignored.insert(check.name) }
    func unignoreAll() { ignored.removeAll() }

    // MARK: Dashboard

    /// Opens the web dashboard, starting `zc-workstation ui` when it is not
    /// already running. The app stops what it started when it quits.
    func openDashboard(path: String = "/") async {
        guard let workstation, let url = URL(string: "http://127.0.0.1:7780" + path) else { return }
        if !(await Self.isServing()) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: workstation.binary)
            p.arguments = ["ui", "-config", workstation.config]
            p.environment = workstation.env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                message = Message(text: "Cannot start the dashboard: \(error.localizedDescription)", failed: true)
                return
            }
            dashboard = p
            for _ in 0..<20 where !(await Self.isServing()) {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        NSWorkspace.shared.open(url)
    }

    /// Asks for a static file: the dashboard itself measures every target,
    /// which takes longer than this probe waits.
    private static func isServing() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:7780/zc/theme.css")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 0.5
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    func stop() {
        ticker?.cancel()
        dashboard?.terminate()
    }

    // MARK: SketchyBar

    /// Hands the count to SketchyBar's zcbar item, which reads it from a file
    /// when the zcbar_changed event says it changed.
    private func publish() {
        let value = setupProblem != nil ? "setup" : snapshot.map { String($0.attention(ignoring: ignored)) }
        guard let value else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ZCBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? value.write(to: dir.appendingPathComponent("attention"), atomically: true, encoding: .utf8)
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin"]
        guard let bar = dirs.map({ $0 + "/sketchybar" }).first(where: FileManager.default.isExecutableFile) else { return }
        // sketchybar finds its server by $USER, so it gets the login environment.
        let env = env
        Task.detached { _ = try? await ProcessRunner().run(bar, ["--trigger", "zcbar_changed"], env: env) }
    }

    // MARK: Login item

    var opensAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard opensAtLogin != oldValue else { return }
            do {
                if opensAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                message = Message(text: "Open at login: \(error.localizedDescription)", failed: true)
                opensAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
}
