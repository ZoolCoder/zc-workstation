import AppKit
import SwiftUI
import ZCBarCore

/// The Care window: CleanMyMac's Smart Care, over this Mac and its
/// zc-workstation config. A sidebar of modules, glass cards, a round button.
@MainActor
final class CareWindow: NSObject, NSWindowDelegate {
    let care: Care
    private var window: NSWindow?

    init(store: Store) {
        care = Care(store: store)
    }

    func show(_ module: Care.Module? = nil) {
        if let module { care.module = module }
        let window = self.window ?? make()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if care.scannedAt == nil, !care.scanning { Task { await care.scan() } }
    }

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "ZC Care"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 600)
        let host = NSHostingController(rootView: CareView(care: care))
        // The window keeps the size its owner gives it, whatever a module holds.
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1000, height: 660))
        window.center()
        window.setFrameAutosaveName("ZCCare")
        return window
    }
}

struct CareView: View {
    @Bindable var care: Care

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(care: care)
            ZStack(alignment: .bottom) {
                Group {
                    switch care.module {
                    case .smartCare: SmartCare(care: care)
                    case .cleanup: Cleanup(care: care)
                    case .apps: Applications(care: care)
                    case .performance: Performance(care: care)
                    }
                }
                // minHeight 0: a module taller than the window must not push the window's content.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                Toast(store: care.store).padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
        .buttonStyle(PillButtonStyle())
        .background(CareBackground().ignoresSafeArea())
        .ignoresSafeArea()
    }
}

/// CleanMyMac's floor: violet at the top left, magenta at the bottom right.
private struct CareBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.24, green: 0.12, blue: 0.47),
                                    Color(red: 0.36, green: 0.13, blue: 0.50),
                                    Color(red: 0.55, green: 0.15, blue: 0.47)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.95, green: 0.35, blue: 0.75).opacity(0.35), .clear],
                           center: .bottom, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.40, green: 0.30, blue: 0.95).opacity(0.35), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 480)
        }
        .drawingGroup()
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    @Bindable var care: Care

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                BrandMark.image(size: 22).foregroundStyle(.white)
                Text("ZC Care").font(.title3.weight(.bold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 44)
            .padding(.bottom, 18)
            ForEach(Care.Module.allCases) { m in
                SidebarRow(title: m.rawValue, symbol: m.symbol, badge: badge(m), selected: care.module == m) {
                    care.module = m
                }
            }
            Spacer()
            SidebarRow(title: "Web Dashboard", symbol: "globe", badge: nil, selected: false) {
                Task { await care.store.openDashboard() }
            }
            SidebarRow(title: "Menu Panel", symbol: "menubar.rectangle", badge: nil, selected: false) {
                NSApp.sendAction(#selector(AppDelegate.showPanel), to: nil, from: nil)
            }
        }
        .padding(10)
        .padding(.bottom, 8)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.18).ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
    }

    private func badge(_ m: Care.Module) -> String? {
        guard care.scannedAt != nil else { return nil }
        switch m {
        case .smartCare: return nil
        case .cleanup: return care.junk + care.clutter > 0 ? Store.bytes(care.junk + care.clutter) : nil
        case .apps:
            let n = care.store.snapshot?.outdated.count ?? 0
            return n > 0 ? "\(n)" : nil
        case .performance: return care.startup.isEmpty ? nil : "\(care.startup.count)"
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let badge: String?
    let selected: Bool
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
                Spacer()
                if let badge { Text(badge).font(.caption).foregroundStyle(.secondary) }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(selected ? 0.16 : over ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
    }
}

// MARK: Shared pieces

/// A big glass card, as Smart Care draws its results.
private struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                                     startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.13)))
    }
}

/// The round magenta button at the bottom of Smart Care.
private struct RoundButton: View {
    let title: String
    var working = false
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.12)).frame(width: 96, height: 96)
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.85), Color(red: 0.80, green: 0.18, blue: 0.62)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 80, height: 80)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35)))
                    .shadow(color: Color(red: 1, green: 0.3, blue: 0.8).opacity(over ? 0.8 : 0.5), radius: over ? 18 : 12)
                if working {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text(title).font(.headline).foregroundStyle(.white)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
    }
}

private struct Header: View {
    let title: String
    let subtitle: String
    var busy = false
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let action { Button(action.title, action: action.run).disabled(busy) }
        }
        .padding(.top, 40)
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }
}

/// What the Store is doing, or what it last did.
private struct Toast: View {
    @Bindable var store: Store

