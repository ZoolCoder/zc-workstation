import Foundation

// The JSON that `zc-workstation status|doctor|list|plan -json` prints.

/// One target's line from `status -json`.
public struct TargetStatus: Decodable, Sendable, Equatable, Identifiable {
    public var target: String
    public var provider: String
    public var summary: String
    public var inPlace: Int
    public var declared: Int
    public var skipped: Bool?
    public var error: String?

    public var id: String { target }

    enum CodingKeys: String, CodingKey {
        case target, provider, summary, declared, skipped, error
        case inPlace = "in_place"
    }

    public init(target: String, provider: String = "", summary: String = "", inPlace: Int, declared: Int,
                skipped: Bool? = nil, error: String? = nil) {
        self.target = target
        self.provider = provider
        self.summary = summary
        self.inPlace = inPlace
        self.declared = declared
        self.skipped = skipped
        self.error = error
    }

    public var isSkipped: Bool { skipped ?? false }

    /// How many declared things are not in place; a target that cannot be
    /// read counts as one.
    public var gaps: Int {
        if isSkipped { return 0 }
        if error != nil { return 1 }
        return max(declared - inPlace, 0)
    }

    public var fraction: Double {
        declared == 0 ? (error == nil ? 1 : 0) : Double(inPlace) / Double(declared)
    }
}

/// `doctor -json`.
public struct DoctorReport: Decodable, Sendable {
    public var checks: [Check]
}

public struct Check: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var status: String
    public var detail: String?

    public var id: String { name }

    public init(name: String, status: String, detail: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
    }

    public var isOK: Bool { status == "ok" }
    public var isSecurity: Bool { name.hasPrefix("security ") }

    /// The name without the doctor's grouping prefix.
    public var title: String {
        let label = isSecurity ? String(name.dropFirst("security ".count)) : name
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

/// One target's block from `list -json`.
public struct ItemGroup: Decodable, Sendable {
    public var target: String
    public var items: [Item]?
}

public struct Item: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var kind: String
    public var state: String
    public var version: String?
    public var latest: String?
    public var desc: String?
    /// The target the item belongs to; list -json gives it per group.
    public var target: String?

    public init(name: String, kind: String, state: String, version: String? = nil, latest: String? = nil) {
        self.name = name
        self.kind = kind
        self.state = state
        self.version = version
        self.latest = latest
    }

    /// The name a plan gives the item's change, for `-only`. A runtime's
    /// change is named for the version the config asks for, which list does
    /// not give, so a runtime has none.
    public var resource: String { kind + ":" + name }
    public var planResource: String? { kind == "runtime" ? nil : resource }
    public var id: String { resource }
}

/// `plan -json`.
public struct PlanDoc: Decodable, Sendable, Equatable {
    public var changes: Int
    public var manual: Int
    public var actions: [PlanAction]

    public init(changes: Int, manual: Int, actions: [PlanAction]) {
        self.changes = changes
        self.manual = manual
        self.actions = actions
    }

    public var deletes: Bool { actions.contains { $0.op == "DELETE" } }
}

public struct PlanAction: Decodable, Sendable, Equatable, Identifiable {
    public var op: String
    public var target: String
    public var resource: String
    public var detail: String?
    public var manual: Bool?

    public init(op: String, target: String, resource: String, detail: String? = nil) {
        self.op = op
        self.target = target
        self.resource = resource
        self.detail = detail
    }

    public var id: String { op + " " + target + " " + resource }
}
