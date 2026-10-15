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
                    if care.showsIntro(care.module) {
                        ModuleIntro(care: care, module: care.module)
                    } else {
                        switch care.module {
                        case .smartCare: SmartCare(care: care)
                        case .cleanup: Cleanup(care: care)
                        case .clutter: Clutter(care: care)
                        case .developer: Developer(care: care)
                        case .apps: Applications(care: care)
                        case .performance: Performance(care: care)
                        case .protection: Protection(care: care)
                        case .spaceLens: SpaceLensView(care: care)
                        case .tools: MyTools(care: care)
                        case .activity: MyActivity(care: care)
                        }
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
        .background(CareBackground(look: care.module.look).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.35), value: care.module)
        .ignoresSafeArea()
    }
}

/// CleanMyMac's floor: each module in its own colour, darker at the top
/// left, lit from the bottom.
private struct CareBackground: View {
    let look: ModuleLook

    var body: some View {
        ZStack {
            LinearGradient(colors: look.floor, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [look.glow.opacity(0.35), .clear], center: .bottom, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [look.glow.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 480)
        }
        .drawingGroup()
    }
}

/// How a module looks: its floor, its tint and what its intro says.
struct ModuleLook {
    var floor: [Color]
    var glow: Color
    var tint: [Color]
    var title: String
    var pitch: String
    var features: [(symbol: String, title: String)]
}

extension Care.Module {
    var look: ModuleLook {
        switch self {
        case .smartCare:
            ModuleLook(floor: [rgb(0.22, 0.05, 0.36), rgb(0.42, 0.08, 0.52), rgb(0.62, 0.12, 0.58)], glow: rgb(1, 0.35, 0.8),
                       tint: Tint.pink, title: "Smart Care", pitch: "Quick maintenance that takes care of the essentials.",
                       features: [("magnifyingglass", "Junk and Clutter Scan"), ("arrow.down.circle.fill", "Homebrew Updates"),
                                  ("checkmark.shield.fill", "Health Check")])
        case .cleanup:
            ModuleLook(floor: [rgb(0.03, 0.22, 0.12), rgb(0.06, 0.36, 0.16), rgb(0.22, 0.42, 0.08)], glow: rgb(0.3, 0.9, 0.45),
                       tint: Tint.green, title: "Junk Cleanup", pitch: "Clear caches, logs and build output to win back free space.",
                       features: [("trash.fill", "System Junk"), ("brain.head.profile", "AI Clutter"),
                                  ("hammer.fill", "Developer Caches"), ("xmark.bin.fill", "Trash Bins")])
        case .protection:
            ModuleLook(floor: [rgb(0.40, 0.04, 0.32), rgb(0.58, 0.10, 0.48), rgb(0.36, 0.02, 0.22)], glow: rgb(1, 0.35, 0.75),
                       tint: Tint.pink, title: "Protection", pitch: "Check your Mac for risky settings and apps that run unseen.",
                       features: [("checkmark.shield.fill", "Security Settings"), ("gearshape.2.fill", "Background Items"),
                                  ("lock.fill", "Application Permissions")])
        case .performance:
            ModuleLook(floor: [rgb(0.62, 0.24, 0.06), rgb(0.70, 0.18, 0.08), rgb(0.42, 0.07, 0.05)], glow: rgb(1, 0.55, 0.2),
                       tint: Tint.orange, title: "Performance", pitch: "Keep your Mac in top shape with recommended maintenance.",
                       features: [("wrench.and.screwdriver.fill", "Maintenance Tasks"), ("power", "Login Items"),
                                  ("cpu", "Background Apps")])
        case .apps:
            ModuleLook(floor: [rgb(0.04, 0.10, 0.36), rgb(0.08, 0.20, 0.55), rgb(0.26, 0.14, 0.55)], glow: rgb(0.25, 0.55, 1),
                       tint: Tint.blue, title: "Applications", pitch: "Uninstall, update and adopt apps, and clear what old ones left.",
                       features: [("xmark.app.fill", "App Uninstaller"), ("arrow.up.circle.fill", "Homebrew Updater"),
                                  ("puzzlepiece.extension.fill", "File Leftovers"), ("shippingbox.fill", "Brewfile Adoption")])
        case .clutter:
            ModuleLook(floor: [rgb(0.0, 0.22, 0.26), rgb(0.02, 0.34, 0.34), rgb(0.0, 0.20, 0.28)], glow: rgb(0.15, 0.8, 0.65),
                       tint: Tint.cyan, title: "My Clutter", pitch: "Sort through your files and reduce the mess in a few clicks.",
                       features: [("folder.fill", "Large Files"), ("doc.on.doc.fill", "Duplicates"),
                                  ("arrow.down.circle.fill", "Old Downloads"), ("opticaldiscdrive.fill", "Installers")])
        case .spaceLens:
            ModuleLook(floor: [rgb(0.14, 0.04, 0.36), rgb(0.24, 0.06, 0.50), rgb(0.32, 0.10, 0.58)], glow: rgb(0.55, 0.35, 1),
                       tint: Tint.violet, title: "Space Lens", pitch: "See what fills your home folder and clear the biggest at once.",
                       features: [("chart.pie.fill", "Visual Storage Map"), ("folder.fill", "Large Folders Overview")])
        case .developer:
            ModuleLook(floor: [rgb(0.04, 0.10, 0.18), rgb(0.06, 0.20, 0.30), rgb(0.08, 0.28, 0.36)], glow: rgb(0.2, 0.75, 0.95),
                       tint: Tint.cyan, title: "Developer", pitch: "Win back what idle projects and local AI models hold.",
                       features: [("shippingbox.fill", "Idle Project Dependencies"), ("brain.fill", "Local AI Models")])
        case .tools:
            ModuleLook(floor: [rgb(0.08, 0.07, 0.20), rgb(0.16, 0.11, 0.32), rgb(0.26, 0.13, 0.40)], glow: rgb(0.6, 0.45, 1),
                       tint: Tint.violet, title: "My Tools", pitch: "Every tool in one place.", features: [])
        case .activity:
            ModuleLook(floor: [rgb(0.03, 0.08, 0.24), rgb(0.06, 0.16, 0.40), rgb(0.12, 0.10, 0.42)], glow: rgb(0.35, 0.6, 1),
                       tint: Tint.blue, title: "My Activity", pitch: "How your Mac is doing and what ZC Care did.", features: [])
        }
    }
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

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
            ForEach(Care.Module.modules) { row($0) }
            Spacer().frame(height: 14)
            ForEach(Care.Module.extras) { row($0) }
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

