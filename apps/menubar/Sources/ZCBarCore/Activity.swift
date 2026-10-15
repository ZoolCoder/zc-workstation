import Foundation

/// One thing ZC Care cleaned or ran, for My Activity.
public struct ActivityEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case junk = "System Junk", ai = "AI Clutter", files = "Personal Files", developer = "Developer"
        case apps = "Applications", maintenance = "Maintenance Tasks", privacy = "Browser Privacy"
    }

    public var date: Date
    public var kind: Kind
    public var title: String
    public var bytes: Int64

    public init(date: Date = .now, kind: Kind, title: String, bytes: Int64) {
        self.date = date
        self.kind = kind
        self.title = title
        self.bytes = bytes
    }
}

/// Everything ZC Care did, kept on disk, newest last.
public struct ActivityLog: Codable, Sendable, Equatable {
    public var entries: [ActivityEntry] = []

    public init(entries: [ActivityEntry] = []) {
        self.entries = entries
    }

    public var freed: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    public var since: Date? { entries.first?.date }

    /// Bytes freed by each kind, biggest first; kinds with none are left out.
    public var freedByKind: [(kind: ActivityEntry.Kind, bytes: Int64)] {
        ActivityEntry.Kind.allCases
            .map { k in (k, entries.filter { $0.kind == k }.reduce(0) { $0 + $1.bytes }) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    /// How often each kind ran, most first.
    public var runsByKind: [(kind: ActivityEntry.Kind, count: Int)] {
        ActivityEntry.Kind.allCases
            .map { k in (k, entries.filter { $0.kind == k }.count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    /// Freed in the `days` before `now`.
    public func freed(lastDays days: Int, now: Date = .now) -> Int64 {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return entries.filter { $0.date >= cutoff }.reduce(0) { $0 + $1.bytes }
    }

    public static func load(from url: URL) -> ActivityLog {
        guard let data = try? Data(contentsOf: url) else { return ActivityLog() }
        return (try? JSONDecoder().decode(ActivityLog.self, from: data)) ?? ActivityLog()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
