import Foundation

/// Where the CLI and its config are. An app opened from Finder gets launchd's
/// bare environment, not the shell's, so both are looked for.
public enum Discovery {
    /// The login shell's environment, for PATH: Homebrew, mise and the CLI
    /// live where only the shell's profile says.
    public static func loginEnvironment(runner: any Runner = ProcessRunner()) async -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"] ?? "/bin/zsh"
        guard let r = try? await runner.run(shell, ["-l", "-c", "env -0"], env: base), r.status == 0 else {
            return base
        }
        return parseEnv(r.stdout).merging(base) { login, _ in login }
    }

    static func parseEnv(_ data: Data) -> [String: String] {
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let s = String(decoding: entry, as: UTF8.self)
            if let eq = s.firstIndex(of: "=") {
                env[String(s[..<eq])] = String(s[s.index(after: eq)...])
            }
        }
        return env
    }

    /// The first zc-workstation on PATH, then where `make install` puts it.
    public static func binary(env: [String: String], home: String,
                              isExecutable: (String) -> Bool = FileManager.default.isExecutableFile) -> String? {
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + [home + "/.local/bin", "/opt/homebrew/bin"]
        return dirs.map { $0 + "/zc-workstation" }.first(where: isExecutable)
    }

    /// The config the owner chose in the app, then the CLI's own lookup:
    /// $ZC_WORKSTATION_CONFIG, then ~/.config/zc-workstation.
    public static func config(chosen: String?, env: [String: String], home: String,
                              exists: (String) -> Bool = FileManager.default.fileExists) -> String? {
        let fallback = home + "/.config/zc-workstation/zc-workstation.yaml"
        return [chosen, env["ZC_WORKSTATION_CONFIG"], fallback].compactMap { $0 }.first { !$0.isEmpty && exists($0) }
    }
}
