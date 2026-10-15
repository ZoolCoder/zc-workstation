import Foundation

/// What files and folders take on disk.
public enum DiskUsage {
    public static func allocated(_ url: URL) -> Int64 {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        var total = Int64((try? url.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0)
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key],
                                                         errorHandler: { _, _ in true }) else { return total }
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// A big file in the home folder, for Large Files.
public struct LargeFile: Sendable, Equatable, Identifiable {
    public var url: URL
    public var size: Int64
    public var modified: Date?

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

public enum LargeFiles {
    /// The Spotlight query for files of at least `minimum` bytes: walking
    /// the home folder takes minutes, Spotlight a moment.
    public static func query(minimum: Int64) -> String { "kMDItemFSSize >= \(minimum)" }

    /// The files Spotlight found, biggest first. Library, hidden folders and
    /// app bundles are left out: what lives there belongs to apps, and
    /// Cleanup covers their caches.
    public static func files(paths: [String], home: String, minimum: Int64, limit: Int = 60) -> [LargeFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        let found = paths.compactMap { path -> LargeFile? in
            guard path.hasPrefix(home + "/") else { return nil }
            let parts = path.dropFirst(home.count + 1).split(separator: "/")
            guard parts.first != "Library", !parts.contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".app") }) else { return nil }
            let url = URL(fileURLWithPath: path)
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { return nil }
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            return size >= minimum ? LargeFile(url: url, size: size, modified: v.contentModificationDate) : nil
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }
}

/// An app in /Applications, and how it got there.
public struct InstalledApp: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        case cask(String), appStore, other
    }

    public var name: String
    public var url: URL
    public var bundleID: String?
    public var source: Source
    /// The Brewfile entry that installs it; nil when nothing declares it.
    public var declared: Item?
    public var size: Int64?
    public var lastUsed: Date?

    public init(name: String, url: URL, bundleID: String?, source: Source, declared: Item? = nil) {
        self.name = name
        self.url = url
        self.bundleID = bundleID
        self.source = source
        self.declared = declared
    }

    public var id: String { url.path }

    /// Not opened for 90 days, or never since Spotlight indexed it.
    public func unused(now: Date = .now) -> Bool {
        guard let lastUsed else { return true }
        return now.timeIntervalSince(lastUsed) > 90 * 86400
    }
}

public enum AppCatalog {
    /// `brew info --json=v2 --installed --cask`: each app bundle's cask.
    public static func caskApps(brewInfo: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: brewInfo) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [:] }
        var apps: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                for case let app as String in artifact["app"] as? [Any] ?? [] {
                    apps[app] = token
                }
            }
        }
        return apps
    }

    /// The declared item that installs the app: its cask, or the App Store
    /// app whose name it starts with, as Keynote does Keynote Creator Studio.
    public static func declared(name: String, source: InstalledApp.Source, items: [Item]) -> Item? {
        switch source {
        case .cask(let token):
            return items.first { $0.kind == "cask" && $0.name == token }
        case .appStore:
            return items.first { $0.kind == "mas" && name.hasPrefix($0.app ?? $0.name) }
        case .other:
            return nil
        }
    }

    /// Every app in the folder, sources and Brewfile entries filled in;
    /// sizes and last use are read separately, being slow.
    public static func apps(in folder: URL, caskApps: [String: String], items: [Item]) -> [InstalledApp] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "app" }.map { url in
            let file = url.lastPathComponent
            let name = url.deletingPathExtension().lastPathComponent
            let source: InstalledApp.Source
            if let token = caskApps[file] {
                source = .cask(token)
            } else if FileManager.default.fileExists(atPath: url.path + "/Contents/_MASReceipt/receipt") {
                source = .appStore
            } else {
                source = .other
            }
            return InstalledApp(name: name, url: url, bundleID: Bundle(url: url)?.bundleIdentifier, source: source,
                                declared: declared(name: name, source: source, items: items))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// What an app leaves in the Library once it is gone.
public enum Leftovers {
    public static func paths(bundleID: String?, name: String, home: String) -> [String] {
        let lib = home + "/Library/"
        var candidates = [lib + "Application Support/" + name, lib + "Logs/" + name]
        if let id = bundleID {
            candidates += [
                lib + "Application Support/" + id,
                lib + "Caches/" + id,
                lib + "Containers/" + id,
                lib + "HTTPStorages/" + id,
                lib + "WebKit/" + id,
                lib + "Logs/" + id,
                lib + "Preferences/" + id + ".plist",
                lib + "Saved Application State/" + id + ".savedState",
            ]
        }
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }
}

/// A launch agent that starts with the session: Performance lists them.
public struct LaunchAgent: Sendable, Equatable, Identifiable {
    public var label: String
    public var path: String
    public var program: String
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var enabled = true
    public var running = false

    public var id: String { label }

    /// The agent's plist, or nil when it has no label.
    public static func parse(plist: [String: Any], path: String) -> LaunchAgent? {
        guard let label = plist["Label"] as? String else { return nil }
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
        let keepAlive = plist["KeepAlive"] as? Bool ?? (plist["KeepAlive"] is [String: Any])
        var agent = LaunchAgent(label: label, path: path, program: program,
                                runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive)
        agent.enabled = !(plist["Disabled"] as? Bool ?? false)
        return agent
    }

    /// Reads every agent in the folders, one per label.
    public static func read(folders: [String]) -> [LaunchAgent] {
        var seen = Set<String>()
        var agents: [LaunchAgent] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for file in files.sorted() where file.hasSuffix(".plist") {
                let path = folder + "/" + file
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
                      let agent = parse(plist: plist, path: path), seen.insert(agent.label).inserted else { continue }
                agents.append(agent)
            }
        }
        return agents
    }
}

extension Launchd {
    /// `launchctl print-disabled`: each label launchd overrides, and whether
    /// it is disabled.
    public static func parseDisabled(_ text: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].hasPrefix("\"") else { continue }
            out[parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))] = parts[1] == "disabled" || parts[1] == "true"
        }
        return out
    }

    /// `launchctl list`: the labels with a running process.
    public static func parseRunning(_ text: String) -> Set<String> {
        var out = Set<String>()
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let f = line.split(separator: "\t")
            if f.count == 3, Int(f[0]) != nil { out.insert(String(f[2])) }
        }
        return out
    }
}
