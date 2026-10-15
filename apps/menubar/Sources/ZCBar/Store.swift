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

    struct Message: Equatable {
        var text: String
        var failed: Bool
        var log: URL?
    }

    private enum Keys {
        static let config = "configPath"
        static let ignored = "ignoredChecks"
    }

    private var workstation: Workstation?
    private var env: [String: String] = [:]
    private var dashboard: Process?
    private var ticker: Task<Void, Never>?
    private let planFile = FileManager.default.temporaryDirectory.appendingPathComponent("zcbar-plan.json").path

    init() {
        ignored = Set(UserDefaults.standard.stringArray(forKey: Keys.ignored) ?? [])
    }

    var attention: Int { snapshot?.attention(ignoring: ignored) ?? 0 }
    var findings: [Check] { snapshot?.findings(ignoring: ignored) ?? [] }
    var ignoredFindings: [Check] { snapshot?.findings.filter { ignored.contains($0.name) } ?? [] }
    var configPath: String? { workstation?.config }

    // MARK: Refresh

    func start() async {
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
        snapshot = await workstation.snapshot()
        refreshedAt = .now
        refreshing = false
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

    // MARK: Changes

    /// Upgrades one package, which its Update button already asked for. A
    /// runtime cannot be picked out of a plan, so its whole target upgrades,
    /// after a confirmation that lists what.
    func update(_ item: Item) async {
        let only = item.planResource.map { [$0] } ?? []
        let targets = only.isEmpty ? [item.target].compactMap { $0 } : []
        await change("Updating \(item.name)", confirm: only.isEmpty) {
            try await $0.plan(upgrade: true, targets: targets, only: only, savingTo: self.planFile)
        }
    }

    func updateAll() async {
        await change("Updating \(snapshot?.outdated.count ?? 0) packages", confirm: true) {
            try await $0.plan(upgrade: true, savingTo: self.planFile)
        }
    }

    func apply() async {
        await change("Applying", confirm: true) { try await $0.plan(savingTo: self.planFile) }
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

    /// Plans, asks when confirm is set or the plan deletes, then applies
    /// exactly the plan that was shown.
    private func change(_ label: String, confirm: Bool, plan make: @escaping (Workstation) async throws -> PlanDoc) async {
        guard let workstation, busy == nil else { return }
        busy = label
        defer { busy = nil }
        do {
            let doc = try await make(workstation)
            let executable = doc.actions.filter { $0.manual != true }
            guard !executable.isEmpty else {
                message = Message(text: "Nothing to change.", failed: false)
                return
            }
            if confirm || doc.deletes, !Alerts.confirm(plan: doc) { return }
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

    private func lastLine(of r: CommandResult) -> String? {
        (r.output + r.stderr).split(whereSeparator: \.isNewline).last { $0.contains("fail") || $0.contains("error") }
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

    private static func isServing() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:7780/")!)
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
