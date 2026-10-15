import Foundation

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var output: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs a program; tests swap in a fake.
public protocol Runner: Sendable {
    func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult
}

public struct ProcessRunner: Runner {
    public init() {}

    public func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                p.environment = env
                p.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { return done.resume(throwing: error) }
                // Both pipes drain at once: a full one would stall the child.
                let errData = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                done.resume(returning: CommandResult(status: p.terminationStatus, stdout: outData,
                                                     stderr: String(decoding: errData.data, as: UTF8.self)))
            }
        }
    }
}

private final class Box: @unchecked Sendable {
    var data = Data()
}

public struct CLIError: LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

/// The zc-workstation CLI, run with one config.
public struct Workstation: Sendable {
    public var binary: String
    public var config: String
    public var env: [String: String]
    var runner: any Runner

    public init(binary: String, config: String, env: [String: String], runner: any Runner = ProcessRunner()) {
        self.binary = binary
        self.config = config
        self.env = env
        self.runner = runner
    }

    public func run(_ args: [String]) async throws -> CommandResult {
        var env = env
        env["ZC_WORKSTATION_CONFIG"] = config
        return try await runner.run(binary, args, env: env)
    }

    /// Runs the command and decodes its JSON. The doctor exits non-zero when
    /// a check fails, so a document on stdout counts more than the status.
    func json<T: Decodable>(_ args: [String]) async throws -> T {
        let r = try await run(args)
        if let doc = try? JSONDecoder().decode(T.self, from: r.stdout) {
            return doc
        }
        throw CLIError(message: lastLine(r.stderr) ?? "\(args[0]) exited \(r.status)")
    }

    public func status() async throws -> [TargetStatus] { try await json(["status", "-json"]) }

    public func findings() async throws -> [Check] {
        let report: DoctorReport = try await json(["doctor", "-json"])
        return report.checks.filter { !$0.isOK }
    }

    public func outdated() async throws -> [Item] {
        let groups: [ItemGroup] = try await json(["list", "-json", "-state", "outdated"])
        return groups.flatMap { g in
            (g.items ?? []).map { var i = $0; i.target = g.target; return i }
        }
    }

    /// Plans and saves the plan to file, so apply runs what was shown.
    public func plan(upgrade: Bool = false, targets: [String] = [], only: [String] = [],
                     savingTo file: String) async throws -> PlanDoc {
        var args = ["plan", "-json", "-out", file]
        if upgrade { args.append("-upgrade") }
        for t in targets { args += ["-target", t] }
        for r in only { args += ["-only", r] }
        return try await json(args)
    }

    /// Applies a saved plan. -yes: the owner confirmed the plan in the app,
    /// deletions included, and there is no terminal to ask in.
    public func apply(saved file: String) async throws -> CommandResult {
        try await run(["apply", "-yes", file])
    }

    /// Reads everything at once; a part that fails leaves an error, not a
    /// blank menu.
    public func snapshot() async -> Snapshot {
        async let t = await Result(catching: { try await status() })
        async let o = await Result(catching: { try await outdated() })
        async let f = await Result(catching: { try await findings() })
        var s = Snapshot()
        var errors: [String] = []
        switch await t {
        case .success(let v): s.targets = v
        case .failure(let e): errors.append("status: " + e.localizedDescription)
        }
        switch await o {
        case .success(let v): s.outdated = v
        case .failure(let e): errors.append("list: " + e.localizedDescription)
        }
        switch await f {
        case .success(let v): s.findings = v
        case .failure(let e): errors.append("doctor: " + e.localizedDescription)
        }
        s.errors = errors
        return s
    }
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

func lastLine(_ s: String) -> String? {
    s.split(whereSeparator: \.isNewline).last.map(String.init)
}
