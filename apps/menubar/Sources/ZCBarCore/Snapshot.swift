import Foundation

/// What the menu shows: every target's coverage, pending updates, and the
/// doctor's findings, read together.
public struct Snapshot: Sendable, Equatable {
    public var targets: [TargetStatus]
    public var outdated: [Item]
    /// The doctor checks that are not ok.
    public var findings: [Check]
    /// A part that could not be read, so the rest still shows.
    public var errors: [String]

    public init(targets: [TargetStatus] = [], outdated: [Item] = [], findings: [Check] = [], errors: [String] = []) {
        self.targets = targets
        self.outdated = outdated
        self.findings = findings
        self.errors = errors
    }

    public var visibleTargets: [TargetStatus] { targets.filter { !$0.isSkipped } }

    /// The findings the owner has not chosen to ignore.
    public func findings(ignoring ignored: Set<String>) -> [Check] {
        findings.filter { !ignored.contains($0.name) }
    }

    /// The number on the menu bar icon: missing things, updates, findings.
    public func attention(ignoring ignored: Set<String>) -> Int {
        targets.map(\.gaps).reduce(0, +) + outdated.count + findings(ignoring: ignored).count + errors.count
    }
}
