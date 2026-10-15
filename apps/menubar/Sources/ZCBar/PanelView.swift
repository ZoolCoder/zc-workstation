import AppKit
import SwiftUI
import ZCBarCore

/// The panel under the bar: a tab each for coverage, updates, the doctor's
/// findings and services, with plan, apply and the dashboard below.
struct PanelView: View {
    @Bindable var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(store: store)
            if let problem = store.setupProblem {
                SetupCard(problem: problem, choose: store.chooseConfig)
            } else if let snapshot = store.snapshot {
                Tabs(store: store, snapshot: snapshot)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(snapshot.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                        switch store.tab {
                        case .overview: OverviewTab(store: store, snapshot: snapshot)
                        case .updates: UpdatesTab(store: store, items: snapshot.outdated)
                        case .health: HealthTab(store: store)
                        case .services: ServicesTab(store: store, services: snapshot.services)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 400)
            } else {
                ProgressView("Reading this Mac…").frame(maxWidth: .infinity, minHeight: 200)
            }
            StatusLine(store: store)
            Divider()
            Footer(store: store)
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { store.refreshIfStale() }
    }
}

// MARK: Frame

private struct Header: View {
    let store: Store

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("ZC Workstation").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.refreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r")
                .disabled(store.setupProblem != nil)
                .help("Read this Mac again (⌘R)")
            }
        }
    }

    private var icon: String {
        if store.setupProblem != nil { return "laptopcomputer.slash" }
        return store.attention == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        if store.setupProblem != nil { return .secondary }
        return store.attention == 0 ? .green : .orange
    }

    private var subtitle: String {
        if store.refreshing { return "Reading…" }
        guard let at = store.refreshedAt else { return "" }
        let n = store.attention
        let state = n == 0 ? "Everything in place" : "\(n) need\(n == 1 ? "s" : "") attention"
        return state + " · " + at.formatted(.relative(presentation: .named))
    }
}

/// The tab bar; each tab's count is what it holds that needs doing.
private struct Tabs: View {
    @Bindable var store: Store
    let snapshot: Snapshot

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Store.Tab.allCases, id: \.self) { tab in
                Button { store.tab = tab } label: {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if let n = count(tab), n > 0 {
                            Text("\(n)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(store.tab == tab ? Color.white.opacity(0.25) : Color.orange.opacity(0.25)))
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(store.tab == tab ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(store.tab == tab ? Color.accentColor : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    private func count(_ tab: Store.Tab) -> Int? {
        switch tab {
        case .overview: snapshot.targets.map(\.gaps).reduce(0, +)
        case .updates: snapshot.outdated.count
        case .health: store.findings.count
        case .services: snapshot.services.filter { !$0.isRunning }.count
        }
    }
}

private struct SetupCard: View {
    let problem: String
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(problem).font(.callout)
            Button("Choose Config…", action: choose)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
        }
    }
}

private struct EmptyNote: View {
    let text: String
    var symbol = "checkmark.circle"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// A row that lights up under the mouse, like a menu item.
private struct Hover: ViewModifier {
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(over ? Color.primary.opacity(0.07) : .clear))
            .onHover { over = $0 }
    }
}

// MARK: Overview

private struct OverviewTab: View {
    let store: Store
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Targets")
            ForEach(snapshot.visibleTargets) { t in
                TargetBlock(store: store, target: t)
            }
        }
        if !store.jobs.isEmpty {
            UpkeepSection(store: store)
        }
        if let plan = store.plan {
            PlanSection(plan: plan) { store.plan = nil }
        }
    }
}

/// A target's coverage bar; a click opens what is not in place.
private struct TargetBlock: View {
    let store: Store
    let target: TargetStatus

    private var open: Bool { store.expanded == target.target }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { store.toggle(target.target) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(target.target).frame(width: 74, alignment: .leading).lineLimit(1)
                    ProgressView(value: target.fraction).progressViewStyle(.linear).tint(tint)
                    Text(count).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Hover())
            .help(target.error ?? target.summary)
            if open {
                TargetDetail(store: store, target: target)
                    .padding(.leading, 22)
            }
        }
    }

    private var count: String {
        target.error != nil ? "error" : "\(target.inPlace)/\(target.declared)"
    }

    private var tint: Color {
        if target.error != nil { return .red }
        return target.gaps == 0 ? .green : .orange
    }
}

