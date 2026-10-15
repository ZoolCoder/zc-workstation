import Foundation

/// A folder Free Up empties: caches, build output and downloads, all of
/// which come back on their own when needed.
public struct Junk: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var path: String
    /// Entries inside the folder to leave alone.
    public var keep: Set<String> = []

    public static func spots(home: String) -> [Junk] {
        [
            Junk(id: "caches", title: "App caches", detail: "Each app rebuilds its own; open apps keep theirs.",
                 path: home + "/Library/Caches", keep: ["Homebrew"]),
            Junk(id: "homebrew", title: "Homebrew downloads", detail: "Bottles and casks already installed.",
                 path: home + "/Library/Caches/Homebrew"),
            Junk(id: "npm", title: "npm cache", detail: "Packages npm downloads again when needed.",
                 path: home + "/.npm/_cacache"),
            Junk(id: "gradle", title: "Gradle caches", detail: "The next build downloads its dependencies again.",
                 path: home + "/.gradle/caches"),
            Junk(id: "xcode", title: "Xcode build output", detail: "DerivedData, rebuilt on the next build.",
                 path: home + "/Library/Developer/Xcode/DerivedData"),
            Junk(id: "logs", title: "Logs", detail: "What apps logged; ZCBar keeps its own.",
                 path: home + "/Library/Logs", keep: ["ZCBar"]),
        ]
    }

    /// The bytes the folder's entries take on disk, less those kept.
    public func size(keeping extra: Set<String> = []) -> Int64 {
        entries(keeping: extra).reduce(0) { $0 + DiskUsage.allocated($1) }
    }

    /// Each entry and its size, biggest first, for Cleanup's preview.
    public func contents(keeping extra: Set<String> = []) -> [JunkEntry] {
        entries(keeping: extra)
            .map { JunkEntry(name: $0.lastPathComponent, size: DiskUsage.allocated($0)) }
            .sorted { $0.size > $1.size }
    }

    /// Removes every entry but those kept, or only the named ones, and
    /// returns how many would not go: some caches belong to the system.
    @discardableResult
    public func empty(keeping extra: Set<String> = [], only: Set<String>? = nil) -> Int {
        entries(keeping: extra)
            .filter { only?.contains($0.lastPathComponent) ?? true }
            .filter { (try? FileManager.default.removeItem(at: $0)) == nil }.count
    }

    private func entries(keeping extra: Set<String>) -> [URL] {
        let kept = keep.union(extra)
        let all = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                                includingPropertiesForKeys: nil)) ?? []
        return all.filter { !kept.contains($0.lastPathComponent) }
    }
}

/// One file or folder in a Junk folder.
public struct JunkEntry: Sendable, Equatable, Identifiable {
    public var name: String
    public var size: Int64

    public var id: String { name }
}
