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
        if !care.fresh, !care.scanning { Task { await care.scan() } }
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
                    case .clutter: Clutter(care: care)
                    case .developer: Developer(care: care)
                    case .apps: Applications(care: care)
                    case .performance: Performance(care: care)
                    case .protection: Protection(care: care)
                    case .spaceLens: SpaceLensView(care: care)
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
        case .cleanup: return care.junk > 0 ? Store.bytes(care.junk) : nil
        case .clutter: return care.clutter > 0 ? Store.bytes(care.clutter) : nil
        case .developer: return care.developer > 0 ? Store.bytes(care.developer) : nil
        case .apps:
            let n = care.store.snapshot?.outdated.count ?? 0
            return n > 0 ? "\(n)" : nil
        case .performance: return care.startup.isEmpty ? nil : "\(care.startup.count)"
        case .protection: return care.untrusted.isEmpty ? nil : "\(care.untrusted.count)"
        case .spaceLens: return care.space.map { Store.bytes($0.root.size) }
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
                   figure: care.clutter == 0 ? "All clear" : Store.bytes(care.clutter),
                   detail: care.clutter == 0 ? "No large files, duplicates, old downloads or installers" : detail,
                   working: care.scanningFiles,
                   link: ("Review Files", { care.module = .clutter }))
    }

    private var detail: String {
        [care.largeFiles.isEmpty ? nil : "\(care.largeFiles.count) large",
         care.duplicates.isEmpty ? nil : "\(care.duplicates.count) duplicated",
         care.oldDownloads.isEmpty ? nil : "\(care.oldDownloads.count) old downloads",
         care.diskImages.isEmpty ? nil : "\(care.diskImages.count) installers"]
            .compactMap { $0 }.joined(separator: ", ")
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
            Header(title: "Cleanup", subtitle: "\(Store.bytes(care.junk)) of caches, logs and build output",
                   busy: care.monitor.scanning,
                   action: ("Rescan", { Task { await care.monitor.scan() } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Section("System Junk") {
                        ForEach(Junk.spots(home: NSHomeDirectory()).filter { FileManager.default.fileExists(atPath: $0.path) }) { spot in
                            JunkRow(care: care, spot: spot)
                        }
                        Row(icon: SymbolTile(symbol: "trash.fill", colors: Tint.gray, size: 32),
                            title: "Trash", detail: "Emptied by the Finder", value: "") {
                            Button("Empty") { Task { await care.store.emptyTrash() } }.controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }
}

/// A Junk folder; its chevron opens what is inside, to clear only some.
private struct JunkRow: View {
    @Bindable var care: Care
    let spot: Junk
    @State private var open = false
    @State private var entries: [JunkEntry]?
    @State private var picked: Set<String> = []

    var body: some View {
        let size = care.monitor.junk[spot.id]
        VStack(alignment: .leading, spacing: 0) {
            Row(icon: SymbolTile(symbol: "folder.fill", colors: Tint.cyan, size: 32),
                title: spot.title, detail: spot.detail, value: size.map { Store.bytes($0) } ?? "…") {
                Button { toggle() } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }
                    .controlSize(.small)
                    .help("Choose what to clear")
                    .disabled((size ?? 0) == 0)
                Button(open ? "Clear Selected" : "Clear") { Task { await clear() } }
                    .controlSize(.small)
                    .disabled((size ?? 0) == 0 || care.store.busy != nil || (open && picked.isEmpty))
            }
            if open {
                if let entries {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries.prefix(40)) { entry in
                            Toggle(isOn: Binding(get: { picked.contains(entry.id) },
                                                 set: { on in if on { picked.insert(entry.id) } else { picked.remove(entry.id) } })) {
                                HStack {
                                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Store.bytes(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 3)
                        }
                        if entries.count > 40 {
                            Text("and \(entries.count - 40) smaller").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.leading, 56)
                    .padding(.trailing, 14)
                    .padding(.bottom, 8)
                } else {
                    ProgressView().controlSize(.small).padding(.leading, 56).padding(.bottom, 8)
                }
            }
        }
    }

    private func toggle() {
        open.toggle()
        guard open else { return }
        entries = nil
        let spot = spot
        let keep = spot.id == "caches" ? care.monitor.runningApps() : []
        Task {
            let found = await Task.detached { spot.contents(keeping: keep) }.value
            entries = found
            picked = Set(found.map(\.id))
        }
    }

    private func clear() async {
        if open, let entries {
            await care.store.clean(spot, only: entries.filter { picked.contains($0.id) })
        } else {
            await care.store.clean(spot)
        }
        open = false
    }
}

// MARK: My Clutter

private struct Clutter: View {
    @Bindable var care: Care

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "My Clutter", subtitle: care.clutter > 0 ? "\(Store.bytes(care.clutter)) in large files, duplicates, old downloads and installers"
                                                        : "No large files, duplicates, old downloads or installers",
                   busy: care.scanningFiles, action: ("Rescan", { Task { await care.scanFiles() } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Section("Large Files") {
                        if care.largeFiles.isEmpty {
                            empty("No file over \(Store.bytes(Care.largeFile)) outside Library.")
                        }
                        ForEach(care.largeFiles) { FileRow(care: care, file: $0) }
                    }
                    Section("Duplicates") {
                        if care.duplicates.isEmpty {
                            empty("No two files over \(Store.bytes(Care.duplicateFile)) hold the same bytes.")
                        }
                        ForEach(care.duplicates) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(group.files[0].name) · \(group.files.count) copies, \(Store.bytes(group.wasted)) wasted")
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                ForEach(group.files) { FileRow(care: care, file: $0, showsFolder: true) }
                            }
                        }
                    }
                    Section("Old Downloads") {
                        if care.oldDownloads.isEmpty {
                            empty("Nothing in Downloads older than 30 days.")
                        }
                        ForEach(care.oldDownloads) { FileRow(care: care, file: $0, dateLabel: "added") }
                    }
                    Section("Installers") {
                        if care.diskImages.isEmpty {
                            empty("No disk images or packages in Downloads or on the Desktop.")
                        }
                        ForEach(care.diskImages) { FileRow(care: care, file: $0, dateLabel: "added") }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(care.scanningFiles ? "Looking through your home folder…" : text)
            .foregroundStyle(.secondary).padding(10)
    }
}

private struct FileRow: View {
    @Bindable var care: Care
    let file: LargeFile
    var showsFolder = false
    var dateLabel = "modified"

    var body: some View {
        let folder = (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        Row(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 32, height: 32),
            title: showsFolder ? folder : file.name,
            detail: (showsFolder ? file.name : folder) + (file.modified.map { " · \(dateLabel) " + days($0) } ?? ""),
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

    enum Filter: String, CaseIterable { case all = "All", undeclared = "Not in Brewfile", unused = "Unused", leftovers = "Leftovers" }

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
                .frame(width: 440)
                Spacer()
                let outdated = care.store.snapshot?.outdated.count ?? 0
                if outdated > 0 {
                    Button("Update \(outdated) Packages") { Task { await care.store.updateAll() } }
                        .disabled(care.store.busy != nil)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            if filter == .leftovers {
                LeftoverList(care: care)
            } else {
            ScrollView {
                Section(filter.rawValue) {
                    ForEach(shown) { app in
                        Row(icon: icon(app), title: app.name, detail: detail(app),
                            value: app.size.map { Store.bytes($0) } ?? "…",
                            flag: app.declared == nil ? "Not in Brewfile" : nil) {
                            if app.source == .other, app.declared == nil, let token = care.casks[app.url.lastPathComponent] {
                                Button("Adopt") { Task { await care.adopt(app) } }
                                    .controlSize(.small)
                                    .help("Install as cask \(token) over this copy, and add it to the Brewfile")
                                    .disabled(care.store.busy != nil)
                            }
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
    }

    private var total: Int64 { care.apps.reduce(0) { $0 + ($1.size ?? 0) } }

    private var shown: [InstalledApp] {
        let list = switch filter {
        case .all: care.apps
        case .undeclared: care.undeclared
        case .unused: care.unused
        case .leftovers: [InstalledApp]()
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

/// What removed apps left in the Library, to pick and trash.
private struct LeftoverList: View {
    @Bindable var care: Care
    @State private var picked: Set<String> = []

    var body: some View {
        ScrollView {
            Section("Leftovers of Removed Apps") {
                if let orphans = care.orphans {
                    if orphans.isEmpty {
                        Text("No app left files behind.").foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(orphans) { o in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { picked.contains(o.id) },
                                                     set: { on in if on { picked.insert(o.id) } else { picked.remove(o.id) } }))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            Row(icon: SymbolTile(symbol: "folder.badge.questionmark", colors: Tint.gray, size: 32),
                                title: o.bundleID,
                                detail: o.paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: " · "),
                                value: Store.bytes(o.size)) {
                                Button { NSWorkspace.shared.activateFileViewerSelecting(o.paths.map(URL.init(fileURLWithPath:))) } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .controlSize(.small)
                                .help("Show in Finder")
                            }
                        }
                        .padding(.leading, 8)
                    }
                    HStack {
                        Text("Named for apps macOS no longer knows. Check before trashing: a command-line tool may still use its settings.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Move \(picked.count) to Trash") {
                            Task {
                                await care.trashOrphans(orphans.filter { picked.contains($0.id) })
                                picked.formIntersection(care.orphans?.map(\.id) ?? [])
                            }
                        }
                        .controlSize(.small)
                        .disabled(picked.isEmpty || care.store.busy != nil)
                    }
                    .padding(10)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking through the Library…").foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 70)
        }
        .task { if care.orphans == nil { await care.loadOrphans() } }
    }
}

// MARK: Developer

private struct Developer: View {
    @Bindable var care: Care
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Developer", subtitle: subtitle, busy: care.scanningDeveloper,
                   action: ("Rescan", { Task { await care.scanDeveloper() } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Section("Dependencies of Idle Projects") {
                        if care.dependencies.isEmpty {
                            Text(care.scanningDeveloper ? "Looking through your projects…"
                                 : "No project untouched for 90 days keeps its dependencies.")
                                .foregroundStyle(.secondary).padding(10)
                        }
                        ForEach(care.dependencies) { dep in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(get: { picked.contains(dep.id) },
                                                         set: { on in if on { picked.insert(dep.id) } else { picked.remove(dep.id) } }))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                Row(icon: SymbolTile(symbol: "shippingbox.fill", colors: Tint.orange, size: 32),
                                    title: dep.url.deletingLastPathComponent().lastPathComponent + "/" + dep.name,
                                    detail: (dep.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                                        + " · project changed " + days(dep.modified),
                                    value: Store.bytes(dep.size)) {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([dep.url]) } label: {
                                        Image(systemName: "magnifyingglass")
                                    }
                                    .controlSize(.small)
                                    .help("Show in Finder")
                                }
                            }
                            .padding(.leading, 8)
                        }
                        if !care.dependencies.isEmpty {
                            HStack {
                                Text("node_modules, Python virtualenvs and Rust or Maven target folders; an install brings them back.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(picked.count == care.dependencies.count ? "Select None" : "Select All") {
                                    picked = picked.count == care.dependencies.count ? [] : Set(care.dependencies.map(\.id))
                                }
                                .controlSize(.small)
                                Button("Move \(picked.count) to Trash") {
                                    Task {
                                        await care.trashDependencies(care.dependencies.filter { picked.contains($0.id) })
                                        picked.formIntersection(care.dependencies.map(\.id))
                                    }
                                }
                                .controlSize(.small)
                                .disabled(picked.isEmpty || care.store.busy != nil)
                            }
                            .padding(10)
                        }
                    }
                    Section("Local AI Models") {
                        if care.models.isEmpty {
                            Text(care.scanningDeveloper ? "Looking for models…"
                                 : "No Ollama, LM Studio or Hugging Face models on this Mac.")
                                .foregroundStyle(.secondary).padding(10)
                        }
                        ForEach(care.models) { model in
                            Row(icon: SymbolTile(symbol: "brain.fill", colors: Tint.pink, size: 32),
                                title: model.name,
                                detail: model.source.rawValue + " · downloaded " + days(model.modified),
                                value: Store.bytes(model.size)) {
                                Button { NSWorkspace.shared.activateFileViewerSelecting(model.paths) } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .controlSize(.small)
                                .help("Show in Finder")
                                Button("Trash") { Task { await care.trash(model) } }
                                    .controlSize(.small)
                                    .disabled(care.store.busy != nil)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }

    private var subtitle: String {
        care.developer > 0 ? "\(Store.bytes(care.developer)) in idle project dependencies and local AI models"
            : "Idle project dependencies and local AI models"
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
                    Section("Maintenance") {
                        ForEach(care.maintenance) { task in
                            Row(icon: SymbolTile(symbol: task.symbol, colors: Tint.violet, size: 32),
                                title: task.title, detail: task.detail, value: task.admin ? "Needs password" : "") {
                                Button("Run") { Task { await care.run(task) } }
                                    .controlSize(.small)
                                    .disabled(care.store.busy != nil)
                            }
                        }
                    }
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
        .onAppear { if care.maintenance.isEmpty { care.loadMaintenance() } }
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

// MARK: Protection

private struct Protection: View {
    @Bindable var care: Care

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Protection", subtitle: subtitle, busy: care.loadingProtection,
                   action: ("Rescan", { Task { care.assessments = [:]; await care.loadProtection() } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Section("Gatekeeper") {
                        Row(icon: SymbolTile(symbol: "checkmark.shield.fill", colors: care.gatekeeper == false ? Tint.pink : Tint.green, size: 32),
                            title: care.gatekeeper == false ? "Gatekeeper is off" : "Gatekeeper is on",
                            detail: "Only apps from identified developers open without a warning.",
                            value: care.gatekeeper == nil ? "…" : "") { EmptyView() }
                        ForEach(care.untrusted) { app in
                            Row(icon: icon(app), title: app.name,
                                detail: care.assessments[app.id]?.source ?? "No signature Gatekeeper accepts",
                                value: care.assessments[app.id]?.accepted == true ? "Not notarized" : "Rejected",
                                flag: "Unverified") {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .controlSize(.small)
                                .help("Show in Finder")
                            }
                        }
                    }
                    Section("Login Items & Background Tasks") {
                        ForEach(care.backgroundItems) { item in
                            Row(icon: SymbolTile(symbol: item.kind == "login item" ? "person.crop.circle.fill" : "gearshape.2.fill",
                                                 colors: item.enabled ? Tint.orange : Tint.gray, size: 32),
                                title: item.name,
                                detail: [item.developer ?? "Unidentified developer", item.kind, item.executable]
                                    .compactMap { $0 }.joined(separator: " · "),
                                value: item.enabled ? "Allowed" : "Off",
                                flag: item.developer == nil && item.enabled ? "Unidentified" : nil) { EmptyView() }
                        }
                        HStack {
                            Text(care.backgroundItems.isEmpty
                                 ? "macOS's list asks for your password to read. Switch items in System Settings."
                                 : "Switch these in System Settings; launch agents also in Performance.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if care.loadingBackground { ProgressView().controlSize(.small) }
                            Button(care.backgroundItems.isEmpty ? "Read List…" : "Read Again…") {
                                Task { await care.loadBackgroundItems() }
                            }
                            .controlSize(.small)
                            .disabled(care.loadingBackground)
                            Button("Open Login Items") { care.openSettings("com.apple.LoginItems-Settings.extension") }
                                .controlSize(.small)
                        }
                        .padding(10)
                    }
                    Section("Privacy Permissions") {
                        if let permissions = care.permissions {
                            if permissions.isEmpty {
                                Text("No app holds a permission.").foregroundStyle(.secondary).padding(10)
                            }
                            ForEach(permissions) { p in
                                Row(icon: SymbolTile(symbol: "hand.raised.fill", colors: p.allowed ? Tint.violet : Tint.gray, size: 32),
                                    title: p.client, detail: p.service, value: p.allowed ? "Allowed" : "Denied") { EmptyView() }
                            }
                        } else {
                            HStack(alignment: .top, spacing: 12) {
                                SymbolTile(symbol: "lock.fill", colors: Tint.gray, size: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("ZCBar needs Full Disk Access to list permissions").font(.body.weight(.medium))
                                    Text("macOS keeps its privacy database from apps without it. ZCBar is signed ad hoc, so each new build asks again.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open Settings") { care.openSettings("com.apple.preference.security?Privacy_AllFiles") }
                                    .controlSize(.small)
                            }
                            .padding(10)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
        .task { if care.gatekeeper == nil { await care.loadProtection() } }
    }

    private var subtitle: String {
        let bad = care.untrusted.count
        if care.loadingProtection { return "Asking Gatekeeper about each app…" }
        return bad > 0 ? "\(bad) apps not verified by Apple" : "Every app is verified by Apple"
    }

    @ViewBuilder private func icon(_ app: InstalledApp) -> some View {
        if let image = care.icons[app.id] {
            Image(nsImage: image).resizable().frame(width: 34, height: 34)
        } else {
            SymbolTile(symbol: "app.fill", colors: Tint.gray, size: 32)
        }
    }
}

// MARK: Space Lens

/// The home folder as rings: each ring a level down, each arc a folder's
/// share of its parent. Clicking an arc goes into it.
private struct SpaceLensView: View {
    @Bindable var care: Care
    @State private var focus: String?
    @State private var hover: SpaceNode?

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Space Lens", subtitle: subtitle, busy: care.scanningSpace,
                   action: (care.space == nil ? "Scan" : "Rescan", { Task { await care.scanSpace() } }))
            if let root = care.space?.root {
                let node = focus.flatMap(root.find) ?? root
                HStack(alignment: .top, spacing: 24) {
                    Sunburst(node: node, hover: $hover) { focus = $0.path }
                        .frame(width: 420, height: 420)
                        .overlay {
                            VStack(spacing: 4) {
                                Text((hover ?? node).name).font(.headline).lineLimit(1)
                                Text(Store.bytes((hover ?? node).size)).font(.title2.weight(.bold))
                                if node.path != root.path {
                                    Button("Back") { focus = (node.path as NSString).deletingLastPathComponent }
                                        .controlSize(.small)
                                }
                            }
                            .frame(width: 130)
                        }
                    VStack(alignment: .leading, spacing: 0) {
                        Text((node.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).padding(.bottom, 6)
                        ForEach(Array(node.children.enumerated()), id: \.element.id) { i, child in
                            Button { if !child.children.isEmpty { focus = child.path } } label: {
                                HStack {
                                    Circle().fill(Sunburst.color(i, depth: 0)).frame(width: 9, height: 9)
                                    Text(child.name).lineLimit(1)
                                    Spacer()
                                    Text(Store.bytes(child.size)).monospacedDigit().foregroundStyle(.secondary)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: child.path)]) } label: {
                                        Image(systemName: "magnifyingglass")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Show in Finder")
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 28)
            } else {
                VStack(spacing: 14) {
                    Spacer()
                    HeroArt(symbol: "chart.pie.fill", colors: Tint.blue, size: 110)
                    Text(care.scanningSpace ? "Measuring your home folder…" : "See what fills your home folder")
                        .font(.title2.weight(.bold))
                    Text("du reads every folder; it takes a few minutes, and the result is kept.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var subtitle: String {
        guard let space = care.space else { return "Folders by size, three levels down" }
        return "\(Store.bytes(space.root.size)) in your home folder, measured " + days(space.scannedAt)
    }
}

private struct Sunburst: View {
    let node: SpaceNode
    @Binding var hover: SpaceNode?
    let open: (SpaceNode) -> Void

    private struct Arc: Identifiable {
        var node: SpaceNode
        var start: Double
        var end: Double
        var depth: Int
        var color: Color
        var id: String { node.path }
    }

    static func color(_ i: Int, depth: Int) -> Color {
        Color(hue: (Double(i) * 0.13 + 0.78).truncatingRemainder(dividingBy: 1), saturation: 0.65 - Double(depth) * 0.12,
              brightness: 0.95 - Double(depth) * 0.08)
    }

    private var arcs: [Arc] {
        var out: [Arc] = []
        func walk(_ n: SpaceNode, from start: Double, span: Double, depth: Int, hue: Int?) {
            guard depth < 3, n.size > 0 else { return }
            var at = start
            for (i, child) in n.children.enumerated() {
                let share = span * Double(child.size) / Double(n.size)
                let h = hue ?? i
                out.append(Arc(node: child, start: at, end: at + share, depth: depth, color: Self.color(h, depth: depth)))
                walk(child, from: at, span: share, depth: depth + 1, hue: h)
                at += share
            }
        }
        walk(node, from: 0, span: 1, depth: 0, hue: nil)
        return out
    }

    var body: some View {
        ZStack {
            ForEach(arcs) { arc in
                Ring(start: arc.start, end: arc.end, inner: 0.34 + Double(arc.depth) * 0.22, outer: 0.34 + Double(arc.depth + 1) * 0.22 - 0.01)
                    .fill(arc.color.opacity(hover?.path == arc.node.path ? 1 : 0.82))
                    .onHover { hover = $0 ? arc.node : (hover?.path == arc.node.path ? nil : hover) }
                    .onTapGesture { if !arc.node.children.isEmpty { open(arc.node) } }
            }
        }
        .animation(.easeOut(duration: 0.25), value: node.path)
    }
}

/// A slice of a ring, as fractions of a turn and of the view's half width.
private struct Ring: Shape {
    var start: Double
    var end: Double
    var inner: Double
    var outer: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let a0 = Angle.degrees(start * 360 - 90), a1 = Angle.degrees(max(end - 0.002, start) * 360 - 90)
        var p = Path()
        p.addArc(center: c, radius: r * outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: r * inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}