    var body: some View {
        Group {
            if let busy = store.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy + "…")
                }
            } else if let m = store.message {
                HStack(spacing: 8) {
                    Image(systemName: m.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(m.failed ? Theme.bad : Theme.good)
                    Text(m.text).lineLimit(2)
                    Button { store.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .opacity(store.busy == nil && store.message == nil ? 0 : 1)
        .frame(maxWidth: 560)
    }
}

private func days(_ date: Date?) -> String {
    guard let date else { return "no record" }
    return date.formatted(.relative(presentation: .named))
}

// MARK: Smart Care

private struct SmartCare: View {
    @Bindable var care: Care

    var body: some View {
        VStack(spacing: 0) {
            if care.scannedAt == nil, !care.scanning {
                Welcome(care: care)
            } else {
                Header(title: "Smart Care", subtitle: care.scanning ? "Looking over your Mac…" : summary)
                HStack(spacing: 14) {
                    VStack(spacing: 14) {
                        CleanupCard(care: care)
                        PerformanceCard(care: care)
                    }
                    .frame(width: 230)
                    HealthCard(care: care)
                    VStack(spacing: 14) {
                        UpdatesCard(care: care)
                        ClutterCard(care: care)
                    }
                    .frame(width: 230)
                }
                .padding(.horizontal, 28)
                HStack(spacing: 18) {
                    RoundButton(title: care.scanning ? "" : canRun ? "Run" : "Scan",
                                working: care.scanning || care.store.busy != nil) {
                        Task { canRun ? await care.run() : await care.scan() }
                    }
                    .disabled(care.scanning || care.store.busy != nil)
                }
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
    }

    private var canRun: Bool {
        care.scannedAt != nil && (care.junk > 0 || !(care.store.snapshot?.outdated.isEmpty ?? true))
    }

    private var summary: String {
        canRun ? "Run cleans up \(Store.bytes(care.junk)) and updates \(care.store.snapshot?.outdated.count ?? 0) packages."
            : "Your Mac is in good shape."
    }
}

private struct Welcome: View {
    @Bindable var care: Care

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            HeroArt(symbol: "sparkles", colors: Tint.pink, size: 150)
            Text("Welcome to ZC Care").font(.largeTitle.weight(.bold))
            Text("Scan for junk, updates, health, startup items and big files, all at once.")
                .foregroundStyle(.secondary)
            Spacer()
            RoundButton(title: "Scan") { Task { await care.scan() } }
                .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A large glossy symbol, CleanMyMac's 3D card art.
private struct HeroArt: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [(colors.first ?? .white).opacity(0.55), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.7))
                .frame(width: size * 1.4, height: size * 1.4)
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: size * 0.28)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
                    .padding(2))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(Color.white.opacity(0.35)))
                .shadow(color: (colors.last ?? .clear).opacity(0.6), radius: size / 6, y: size / 14)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
    }
}

/// One Smart Care result: an icon, a big figure and a link to the module.
private struct ResultCard: View {
    let title: String
    let symbol: String
    let colors: [Color]
    let figure: String
    let detail: String
    var working = false
    var link: (title: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                SymbolTile(symbol: symbol, colors: colors, size: 40)
            }
            Spacer(minLength: 0)
            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking…").foregroundStyle(.secondary)
                }
            } else {
                Text(figure).font(.title.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            if let link {
                Button(link.title, action: link.run).buttonStyle(.zcLink).font(.callout.weight(.semibold))
            }
        }
        .modifier(Glass())
    }
}

private struct CleanupCard: View {
    @Bindable var care: Care

    var body: some View {
        ResultCard(title: "Cleanup", symbol: "trash.fill", colors: Tint.cyan,
                   figure: Store.bytes(care.junk), detail: "of caches, logs and build output to clear",
                   working: care.monitor.scanning,
                   link: ("Review", { care.module = .cleanup }))
    }
}

private struct ClutterCard: View {
    @Bindable var care: Care

    var body: some View {
        ResultCard(title: "My Clutter", symbol: "doc.on.doc.fill", colors: Tint.blue,
                   figure: Store.bytes(care.clutter),
                   detail: "in \(care.largeFiles.count) files over \(Store.bytes(Care.largeFile))",
                   working: care.scanningFiles,
                   link: ("Review Files", { care.module = .cleanup }))
    }
}

private struct UpdatesCard: View {
    @Bindable var care: Care

