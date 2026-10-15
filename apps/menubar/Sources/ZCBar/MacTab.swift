import AppKit
import SwiftUI
import ZCBarCore

/// The Mac itself: a grade, protection, a tile for each vital, and one
/// recommendation. It samples only while it shows.
struct MacTab: View {
    @Bindable var store: Store
    let snapshot: Snapshot
    private var open: Store.MacDetail? { store.macDetail }

    private var monitor: Monitor { store.monitor }
    private var vitals: Vitals { monitor.vitals }
    private var insecure: Int { store.findings.filter(\.isSecurity).count }

    var body: some View {
        ScrollViewReader { proxy in
            content
                // An opened tile's list starts below the fold; it scrolls up.
                .onChange(of: store.macDetail) { _, detail in
                    guard detail != nil else { return }
                    withAnimation { proxy.scrollTo("detail", anchor: .top) }
                }
        }
        .onAppear { monitor.start() }
        .onDisappear {
            monitor.stop()
            store.macDetail = nil
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            hero
            ProtectionTile(store: store, security: snapshot.security, insecure: insecure)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    diskTile
                    memoryTile
                }
                GridRow {
                    if let battery = vitals.battery { batteryTile(battery) } else { Color.clear }
                    cpuTile
                }
                GridRow {
                    networkTile
                    devicesTile
                }
            }
            Group {
                switch open {
                case .disk: FreeUpList(store: store)
                case .memory: TopList(store: store, order: .memory)
                case .cpu: TopList(store: store, order: .cpu)
                case nil: EmptyView()
                }
            }
            .id("detail")
            Recommendation(advice: vitals.advice(insecure: insecure, updates: snapshot.outdated.count), act: act)
        }
    }

    private var hero: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if vitals.memory == nil {
                    Text("Mac Health: …").font(.title3.weight(.bold))
                } else {
                    let grade = vitals.grade(insecure: insecure)
                    Text("Mac Health: \(Text(grade.rawValue).foregroundStyle(color(grade)))").font(.title3.weight(.bold))
                }
                Text(monitor.model).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "laptopcomputer").font(.system(size: 30)).foregroundStyle(.teal.gradient)
        }
    }

    private var diskTile: some View {
        Tile(symbol: "internaldrive", title: vitals.disk?.name ?? "Disk", link: "Free Up", selected: open == .disk,
             action: { toggle(.disk) }) {
            if let disk = vitals.disk {
                Text("Available: \(Store.bytes(disk.available))").foregroundStyle(disk.isLow ? .orange : .secondary)
                Text("of \(Store.bytes(disk.total))")
            }
        }
    }

    private var memoryTile: some View {
        Tile(symbol: "memorychip", title: "Memory", link: "Free Up", selected: open == .memory,
             action: { toggle(.memory) }) {
            if let m = vitals.memory {
                Text("Pressure: \(m.pressure) %").foregroundStyle(m.pressure >= 75 ? .red : m.pressure >= 50 ? .orange : .secondary)
                Text("\(Store.bytes(m.used, .memory)) of \(Store.bytes(m.total, .memory)) used")
            }
        }
    }

    private func batteryTile(_ b: Battery) -> some View {
        Tile(symbol: batterySymbol(b), title: "Battery", value: Text("\(b.percent) %")) {
            Text(b.state)
            if let capacity = b.capacity {
                Text("Health \(capacity) %" + (b.cycles.map { " · \($0) cycles" } ?? ""))
                    .foregroundStyle(b.needsService ? .orange : .secondary)
            }
        }
    }

    private var cpuTile: some View {
        Tile(symbol: "cpu", title: "CPU", value: vitals.sensors.map(temperature), link: "Top Apps",
             selected: open == .cpu, action: { toggle(.cpu) }) {
            Text("Load: " + (vitals.cpuLoad.map { "\(Int(($0 * 100).rounded())) %" } ?? "…"))
            if let fans = vitals.sensors?.fans, !fans.isEmpty {
                Text("Fans: \(fans.reduce(0, +) / fans.count) rpm")
            }
        }
    }

    private var networkTile: some View {
        let net = vitals.network
        return Tile(symbol: net?.wifi == false ? "network" : "wifi", title: net.map { $0.wifi ? "Wi-Fi" : $0.interface } ?? "Network",
                    link: monitor.testingSpeed ? "Testing…" : "Test Speed",
                    action: { Task { await store.testSpeed() } }) {
            if let net {
                Label("\(Store.bytes(Int64(net.up)))/s", systemImage: "arrow.up")
                Label("\(Store.bytes(Int64(net.down)))/s", systemImage: "arrow.down")
            }
            if let s = monitor.speed {
                Text("Speed: \(mbps(s.down)) down, \(mbps(s.up)) up").foregroundStyle(.primary)
            }
        }
    }

    private var devicesTile: some View {
        Tile(symbol: "dot.radiowaves.left.and.right", title: "Devices") {
            if vitals.devices.isEmpty {
                Text("Nothing connected")
            }
            ForEach(vitals.devices) { d in
                HStack(spacing: 4) {
                    Image(systemName: deviceSymbol(d.kind)).frame(width: 14)
                    Text(d.name).lineLimit(1)
                    Spacer(minLength: 2)
                    if let battery = d.battery { Text("\(battery) %").monospacedDigit() }
                }
            }
        }
    }

    // MARK: Actions

    private func toggle(_ detail: Store.MacDetail) {
        show(open == detail ? nil : detail)
    }

    private func show(_ detail: Store.MacDetail?) {
        store.macDetail = detail
    }

    private func act(_ action: Advice.Action) {
        switch action {
        case .freeUp: show(.disk)
        case .memory: show(.memory)
        case .cpu: show(.cpu)
        case .security: store.tab = .health
        case .updates: store.tab = .updates
        case .battery:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        case .none: break
        }
    }

    // MARK: Looks

    private func color(_ grade: Grade) -> Color {
        switch grade {
        case .excellent: .teal
        case .good: .green
        case .fair: .orange
        case .poor: .red
        }
    }

    private func temperature(_ s: Sensors) -> Text {
        Text("\(Int(s.cpuTemp.rounded()))°C").foregroundStyle(s.cpuTemp >= 95 ? .red : s.cpuTemp >= 80 ? .orange : .secondary)
    }

    private func mbps(_ bits: Double) -> String { "\(Int((bits / 1_000_000).rounded())) Mbps" }

    private func batterySymbol(_ b: Battery) -> String {
        if b.charging { return "battery.100percent.bolt" }
        let level = [100, 75, 50, 25].first { b.percent >= $0 - 12 } ?? 0
        return "battery.\(level)percent"
    }

    private func deviceSymbol(_ kind: String) -> String {
        switch kind.lowercased() {
        case "headset", "headphones": "headphones"
        case "keyboard": "keyboard"
        case "mouse": "computermouse"
        case "speaker": "hifispeaker"
        default: "dot.radiowaves.right"
        }
    }
}

