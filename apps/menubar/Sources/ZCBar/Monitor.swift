import AppKit
import Observation
import ZCBarCore

/// Samples the Mac's vitals for the Mac tab, every two seconds while it
/// shows: rates from the kernel each time, sensors every ten seconds, and
/// devices and battery health, which system_profiler is slow to give, each
/// minute. Each sample lands as one change, and only when something moved,
/// so the panel redraws at most once a tick.
@MainActor @Observable
final class Monitor {
    var vitals = Vitals()
    var model = "Mac"
    /// The busiest processes, while the memory or CPU tile is open.
    var top: [Proc] = []
    var order: Order? {
        didSet {
            guard order != oldValue else { return }
            top = []
            Task { await readTop() }
        }
    }
    var speed: SpeedTest?
    var testingSpeed = false
    /// What each Free Up folder takes, once scanned.
    var junk: [String: Int64] = [:]
    var scanning = false

    enum Order { case memory, cpu }

    private var sampler = Sampler()
    private var loop: Task<Void, Never>?
    private var tick = 0
    private let macmon = ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"].first(where: FileManager.default.isExecutableFile)

    func start() {
        guard loop == nil else { return }
        tick = 0
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func sample() async {
        var v = vitals
        if let load = sampler.cpuLoad() { v.cpuLoad = load }
        v.memory = sampler.memory()
        v.network = sampler.network()
        var battery = sampler.battery()
        battery?.health = v.battery?.health
        battery?.capacity = v.battery?.capacity
        battery?.cycles = v.battery?.cycles
        v.battery = battery
        if tick % 5 == 0 {
            v.disk = sampler.disk()
            if let macmon, let r = try? await ProcessRunner().run(macmon, ["pipe", "-s", "1", "-i", "200"], env: [:]) {
                v.sensors = Sensors.parse(macmon: r.stdout) ?? v.sensors
            }
        }
        if tick % 30 == 0 { await readSystemProfile(into: &v) }
        if v != vitals { vitals = v }
        if order != nil, tick % 2 == 1 { await readTop() }
        tick += 1
    }

    /// The model name never changes, so the hardware is read only once.
    private func readSystemProfile(into v: inout Vitals) async {
        let hardware = model == "Mac" ? ["SPHardwareDataType"] : []
        let args = ["-json"] + hardware + ["SPPowerDataType", "SPBluetoothDataType"]
        guard let r = try? await ProcessRunner().run("/usr/sbin/system_profiler", args, env: [:]) else { return }
        v.devices = Device.parse(systemProfiler: r.stdout)
        v.battery?.read(systemProfiler: r.stdout)
        guard !hardware.isEmpty else { return }
        let root = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any]
        if let name = ((root?["SPHardwareDataType"] as? [[String: Any]])?.first?["machine_name"] as? String) {
            model = name
        }
    }

    func readTop() async {
        guard let order else { return }
        let args = ["-Aceo", "pid=,pcpu=,rss=,comm=", order == .memory ? "-m" : "-r"]
        guard let r = try? await ProcessRunner().run("/bin/ps", args, env: [:]), self.order == order else { return }
        let next = Array(Proc.parse(ps: r.output).prefix(6))
        if next != top { top = next }
    }

    /// Sizes every Free Up folder at once, off the main thread: caches run
    /// to gigabytes in many small files.
    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let open = runningApps()
        await withTaskGroup(of: (String, Int64).self) { group in
            for spot in Junk.spots(home: NSHomeDirectory()) {
                let keep = spot.id == "caches" ? open : []
                group.addTask(priority: .utility) { (spot.id, spot.size(keeping: keep)) }
            }
            for await (id, size) in group { junk[id] = size }
        }
    }

    /// Open apps' bundle ids: their caches stay while they run.
    func runningApps() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func readDisk() { vitals.disk = sampler.disk() }
}

// MARK: Actions

extension Store {
    func clean(_ spot: Junk) async {
        let size = monitor.junk[spot.id] ?? 0
        guard busy == nil, Alerts.confirm("Clear \(spot.title)?",
                                          "This deletes \(Self.bytes(size)) in \(spot.path).\n\n\(spot.detail)",
                                          button: "Clear") else { return }
        busy = "Clearing \(spot.title)"
        defer { busy = nil }
        let keep = spot.id == "caches" ? monitor.runningApps() : []
        let stuck = await Task.detached { spot.empty(keeping: keep) }.value
        let left = await Task.detached { spot.size(keeping: keep) }.value
        monitor.junk[spot.id] = left
        monitor.readDisk()
        message = Message(text: "\(spot.title): freed \(Self.bytes(max(size - left, 0)))"
                          + (stuck > 0 ? "; \(stuck) in use stayed." : "."), failed: false)
    }

    /// Clears every Free Up folder after one question, for Smart Care.
    func cleanAll() async {
        let spots = Junk.spots(home: NSHomeDirectory()).filter { (monitor.junk[$0.id] ?? 0) > 0 }
        let total = spots.reduce(Int64(0)) { $0 + (monitor.junk[$1.id] ?? 0) }
        let list = spots.map { "\($0.title): \(Self.bytes(monitor.junk[$0.id] ?? 0))" }.joined(separator: "\n")
        guard busy == nil, !spots.isEmpty,
              Alerts.confirm("Clean up \(Self.bytes(total))?", list + "\n\nAll of it comes back on its own when needed.",
                             button: "Clean Up") else { return }
        busy = "Cleaning up"
        defer { busy = nil }
        let open = monitor.runningApps()
        var freed: Int64 = 0, stuck = 0
        for spot in spots {
            let keep = spot.id == "caches" ? open : []
            let size = monitor.junk[spot.id] ?? 0
            stuck += await Task.detached { spot.empty(keeping: keep) }.value
            let left = await Task.detached { spot.size(keeping: keep) }.value
            monitor.junk[spot.id] = left
            freed += max(size - left, 0)
        }
        monitor.readDisk()
        message = Message(text: "Freed \(Self.bytes(freed))" + (stuck > 0 ? "; \(stuck) in use stayed." : "."), failed: false)
    }

    /// The Finder empties the Trash: the app cannot read it without Full
    /// Disk Access. macOS asks once to let ZCBar control the Finder.
    func emptyTrash() async {
        guard busy == nil, Alerts.confirm("Empty the Trash?", "What is in the Trash is deleted for good.",
                                          button: "Empty Trash") else { return }
        busy = "Emptying the Trash"
        defer { busy = nil }
        let r = try? await ProcessRunner().run("/usr/bin/osascript", ["-e", #"tell application "Finder" to empty trash"#], env: [:])
        monitor.readDisk()
        message = r?.status == 0
            ? Message(text: "The Trash is empty.", failed: false)
            : Message(text: "Trash not emptied. \(r?.stderr ?? "")", failed: true)
    }

    func testSpeed() async {
        guard !monitor.testingSpeed else { return }
        monitor.testingSpeed = true
        defer { monitor.testingSpeed = false }
        let r = try? await ProcessRunner().run("/usr/bin/networkQuality", ["-c"], env: [:])
        guard let r, let result = SpeedTest.parse(r.stdout) else {
            message = Message(text: "Speed test failed. \(r?.stderr ?? "")", failed: true)
            return
        }
        monitor.speed = result
    }

    func quit(_ app: NSRunningApplication) {
        app.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            await monitor.readTop()
        }
    }

    static func bytes(_ n: Int64, _ style: ByteCountFormatter.CountStyle = .file) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: style)
    }
}