    var body: some View {
        let outdated = care.store.snapshot?.outdated.count ?? 0
        let undeclared = care.undeclared.count
        ResultCard(title: "Applications", symbol: "square.grid.2x2.fill", colors: Tint.green,
                   figure: outdated == 0 ? "Up to date" : "\(outdated) updates",
                   detail: undeclared == 0 ? "Every app is in the Brewfile" : "\(undeclared) apps not in the Brewfile",
                   working: care.store.refreshing || care.loadingApps,
                   link: ("Manage", { care.module = .apps }))
    }
}

private struct PerformanceCard: View {
    @Bindable var care: Care

    var body: some View {
        ResultCard(title: "Performance", symbol: "gauge.with.dots.needle.67percent", colors: Tint.orange,
                   figure: "\(care.startup.count) startup items",
                   detail: "\(care.background.count) background apps running",
                   link: ("Review", { care.module = .performance }))
    }
}

/// The centre card: what the doctor found, security first.
private struct HealthCard: View {
    @Bindable var care: Care

    var body: some View {
        let findings = care.store.findings
        let ok = findings.isEmpty
        VStack(spacing: 14) {
            Text("Health").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HeroArt(symbol: ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                    colors: ok ? Tint.green : Tint.pink, size: 110)
            if care.store.refreshing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking health…") }
                    .font(.title3.weight(.semibold))
            } else {
                Text(ok ? "No problems found" : "\(findings.count) to look at")
                    .font(.title2.weight(.bold))
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(findings.prefix(4)) { c in
                    HStack(spacing: 8) {
                        Circle().fill(c.isSecurity ? Theme.bad : Theme.warning).frame(width: 7, height: 7)
                        Text(c.title).font(.callout).lineLimit(1)
                        Spacer()
                        if case .info = Fix(for: c) {} else {
                            Button("Fix") { Task { await care.store.fix(c) } }
                                .controlSize(.small)
                                .help(c.detail ?? "")
                        }
                    }
                }
            }
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .modifier(Glass())
        .background(RoundedRectangle(cornerRadius: 20)
            .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.35, blue: 0.75).opacity(0.25), .clear],
                                 startPoint: .bottom, endPoint: .top)))
    }
}

// MARK: Cleanup

private struct Cleanup: View {
    @Bindable var care: Care

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Cleanup", subtitle: "\(Store.bytes(care.junk)) of junk, \(Store.bytes(care.clutter)) in large files",
                   busy: care.monitor.scanning || care.scanningFiles,
                   action: ("Rescan", { Task { async let a: Void = care.monitor.scan(); async let b: Void = care.scanFiles(); _ = await (a, b) } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Section("System Junk") {
                        ForEach(Junk.spots(home: NSHomeDirectory())) { spot in
                            Row(icon: SymbolTile(symbol: "folder.fill", colors: Tint.cyan, size: 32),
                                title: spot.title, detail: spot.detail,
                                value: care.monitor.junk[spot.id].map { Store.bytes($0) } ?? "…") {
                                Button("Clear") { Task { await care.store.clean(spot) } }
                                    .controlSize(.small)
                                    .disabled((care.monitor.junk[spot.id] ?? 0) == 0 || care.store.busy != nil)
                            }
                        }
                        Row(icon: SymbolTile(symbol: "trash.fill", colors: Tint.gray, size: 32),
                            title: "Trash", detail: "Emptied by the Finder", value: "") {
                            Button("Empty") { Task { await care.store.emptyTrash() } }.controlSize(.small)
                        }
                    }
                    Section("Large Files") {
                        if care.largeFiles.isEmpty {
                            Text(care.scanningFiles ? "Looking through your home folder…"
                                 : "No file over \(Store.bytes(Care.largeFile)) outside Library.")
                                .foregroundStyle(.secondary).padding(10)
                        }
                        ForEach(care.largeFiles) { file in
                            Row(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 32, height: 32),
                                title: file.name,
                                detail: (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                                    + (file.modified.map { " · modified " + days($0) } ?? ""),
                                value: Store.bytes(file.size)) {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .controlSize(.small)
                                .help("Show in Finder")
                                Button("Trash") { care.trash(file) }.controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.1)))
        }
    }
}

private struct Row<Icon: View, Actions: View>: View {
    let icon: Icon
    let title: String
    let detail: String
    let value: String
    var flag: String?
    @ViewBuilder let actions: Actions
    @State private var over = false