/// A card in the grid: a title, a value on the right, a few lines, and a
/// link that opens what it is about.
private struct Tile<Lines: View>: View {
    let symbol: String
    let title: String
    var value: Text?
    var link: String?
    var selected = false
    var action: () -> Void = {}
    @ViewBuilder let lines: Lines

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let value { value.font(.caption.monospacedDigit().weight(.semibold)) }
            }
            VStack(alignment: .leading, spacing: 2) { lines }
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let link {
                HStack {
                    Spacer()
                    Button(link, action: action).buttonStyle(.link).font(.caption.weight(.semibold))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(Card(selected: selected))
    }
}

private struct Card: ViewModifier {
    var selected = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08)))
    }
}

/// The doctor's security checks as one card; a click opens the Health tab.
private struct ProtectionTile: View {
    let store: Store
    let security: [Check]
    let insecure: Int

    var body: some View {
        let passing = security.filter(\.isOK)
        Button { store.tab = .health } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: insecure == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(insecure == 0 ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Protection").font(.callout.weight(.semibold))
                    Text("\(passing.count) of \(security.count) security checks pass")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(passing.prefix(3).map(\.title).joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Label(insecure == 0 ? "Protected" : "\(insecure) to fix",
                      systemImage: insecure == 0 ? "checkmark" : "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(insecure == 0 ? .green : .orange)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(Card())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the Health tab")
    }
}

private struct Recommendation: View {
    let advice: Advice
    let act: (Advice.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Today's Recommendation")
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(tint.gradient))
                VStack(alignment: .leading, spacing: 4) {
                    Text(advice.title).font(.callout.weight(.semibold))
                    Text(advice.body).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let button = advice.button {
                        HStack {
                            Spacer()
                            Button(button) { act(advice.action) }.controlSize(.small)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(Card())
        }
    }

    private var symbol: String {
        switch advice.action {
        case .freeUp: "internaldrive"
        case .memory: "memorychip"
        case .cpu: "thermometer.high"
        case .battery: "battery.25percent"
        case .security: "lock.shield"
        case .updates: "arrow.down.circle"
        case .none: "sparkles"
        }
    }

    private var tint: Color {
        switch advice.action {
        case .none: .teal
        case .updates: .blue
        case .security: .orange
        default: .pink
        }
    }
}

/// The folders Free Up can clear, each with its size, and the Trash.
private struct FreeUpList: View {
    let store: Store

    var body: some View {
        let spots = Junk.spots(home: NSHomeDirectory())
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionTitle(title: "Free Up")
                if let total = total(spots) {
                    Text(Store.bytes(total)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer()
                if store.monitor.scanning {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Rescan") { Task { await store.monitor.scan() } }.buttonStyle(.link).font(.caption)
                }
            }
            ForEach(spots) { spot in
                let size = store.monitor.junk[spot.id]
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(spot.title).lineLimit(1)
                        Text(spot.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(size.map { Store.bytes($0) } ?? "…").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Clear") { Task { await store.clean(spot) } }
                        .controlSize(.small)
                        .disabled(store.busy != nil || (size ?? 0) == 0)
                }
                .modifier(Hover())
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Trash")
                    Text("What is in it is deleted for good.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Empty") { Task { await store.emptyTrash() } }
                    .controlSize(.small)
                    .disabled(store.busy != nil)
            }
            .modifier(Hover())
        }
    }

    private func total(_ spots: [Junk]) -> Int64? {
        let sizes = spots.compactMap { store.monitor.junk[$0.id] }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

/// The busiest processes by memory or CPU; an app can be quit from here.
private struct TopList: View {
    let store: Store
    let order: Monitor.Order

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: order == .memory ? "Using the most memory" : "Using the most CPU")
            if store.monitor.top.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            ForEach(store.monitor.top) { proc in
                let app = NSRunningApplication(processIdentifier: proc.pid)
                HStack(spacing: 8) {
                    if let icon = app?.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 16)
                    }
                    Text(app?.localizedName ?? proc.name).lineLimit(1)
                    Spacer()
                    Text(order == .memory ? Store.bytes(proc.memory, .memory) : "\(Int(proc.cpu.rounded())) %")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let app, app.activationPolicy == .regular, app != .current {
                        Button("Quit") { store.quit(app) }.controlSize(.small)
                    }
                }
                .modifier(Hover())
            }
        }
    }
}