    private func row(_ m: Care.Module) -> some View {
        SidebarRow(title: m.rawValue, symbol: m.symbol, tint: m.look.tint, badge: badge(m), selected: care.module == m) {
            care.module = m
        }
    }

    private func badge(_ m: Care.Module) -> String? {
        guard care.scannedAt != nil else { return nil }
        switch m {
        case .smartCare, .tools: return nil
        case .activity:
            let n = care.recommendations.count
            return n > 0 ? "\(n)" : nil
        case .cleanup: return care.junk + care.ai > 0 ? Store.bytes(care.junk + care.ai) : nil
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
    var tint: [Color]?
    let badge: String?
    let selected: Bool
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if selected, let tint {
                    SymbolTile(symbol: symbol, colors: tint, size: 22).frame(width: 20)
                } else {
                    Image(systemName: symbol).frame(width: 20)
                }
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

/// The round button at the bottom of a module, in its tint.
private struct RoundButton: View {
    let title: String
    var colors = Tint.pink
    var working = false
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.12)).frame(width: 96, height: 96)
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .frame(width: 80, height: 80)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35)))
                    .shadow(color: (colors.last ?? .clear).opacity(over ? 0.8 : 0.5), radius: over ? 18 : 12)
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
                RoundButton(title: care.scanning ? "" : canRun ? "Run" : "Scan", colors: Care.Module.smartCare.look.tint,
                            working: care.scanning || care.store.busy != nil) {
                    Task { canRun ? await care.run() : await care.scan() }
                }
                .disabled(care.scanning || care.store.busy != nil)
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
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