private struct TargetDetail: View {
    let store: Store
    let target: TargetStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = target.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let items = store.targetItems[target.target] {
                if items.isEmpty {
                    Text("Everything in place.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(items) { item in ItemRow(store: store, item: item) }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                if target.gaps > 0 {
                    Button("Apply \(target.target)…") { Task { await store.fixTarget(target.target) } }
                        .controlSize(.small)
                        .disabled(store.busy != nil)
                }
                Spacer()
                Button("Dashboard") { Task { await store.openDashboard(path: "/targets/\(target.target)") } }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ItemRow: View {
    let store: Store
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(item.state)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(color))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if let note = item.why ?? item.desc {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if item.isFixable {
                Button("Fix") { Task { await store.fix(item) } }
                    .controlSize(.small)
                    .disabled(store.busy != nil)
            }
        }
        .help(item.state == "manual" ? "zc-workstation cannot do this one; do it by hand." : item.name)
    }

    private var color: Color {
        switch item.state {
        case "missing": .orange
        case "differs": .yellow
        default: .secondary
        }
    }
}

/// Scheduled agents such as the weekly upkeep: when they last ran, how it
/// went, and when they run next.
private struct UpkeepSection: View {
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Upkeep")
            ForEach(store.jobs) { job in JobRow(store: store, job: job) }
        }
    }
}

private struct JobRow: View {
    let store: Store
    let job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.label.replacingOccurrences(of: "local.", with: "")).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let log = job.log {
                Button("Log") { NSWorkspace.shared.open(log) }.buttonStyle(.link).font(.caption)
            }
            Button("Run Now") { Task { await store.run(job) } }
                .controlSize(.small)
                .disabled(store.busy != nil || job.running)
        }
        .modifier(Hover())
    }

    private var symbol: String {
        if job.running { return "arrow.triangle.2.circlepath" }
        return job.failed ? "xmark.circle.fill" : "clock"
    }

    private var color: Color { job.failed ? .red : job.running ? .blue : .secondary }

    private var detail: String {
        var parts: [String] = []
        if job.running {
            parts.append("Running now")
        } else if let last = job.lastRun {
            parts.append((job.failed ? "Failed " : "Ran ") + last.formatted(.relative(presentation: .named)))
        } else {
            parts.append("Not run yet")
        }
        if let next = job.next(after: .now) {
            parts.append("next " + next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        }
        return parts.joined(separator: " · ")
    }
}

private struct PlanSection: View {
    let plan: PlanDoc
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Plan", count: plan.actions.count)
                Spacer()
                Button("Close", action: close).buttonStyle(.link).font(.caption)
            }
            if plan.actions.isEmpty {
                Text("Nothing to change.").foregroundStyle(.secondary)
            }
            ForEach(plan.actions) { a in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(a.op).font(.caption.monospaced().weight(.semibold)).foregroundStyle(color(a.op))
                        .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.resource).lineLimit(1)
                        if let d = a.detail, !d.isEmpty {
                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func color(_ op: String) -> Color {
        switch op {
        case "DELETE": .red
        case "UPDATE": .orange
        case "MANUAL": .secondary
        default: .green
        }
    }
}

// MARK: Updates

private struct UpdatesTab: View {
    let store: Store
    let items: [Item]
    @State private var filter = ""

    var body: some View {
        if items.isEmpty {
            EmptyNote(text: "Everything is up to date.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if items.count > 6 {
                        TextField("Filter", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    } else {
                        Spacer()
                    }
                    Button("Update All…") { Task { await store.updateAll() } }
                        .controlSize(.small)
                        .disabled(store.busy != nil)
                }
                ForEach(groups, id: \.0) { title, group in
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle(title: title, count: group.count)
                        ForEach(group) { item in UpdateRow(store: store, item: item) }
                    }
                }
            }
        }
    }

    /// Formulae, apps and runtimes apart: apps may ask for a password.
    private var groups: [(String, [Item])] {
        let shown = filter.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        let titles = ["brew": "Formulae", "cask": "Apps", "mas": "App Store", "runtime": "Runtimes"]
        let rank = ["brew", "cask", "mas", "runtime"]
        let kinds = Set(shown.map(\.kind)).sorted {
            (rank.firstIndex(of: $0) ?? rank.count, $0) < (rank.firstIndex(of: $1) ?? rank.count, $1)
        }
        return kinds.map { kind in (titles[kind] ?? kind.capitalized, shown.filter { $0.kind == kind }) }
    }
}

