import AppKit
import SwiftUI
import ZCBarCore

/// The window under the menu bar icon: coverage per target, updates, the
/// doctor's findings, and the plan, apply and dashboard actions.
struct PanelView: View {
    @Bindable var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(store: store)
            if let problem = store.setupProblem {
                SetupCard(problem: problem, choose: store.chooseConfig)
            } else if let snapshot = store.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(snapshot.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                        TargetsSection(targets: snapshot.visibleTargets) { t in
                            Task { await store.openDashboard(path: "/targets/\(t.target)") }
                        }
                        if !snapshot.outdated.isEmpty {
                            UpdatesSection(store: store, items: snapshot.outdated)
                        }
                        if !store.findings.isEmpty || !store.ignoredFindings.isEmpty {
                            FindingsSection(store: store)
                        }
                        if let plan = store.plan {
                            PlanSection(plan: plan) { store.plan = nil }
                        }
                    }
                }
                .frame(maxHeight: 520)
            } else {
                ProgressView("Reading this Mac…").frame(maxWidth: .infinity).padding()
            }
            StatusLine(store: store)
            Divider()
            Footer(store: store)
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { store.refreshIfStale() }
    }
}

private struct Header: View {
    let store: Store

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
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
                .disabled(store.setupProblem != nil)
                .help("Read this Mac again")
            }
        }
    }

    private var subtitle: String {
        if store.refreshing { return "Reading…" }
        guard let at = store.refreshedAt else { return "" }
        let n = store.attention
        let state = n == 0 ? "Everything in place" : "\(n) need\(n == 1 ? "s" : "") attention"
        return state + " · " + at.formatted(.relative(presentation: .named))
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

private struct TargetsSection: View {
    let targets: [TargetStatus]
    let open: (TargetStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Targets")
            ForEach(targets) { t in
                Button { open(t) } label: { TargetRow(target: t) }
                    .buttonStyle(.plain)
                    .help(t.error ?? t.summary)
            }
        }
    }
}

private struct TargetRow: View {
    let target: TargetStatus

    var body: some View {
        HStack(spacing: 10) {
            Text(target.target).frame(width: 80, alignment: .leading).lineLimit(1)
            ProgressView(value: target.fraction)
                .progressViewStyle(.linear)
                .tint(tint)
            Text(count).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    private var count: String {
        target.error != nil ? "error" : "\(target.inPlace)/\(target.declared)"
    }

    private var tint: Color {
        if target.error != nil { return .red }
        return target.gaps == 0 ? .green : .orange
    }
}

private struct UpdatesSection: View {
    let store: Store
    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Updates", count: items.count)
                Spacer()
                Button("Update All…") { Task { await store.updateAll() } }
                    .controlSize(.small)
                    .disabled(store.busy != nil)
            }
            ForEach(items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1)
                        Text("\(short(item.version)) → \(short(item.latest))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Update") { Task { await store.update(item) } }
                        .controlSize(.small)
                        .disabled(store.busy != nil)
                }
            }
        }
    }

    /// A cask version carries a build id after a comma, too long for a row.
    private func short(_ v: String?) -> String {
        String((v ?? "?").split(separator: ",").first ?? "?")
    }
}

private struct FindingsSection: View {
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Health", count: store.findings.count)
                Spacer()
                if !store.ignoredFindings.isEmpty {
                    Button("Show \(store.ignoredFindings.count) ignored") { store.unignoreAll() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            ForEach(store.findings) { check in
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
                    Button(fixTitle(check)) { Task { await store.fix(check) } }
                        .controlSize(.small)
                        .disabled(store.busy != nil)
                }
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
        }
    }

    private func fixTitle(_ check: Check) -> String {
        switch Fix(for: check) {
        case .command: "Fix…"
        case .settings: "Open"
        case .info: "Details"
        }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Plan") { Task { await store.showPlan() } }
                Button("Apply…") { Task { await store.apply() } }
                Spacer()
                Button("Dashboard") { Task { await store.openDashboard() } }
            }
            .disabled(store.busy != nil || store.setupProblem != nil)
            HStack {
                Toggle("Open at login", isOn: $store.opensAtLogin).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Menu {
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
}