    init(icon: Icon, title: String, detail: String, value: String, flag: String? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.value = value
        self.flag = flag
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium)).lineLimit(1)
                    if let flag {
                        Text(flag).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.warning.opacity(0.25)))
                            .foregroundStyle(Theme.warning)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(over ? 0.06 : 0)))
        .onHover { over = $0 }
    }
}

// MARK: Applications

private struct Applications: View {
    @Bindable var care: Care
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable { case all = "All", undeclared = "Not in Brewfile", unused = "Unused" }

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Applications", subtitle: "\(care.apps.count) apps, \(Store.bytes(total)) in all",
                   busy: care.loadingApps, action: ("Rescan", { Task { await care.loadApps() } }))
            HStack {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                Spacer()
                let outdated = care.store.snapshot?.outdated.count ?? 0
                if outdated > 0 {
                    Button("Update \(outdated) Packages") { Task { await care.store.updateAll() } }
                        .disabled(care.store.busy != nil)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            ScrollView {
                Section(filter.rawValue) {
                    ForEach(shown) { app in
                        Row(icon: icon(app), title: app.name, detail: detail(app),
                            value: app.size.map { Store.bytes($0) } ?? "…",
                            flag: app.declared == nil ? "Not in Brewfile" : nil) {
                            Button("Uninstall") { Task { await care.uninstall(app) } }
                                .controlSize(.small)
                                .disabled(care.store.busy != nil)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }

    private var total: Int64 { care.apps.reduce(0) { $0 + ($1.size ?? 0) } }

    private var shown: [InstalledApp] {
        let list = switch filter {
        case .all: care.apps
        case .undeclared: care.undeclared
        case .unused: care.unused
        }
        return list.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    @ViewBuilder private func icon(_ app: InstalledApp) -> some View {
        if let image = care.icons[app.id] {
            Image(nsImage: image).resizable().frame(width: 34, height: 34)
        } else {
            SymbolTile(symbol: "app.fill", colors: Tint.gray, size: 32)
        }
    }

    private func detail(_ app: InstalledApp) -> String {
        let source = switch (app.source, app.declared) {
        case (_, let item?): "Brewfile · \(item.resource)"
        case (.cask(let token), nil): "Homebrew cask \(token)"
        case (.appStore, nil): "App Store"
        default: "Installed by hand"
        }
        return source + " · last used " + days(app.lastUsed)
    }
}

// MARK: Performance

private struct Performance: View {
    @Bindable var care: Care
    @State private var order = Monitor.Order.cpu

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Performance", subtitle: "\(care.startup.count) items start with your session",
                   action: ("Rescan", { Task { await care.loadAgents() } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Section("Launch Agents") {
                        ForEach(care.agents) { agent in
                            Row(icon: SymbolTile(symbol: "bolt.fill", colors: agent.enabled ? Tint.orange : Tint.gray, size: 32),
                                title: agent.label,
                                detail: (agent.program as NSString).abbreviatingWithTildeInPath,
                                value: agent.running ? "Running" : agent.runAtLoad ? "At login" : "On demand") {
                                Toggle("", isOn: Binding(get: { agent.enabled },
                                                         set: { on in Task { await care.setEnabled(agent, on) } }))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .disabled(care.store.busy != nil)
                            }
                        }
                    }
                    Section("Background Apps") {
                        if care.background.isEmpty {
                            Text("None running.").foregroundStyle(.secondary).padding(10)
                        }
                        ForEach(care.background, id: \.processIdentifier) { app in
                            Row(icon: Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 32, height: 32),
                                title: app.localizedName ?? "?", detail: app.bundleIdentifier ?? "", value: "") {
                                Button("Quit") { care.quit(app) }.controlSize(.small)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Top Processes").font(.title3.weight(.semibold))
                            Spacer()
                            Picker("", selection: $order) {
                                Text("CPU").tag(Monitor.Order.cpu)
                                Text("Memory").tag(Monitor.Order.memory)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 160)
                        }
                        VStack(spacing: 0) {
                            ForEach(care.monitor.top) { p in
                                Row(icon: SymbolTile(symbol: "cpu", colors: Tint.violet, size: 32),
                                    title: p.name, detail: "pid \(p.pid)",
                                    value: order == .cpu ? String(format: "%.0f%% CPU", p.cpu) : Store.bytes(p.memory, .memory)) {
                                    EmptyView()
                                }
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.1)))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
        // ps every three seconds while the module shows.
        .task(id: order) {
            care.monitor.order = order
            while !Task.isCancelled {
                await care.monitor.readTop()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