private struct UpdateRow: View {
    let store: Store
    let item: Item

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.app ?? item.name).lineLimit(1)
                Text("\(short(item.version)) → \(short(item.latest))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Update") { Task { await store.update(item) } }
                .controlSize(.small)
                .disabled(store.busy != nil)
        }
        .modifier(Hover())
        .help(item.why ?? item.name)
    }

    /// A cask version carries a build id after a comma, too long for a row.
    private func short(_ v: String?) -> String {
        String((v ?? "?").split(separator: ",").first ?? "?")
    }
}

// MARK: Health

private struct HealthTab: View {
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Findings", count: store.findings.count)
                Spacer()
                if !store.ignoredFindings.isEmpty {
                    Button("Show \(store.ignoredFindings.count) ignored") { store.unignoreAll() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if store.findings.isEmpty {
                EmptyNote(text: "Every check passes.", symbol: "checkmark.shield")
            }
            ForEach(store.findings) { check in FindingRow(store: store, check: check) }
        }
    }
}

private struct FindingRow: View {
    let store: Store
    let check: Check

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: check.status == "fail" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.status == "fail" ? .red : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title).lineLimit(1)
                if let detail = check.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button(fixTitle) { Task { await store.fix(check) } }
                .controlSize(.small)
                .disabled(store.busy != nil)
        }
        .modifier(Hover())
        .contextMenu {
            Button("Ignore") { store.ignore(check) }
            if let detail = check.detail {
                Button("Copy Fix") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                }
            }
        }
    }

    private var fixTitle: String {
        switch Fix(for: check) {
        case .command: "Fix…"
        case .settings: "Open"
        case .info: "Details"
        }
    }
}

// MARK: Services

private struct ServicesTab: View {
    let store: Store
    let services: [Item]

    var body: some View {
        if services.isEmpty {
            EmptyNote(text: "No services target in this config.", symbol: "gearshape.2")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(title: "Services", count: services.count)
                ForEach(services) { s in ServiceRow(store: store, item: s) }
            }
            if !store.jobs.isEmpty {
                UpkeepSection(store: store)
            }
        }
    }
}

private struct ServiceRow: View {
    let store: Store
    let item: Item

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(item.isRunning ? Color.green : Color.red).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text("\(item.kind == "agent" ? "launch agent" : "brew service") · \(item.desc ?? item.state)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isRunning {
                Button(restart) { Task { await store.service(item, .restart) } }
                    .controlSize(.small)
            } else {
                Button("Start") { Task { await store.service(item, .start) } }
                    .controlSize(.small)
            }
            Menu {
                if item.kind == "agent" {
                    Button("Run Now") { Task { await store.service(item, .run) } }
                }
                Button(restart) { Task { await store.service(item, .restart) } }
                Button(item.kind == "agent" ? "Unload" : "Stop") { Task { await store.service(item, .stop) } }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .disabled(store.busy != nil)
        .modifier(Hover())
    }

    /// An agent reloads rather than restarts: kickstart -k would run a
    /// calendar job such as the weekly upkeep.
    private var restart: String { item.kind == "agent" ? "Reload" : "Restart" }
}

// MARK: Bottom

private struct StatusLine: View {
    let store: Store

    var body: some View {
        if let busy = store.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(busy + "…").font(.caption)
            }
        } else if let m = store.message {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: m.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(m.failed ? .red : .green)
                Text(m.text).font(.caption).lineLimit(3)
                Spacer()
                if let log = m.log {
                    Button("Log") { NSWorkspace.shared.open(log) }.buttonStyle(.link).font(.caption)
                }
                Button { store.message = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }
}

private struct Footer: View {
    @Bindable var store: Store

    var body: some View {
        HStack {
            Group {
                Button("Plan") {
                    store.tab = .overview
                    Task { await store.showPlan() }
                }
                Button("Apply…") { Task { await store.apply() } }
                Spacer()
                Button("Dashboard") { Task { await store.openDashboard() } }
            }
            .disabled(store.busy != nil || store.setupProblem != nil)
            Menu {
                Toggle("Notifications", isOn: $store.notifies)
                Toggle("Open Panel with ⌃⌥Z", isOn: $store.hotkey)
                Toggle("Open at Login", isOn: $store.opensAtLogin)
                Divider()
                if let path = store.configPath {
                    Button("Reveal Config in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Button("Choose Config…", action: store.chooseConfig)
                Divider()
                Button("Quit ZCBar") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