/// A module before its scan, as CleanMyMac opens each: the art on the
/// left, what it does on the right, Scan below.
private struct ModuleIntro: View {
    @Bindable var care: Care
    let module: Care.Module

    var body: some View {
        let look = module.look
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 40) {
                GlassPlate(symbol: module.symbol, look: look)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    Text(look.title).font(.system(size: 40, weight: .regular))
                    Text(look.pitch).font(.title3).foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .padding(.bottom, 26)
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(look.features, id: \.title) { f in
                            HStack(spacing: 14) {
                                SymbolTile(symbol: f.symbol, colors: look.tint, size: 28)
                                Text(f.title).font(.headline)
                            }
                        }
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 40)
            Spacer()
            RoundButton(title: "Scan", colors: look.tint) { Task { await care.enter(module) } }
                .padding(.bottom, 36)
        }
        .id(module)
        .transition(.opacity)
    }
}

/// CleanMyMac's 3D art: a frosted plate lit in the module's colour, the
/// symbol raised on it.
private struct GlassPlate: View {
    let symbol: String
    let look: ModuleLook
    var size: CGFloat = 230

    var body: some View {
        let plate = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [look.glow.opacity(0.45), .clear], center: .center,
                                     startRadius: 0, endRadius: size * 0.75))
                .frame(width: size * 1.5, height: size * 1.5)
            plate
                .fill(LinearGradient(colors: [look.glow.opacity(0.55), (look.floor.last ?? .clear).opacity(0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(plate.fill(LinearGradient(colors: [Color.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)))
                .overlay(plate.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.6), Color.white.opacity(0.08)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 2))
                .frame(width: size, height: size)
                .rotation3DEffect(.degrees(14), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 18)
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                .shadow(color: (look.tint.last ?? .clear).opacity(0.8), radius: 12, y: 6)
        }
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
            Header(title: "Cleanup", subtitle: "Caches, logs, build output and what AI tools leave behind",
                   busy: care.monitor.scanning || care.scanningAI,
                   action: ("Rescan", { Task { await care.enter(.cleanup) } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("There are \(Store.bytes(care.junk + care.ai)) of junk files on your Mac.")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    HStack(spacing: 14) {
                        ResultCard(title: "System Junk", symbol: "trash.fill", colors: Tint.green,
                                   figure: Store.bytes(care.junk), detail: "Caches, logs and build output",
                                   working: care.monitor.scanning,
                                   link: care.junk > 0 ? ("Clean All", { Task { await care.store.cleanAll() } }) : nil)
                        ResultCard(title: "AI Clutter", symbol: "brain.head.profile", colors: Tint.violet,
                                   figure: Store.bytes(care.ai), detail: "Temp files, old versions, caches and logs of AI tools",
                                   working: care.scanningAI,
                                   link: care.ai > 0 ? ("Clean All", { Task { await care.cleanAI(care.aiJunk) } }) : nil)
                    }
                    .frame(height: 170)
                    if !care.aiJunk.isEmpty {
                        Section("AI Clutter") {
                            ForEach(aiTools, id: \.tool) { tool, junk in
                                Row(icon: AIToolIcon(tool: tool), title: tool,
                                    detail: junk.map { "\($0.kind) \(Store.bytes($0.size))" }.joined(separator: " · "),
                                    value: Store.bytes(junk.reduce(0) { $0 + $1.size })) {
                                    Button("Clear") { Task { await care.cleanAI(junk) } }
                                        .controlSize(.small)
                                        .disabled(care.store.busy != nil)
                                }
                            }
                        }
                    }
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

    /// Each tool's junk together, biggest tool first.
    private var aiTools: [(tool: String, junk: [AIJunk])] {
        Dictionary(grouping: care.aiJunk, by: \.tool)
            .map { ($0.key, $0.value) }
            .sorted { $0.1.reduce(0) { $0 + $1.size } > $1.1.reduce(0) { $0 + $1.size } }
    }
}

/// The tool's app icon when the app is installed, a symbol for the CLIs.
private struct AIToolIcon: View {
    let tool: String

    var body: some View {
        let app = "/Applications/\(tool == "Claude Code" ? "Claude" : tool).app"
        if FileManager.default.fileExists(atPath: app) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable().frame(width: 32, height: 32)
        } else {
            SymbolTile(symbol: "terminal.fill", colors: Tint.violet, size: 32)
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
                    Section("Browser Privacy") {
                        if let traces = care.browserTraces {
                            if traces.isEmpty {
                                Text("No browser keeps history, cookies or caches ZCBar can read.").foregroundStyle(.secondary).padding(10)
                            }
                            ForEach(traces) { trace in
                                let open = care.isRunning(trace.bundleID)
                                Row(icon: SymbolTile(symbol: symbol(trace.kind), colors: open ? Tint.gray : Tint.violet, size: 32),
                                    title: "\(trace.browser) \(trace.kind)",
                                    detail: open ? "Quit \(trace.browser) to clear it" : "\(trace.paths.count) items",
                                    value: Store.bytes(trace.size)) {
                                    Button("Clear") { Task { await care.clearBrowser(trace) } }
                                        .controlSize(.small)
                                        .disabled(open)
                                }
                            }
                        } else {
                            ProgressView().controlSize(.small).padding(10)
                        }
                        Text("Browsers keep history and cookies from apps without Full Disk Access; ZCBar lists what it can read. A browser clears only while it is closed.")
                            .font(.caption).foregroundStyle(.secondary).padding(10)
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

    private func symbol(_ kind: String) -> String {
        switch kind {
        case BrowserPrivacy.history: "clock.arrow.circlepath"
        case BrowserPrivacy.cookies: "birthday.cake.fill"
        default: "internaldrive.fill"
        }
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

// MARK: My Tools

private struct Tool: Identifiable {
    let title: String
    let detail: String
    let symbol: String
    let colors: [Color]
    var button = "Open"
    var isNew = false
    let run: @MainActor () -> Void
    var id: String { title }
}

/// CleanMyMac's My Tools: every tool as a card, to search and open.
private struct MyTools: View {
    @Bindable var care: Care
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "My Tools", subtitle: "Every tool in one place")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Tools", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 14)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(shown) { ToolCard(tool: $0, busy: care.store.busy != nil) }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }

    private var shown: [Tool] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? tools : tools.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
    }

    private var tools: [Tool] {
        let care = care
        let mail = Junk.spots(home: NSHomeDirectory()).first { $0.id == "mail" }
        return [
            Tool(title: "Screen Cleaning Mode", detail: "Keyboard locks and screens go black, so nothing types while you wipe.",
                 symbol: "display", colors: Tint.blue, isNew: true) { ScreenCleaner.shared.start() },
            Tool(title: "AI Clutter", detail: "Remove AI tool caches, logs, temp files and old versions you no longer need.",
                 symbol: "brain.head.profile", colors: Tint.violet, button: "Review", isNew: true) { care.open(.cleanup) },
            Tool(title: "System Junk", detail: "Clear caches, logs and build output that come back on their own.",
                 symbol: "trash.fill", colors: Tint.green, button: "Review") { care.open(.cleanup) },
            Tool(title: "Mail Attachments", detail: "Remove attachment copies Mail saved on opening; the mail keeps them.",
                 symbol: "paperclip", colors: Tint.blue, button: "Clean", isNew: true) {
                if let mail { Task { await care.store.clean(mail) } }
            },
            Tool(title: "Trash Bins", detail: "Empty the Trash for good.", symbol: "xmark.bin.fill", colors: Tint.gray,
                 button: "Empty") { Task { await care.store.emptyTrash() } },
            Tool(title: "Large and Old Files", detail: "Find big files and downloads you have not opened in months.",
                 symbol: "folder.fill", colors: Tint.cyan, button: "Review") { care.open(.clutter) },
            Tool(title: "Duplicate Finder", detail: "Find copies of the same file and keep one.",
                 symbol: "doc.on.doc.fill", colors: Tint.cyan, button: "Review") { care.open(.clutter) },
            Tool(title: "Downloads", detail: "Review one-time files and installers left in Downloads.",
                 symbol: "arrow.down.circle.fill", colors: Tint.cyan, button: "Review") { care.open(.clutter) },
            Tool(title: "Space Lens", detail: "See what fills your home folder as a map.",
                 symbol: "chart.pie.fill", colors: Tint.violet) { care.open(.spaceLens) },
            Tool(title: "App Uninstaller", detail: "Remove apps with everything they keep in the Library.",
                 symbol: "xmark.app.fill", colors: Tint.blue) { care.open(.apps) },
            Tool(title: "App Leftovers", detail: "Clear what apps you removed left behind.",
                 symbol: "puzzlepiece.extension.fill", colors: Tint.blue) { care.open(.apps) },
            Tool(title: "App Updater", detail: "Update every outdated Homebrew package.",
                 symbol: "arrow.up.circle.fill", colors: Tint.blue, button: "Update") { Task { await care.store.updateAll() } },
            Tool(title: "Maintenance Tasks", detail: "Free RAM, flush DNS, reindex Spotlight and more.",
                 symbol: "wrench.and.screwdriver.fill", colors: Tint.orange) { care.open(.performance) },
            Tool(title: "Login Items", detail: "Choose what starts with your Mac.", symbol: "power", colors: Tint.orange) { care.open(.performance) },
            Tool(title: "Time Machine Snapshots", detail: "Thin local snapshots that hold space Time Machine already backed up.",
                 symbol: "clock.arrow.circlepath", colors: Tint.orange, button: "Thin") {
                if care.maintenance.isEmpty { care.loadMaintenance() }
                if let task = care.maintenance.first(where: { $0.id == "snapshots" }) { Task { await care.run(task) } }
            },
            Tool(title: "Background Items", detail: "See what runs unseen and turn it off.",
                 symbol: "gearshape.2.fill", colors: Tint.pink) { care.open(.protection) },
            Tool(title: "Malware Finder", detail: "Check every app's signature with Gatekeeper.",
                 symbol: "ladybug.fill", colors: Tint.pink) { care.open(.protection) },
            Tool(title: "Application Permissions", detail: "Review which apps can use the camera, the screen and your files.",
                 symbol: "lock.fill", colors: Tint.pink) { care.open(.protection) },
            Tool(title: "Project Dependencies", detail: "Clear node_modules and virtualenvs of projects left alone.",
                 symbol: "shippingbox.fill", colors: Tint.cyan, button: "Review") { care.open(.developer) },
            Tool(title: "Local AI Models", detail: "Remove Ollama, LM Studio and Hugging Face models you no longer run.",
                 symbol: "brain.fill", colors: Tint.cyan, button: "Review") { care.open(.developer) },
        ]
    }
}

private struct ToolCard: View {
    let tool: Tool
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                SymbolTile(symbol: tool.symbol, colors: tool.colors, size: 44)
                Spacer()
                if tool.isNew {
                    Text("New").font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
            }
            Text(tool.title).font(.headline).padding(.top, 4)
            Text(tool.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(tool.button, action: tool.run).disabled(busy)
        }
        .frame(height: 190)
        .modifier(Glass())
    }
}

// MARK: My Activity

/// CleanMyMac's My Activity: how the Mac is, what was cleaned, what to do next.
private struct MyActivity: View {
    @Bindable var care: Care

    var body: some View {
        let log = care.store.activity
        VStack(spacing: 0) {
            Header(title: "My Activity",
                   subtitle: log.since.map { "Since \($0.formatted(date: .abbreviated, time: .omitted))" }
                       ?? "What ZC Care cleans and runs shows here")
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        MacHealth(care: care)
                        StorageCleaned(log: log)
                    }
                    .frame(height: 260)
                    HStack(alignment: .top, spacing: 14) {
                        Recommendations(care: care)
                        Recent(log: log)
                    }
                    .frame(minHeight: 280)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }
}

private struct MacHealth: View {
    @Bindable var care: Care

    var body: some View {
        let findings = care.store.findings
        let (word, color) = findings.contains(where: \.isSecurity) ? ("Needs Attention", Theme.bad)
            : findings.isEmpty ? ("Excellent", Theme.good) : ("Good", Theme.warning)
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac Health").font(.headline)
            HStack(spacing: 14) {
                HeroArt(symbol: "macbook", colors: Tint.blue, size: 70)
                VStack(alignment: .leading, spacing: 2) {
                    Text(word).font(.title.weight(.bold)).foregroundStyle(color)
                    Text(Host.current().localizedName ?? "This Mac").font(.callout)
                    Text(ProcessInfo.processInfo.operatingSystemVersionString).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let disk = care.monitor.vitals.disk {
                let used = disk.total - disk.available
                HStack {
                    Text("\(Store.bytes(used)) used of \(Store.bytes(disk.total))").font(.callout)
                    Spacer()
                    Text("\(Store.bytes(disk.available)) free").font(.callout).foregroundStyle(.secondary)
                }
                Bar(share: Double(used) / Double(max(disk.total, 1)), colors: disk.isLow ? Tint.red : Tint.blue)
            }
        }
        .modifier(Glass())
        .onAppear { care.monitor.readDisk() }
    }
}

private struct StorageCleaned: View {
    let log: ActivityLog

    var body: some View {
        let byKind = log.freedByKind
        let top = max(byKind.first?.bytes ?? 1, 1)
        VStack(alignment: .leading, spacing: 10) {
            Text("Local Storage Cleaned").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Store.bytes(log.freed)).font(.largeTitle.weight(.bold))
                let week = log.freed(lastDays: 7)
                if week > 0 { Text("+\(Store.bytes(week)) this week").font(.callout).foregroundStyle(Theme.good) }
            }
            Spacer(minLength: 0)
            if byKind.isEmpty {
                Text("Nothing cleaned yet.").foregroundStyle(.secondary)
            }
            ForEach(byKind.prefix(4), id: \.kind) { k in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(k.kind.rawValue).font(.callout)
                        Spacer()
                        Text(Store.bytes(k.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Bar(share: Double(k.bytes) / Double(top), colors: Tint.green)
                }
            }
        }
        .modifier(Glass())
    }
}

private struct Recommendations: View {
    @Bindable var care: Care

    var body: some View {
        let all = care.recommendations
        VStack(alignment: .leading, spacing: 10) {
            Text(all.isEmpty ? "No Recommendations" : "\(all.count) Recommendations").font(.headline)
            if all.isEmpty {
                Text("Your Mac is in good shape.").foregroundStyle(.secondary)
            }
            ForEach(all) { r in
                HStack(spacing: 10) {
                    SymbolTile(symbol: r.symbol, colors: r.module.look.tint, size: 28)
                    Text(r.title).font(.callout).lineLimit(1)
                    Spacer()
                    Button("Go") { care.open(r.module) }.controlSize(.small)
                }
            }
        }
        .modifier(Glass())
    }
}

private struct Recent: View {
    let log: ActivityLog

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Activity").font(.headline)
            if log.entries.isEmpty {
                Text("Clean or run a task and it shows here.").foregroundStyle(.secondary)
            }
            ForEach(Array(log.entries.suffix(8).reversed().enumerated()), id: \.offset) { _, e in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.callout).lineLimit(1)
                        Text("\(e.kind.rawValue) · \(e.date.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.bytes > 0 { Text(Store.bytes(e.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            if !log.runsByKind.isEmpty {
                Text("\(log.entries.count) cleanups and tasks in all").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .modifier(Glass())
    }
}

/// A thin rounded bar, filled to `share` in a gradient.
private struct Bar: View {
    let share: Double
    let colors: [Color]

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * min(max(share, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
