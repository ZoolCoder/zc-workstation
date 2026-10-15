import Foundation
import Testing
@testable import ZCBarCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zcbar-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
}

@Test func largeFilesSkipLibraryHiddenAndSmallFiles() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent("Movies/big.mov"), bytes: 400_000)
    try write(home.appendingPathComponent("Downloads/mid.zip"), bytes: 200_000)
    try write(home.appendingPathComponent("Downloads/tiny.txt"), bytes: 10)
    try write(home.appendingPathComponent("Library/Caches/huge.bin"), bytes: 500_000)
    try write(home.appendingPathComponent(".cache/hidden.bin"), bytes: 500_000)
    try write(home.appendingPathComponent("Code/app/node_modules/x/bin"), bytes: 500_000)
    try write(home.appendingPathComponent("go/pkg/mod/m@v1/big.db"), bytes: 500_000)

    let paths = ["Movies/big.mov", "Downloads/mid.zip", "Downloads/tiny.txt", "Library/Caches/huge.bin",
                 ".cache/hidden.bin", "Code/app/node_modules/x/bin", "go/pkg/mod/m@v1/big.db",
                 "Gone/missing.bin"].map { home.path + "/" + $0 } + ["/elsewhere/x.bin"]
    let found = LargeFiles.files(paths: paths, home: home.path, minimum: 100_000)

    #expect(found.map(\.name) == ["big.mov", "mid.zip"])
}

@Test func caskAppsMapsBundlesToTokens() {
    let json = """
    {"casks":[{"token":"visual-studio-code","artifacts":[{"uninstall":[{"quit":"com.microsoft.VSCode"}]},
      {"app":["Visual Studio Code.app"],"target":"/Applications/Visual Studio Code.app"}]},
     {"token":"font-x","artifacts":[{"font":["x.ttf"]}]}]}
    """
    #expect(AppCatalog.caskApps(brewInfo: Data(json.utf8)) == ["Visual Studio Code.app": "visual-studio-code"])
}

@Test func declaredMatchesCaskTokenAndAppStorePrefix() {
    var keynote = Item(name: "Keynote", kind: "mas", state: "in place")
    keynote.app = "Keynote"
    let code = Item(name: "visual-studio-code", kind: "cask", state: "in place")
    let items = [keynote, code]

    #expect(AppCatalog.declared(name: "Visual Studio Code", source: .cask("visual-studio-code"), items: items) == code)
    #expect(AppCatalog.declared(name: "Keynote Creator Studio", source: .appStore, items: items) == keynote)
    #expect(AppCatalog.declared(name: "AnyDesk", source: .cask("anydesk"), items: items) == nil)
    #expect(AppCatalog.declared(name: "Keynote", source: .other, items: items) == nil)
}

@Test func leftoversListOnlyWhatExists() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent("Library/Caches/com.x.app/c"), bytes: 1)
    try write(home.appendingPathComponent("Library/Preferences/com.x.app.plist"), bytes: 1)
    try write(home.appendingPathComponent("Library/Application Support/X/data"), bytes: 1)

    let found = Leftovers.paths(bundleID: "com.x.app", name: "X", home: home.path)

    #expect(Set(found.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["X", "com.x.app", "com.x.app.plist"])
}

@Test func unusedAfterNinetyDaysOrNever() {
    var app = InstalledApp(name: "X", url: URL(fileURLWithPath: "/Applications/X.app"), bundleID: nil, source: .other)
    #expect(app.unused())
    app.lastUsed = .now.addingTimeInterval(-10 * 86400)
    #expect(!app.unused())
    app.lastUsed = .now.addingTimeInterval(-100 * 86400)
    #expect(app.unused())
}

@Test func launchAgentParsesProgramAndFlags() {
    let agent = LaunchAgent.parse(plist: ["Label": "sh.brew.borders", "ProgramArguments": ["/opt/homebrew/bin/borders", "-x"],
                                          "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "Disabled": true],
                                  path: "/p.plist")
    #expect(agent?.program == "/opt/homebrew/bin/borders")
    #expect(agent?.runAtLoad == true)
    #expect(agent?.keepAlive == true)
    #expect(agent?.enabled == false)
    #expect(LaunchAgent.parse(plist: ["Program": "/x"], path: "/p.plist") == nil)
}

@Test func launchctlDisabledAndRunning() {
    let disabled = """
    \tdisabled services = {
    \t\t"com.docker.helper" => enabled
    \t\t"com.apple.enrollagent" => disabled
    \t}
    """
    #expect(Launchd.parseDisabled(disabled) == ["com.docker.helper": false, "com.apple.enrollagent": true])
    let list = "PID\tStatus\tLabel\n-\t0\tcom.apple.idle\n2269\t0\tcom.apple.progressd\n"
    #expect(Launchd.parseRunning(list) == ["com.apple.progressd"])
}

@Test func careScanRoundTripsThroughDisk() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var app = InstalledApp(name: "Ghostty", url: URL(fileURLWithPath: "/Applications/Ghostty.app"), bundleID: "com.mitchellh.ghostty",
                           source: .cask("ghostty"), declared: Item(name: "ghostty", kind: "cask", state: "ok"))
    app.size = 120
    let agent = LaunchAgent(label: "local.x", path: "/p.plist", program: "/bin/sh", runAtLoad: true, keepAlive: false)
    let scan = CareScan(scannedAt: Date(timeIntervalSince1970: 1_700_000_000), junk: ["caches": 42],
                        largeFiles: [LargeFile(url: URL(fileURLWithPath: "/tmp/big.mov"), size: 9, modified: nil)],
                        apps: [app], agents: [agent])
    let url = dir.appendingPathComponent("sub/care.json")

    try scan.save(to: url)

    #expect(CareScan.load(from: url) == scan)
    #expect(CareScan.load(from: dir.appendingPathComponent("none.json")) == nil)
}

@Test func duplicatesGroupSameBytesOnly() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent("Downloads/a.zip"), bytes: 300_000)
    try write(home.appendingPathComponent("Documents/a copy.zip"), bytes: 300_000)
    try write(home.appendingPathComponent("Movies/b.mov"), bytes: 300_000)
    try Data(repeating: 9, count: 300_000).write(to: home.appendingPathComponent("Movies/b.mov"))
    try write(home.appendingPathComponent("Movies/c.mov"), bytes: 200_000)

    let paths = ["Downloads/a.zip", "Documents/a copy.zip", "Movies/b.mov", "Movies/c.mov"].map { home.path + "/" + $0 }
    let groups = Duplicates.groups(paths: paths, home: home.path, minimum: 100_000)

    #expect(groups.count == 1)
    #expect(Set(groups[0].files.map(\.name)) == ["a.zip", "a copy.zip"])
    #expect(groups[0].wasted == 300_000)
}

@Test func oldDownloadsGoByAge() throws {
    let folder = try tempDir()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(folder.appendingPathComponent("old.dmg"), bytes: 1000)
    try write(folder.appendingPathComponent("new.dmg"), bytes: 1000)
    try write(folder.appendingPathComponent(".hidden"), bytes: 1000)

    let later = Date.now.addingTimeInterval(31 * 86400)
    #expect(OldDownloads.files(in: folder, now: .now).isEmpty)
    #expect(Set(OldDownloads.files(in: folder, now: later).map(\.name)) == ["old.dmg", "new.dmg"])
}

@Test func junkEmptiesOnlyThePickedEntries() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(dir.appendingPathComponent("a/x.bin"), bytes: 50_000)
    try write(dir.appendingPathComponent("b.bin"), bytes: 10_000)
    try write(dir.appendingPathComponent("kept/y.bin"), bytes: 10_000)
    let spot = Junk(id: "t", title: "T", detail: "", path: dir.path, keep: ["kept"])

    #expect(spot.contents().map(\.name) == ["a", "b.bin"])
    spot.empty(only: ["b.bin"])
    #expect(spot.contents().map(\.name) == ["a"])
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("kept/y.bin").path))
}

@Test func backgroundItemsReadTheUsersRunningRecords() {
    let dump = """
     Records for UID 501 : X
     Items:
     #1:
                     Name: (null)
                     Type: developer (0x20)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: Unknown Developer
     #2:
                     Name: CleanMyMac Menu
           Developer Name: MacPaw Way Ltd
                     Type: login item (0x4)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 4.com.macpaw.CleanMyMac5.Menu
        Parent Identifier: 2.com.macpaw.CleanMyMac5
     #3:
                     Name: GoogleUpdater
                     Type: legacy agent (0x10008)
              Disposition: [disabled, allowed, notified] (0xa)
               Identifier: 8.com.google.GoogleUpdater.wake
          Executable Path: /x/GoogleUpdater
     Records for UID 502 : Y
     #1:
                     Name: Other
                     Type: login item (0x4)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 4.other
    """
    let items = BackgroundItems.parse(dump, uid: 501)

    #expect(items.map(\.name) == ["CleanMyMac Menu", "GoogleUpdater"])
    #expect(items[0].enabled && items[0].developer == "MacPaw Way Ltd" && items[0].parent == "2.com.macpaw.CleanMyMac5")
    #expect(!items[1].enabled && items[1].kind == "legacy agent" && items[1].executable == "/x/GoogleUpdater")
}

@Test func gatekeeperAssessment() {
    let ok = Assessment.parse("/Applications/A.app: accepted\nsource=Notarized Developer ID\n")
    let bad = Assessment.parse("/Applications/B.app: rejected\nsource=no usable signature\n")
    let adhoc = Assessment.parse("/Applications/C.app: accepted\nsource=Unnotarized Developer ID\n")

    #expect(ok.trusted && ok.source == "Notarized Developer ID")
    #expect(!bad.accepted && !bad.trusted)
    #expect(adhoc.accepted && !adhoc.trusted)
}

@Test func privacyRowsKeepKnownServices() {
    let rows = Privacy.parse("""
    kTCCServiceCamera|us.zoom.xos|2
    kTCCServiceMicrophone|us.zoom.xos|0
    kTCCServiceUbiquity|com.apple.x|2
    kTCCServiceCamera|us.zoom.xos|2
    """)

    #expect(rows == [Permission(service: "Camera", client: "us.zoom.xos", allowed: true),
                     Permission(service: "Microphone", client: "us.zoom.xos", allowed: false)])
}

@Test func spaceLensBuildsATreeOfTheBiggest() {
    let du = """
    10\t/h/a/tiny
    4000\t/h/a/big
    5000\t/h/a
    3000\t/h/b
    9000\t/h
    """
    let root = SpaceLens.parse(du: du, root: "/h")

    #expect(root?.size == Int64(9000 * 1024))
    #expect(root?.children.map(\.name) == ["a", "b"])
    #expect(root?.find("/h/a")?.children.map(\.name) == ["big"])
    #expect(SpaceLens.parse(du: du, root: "/elsewhere") == nil)
}

@Test func uninstallRoutes() {
    var item = Item(name: "raycast", kind: "cask", state: "ok")
    item.target = "apps"

    #expect(Uninstall.method(declared: item, source: .cask("raycast")) == .remove(target: "apps", resource: "cask:raycast"))
    #expect(Uninstall.method(declared: nil, source: .cask("zoom")) == .cask("zoom"))
    #expect(Uninstall.method(declared: nil, source: .appStore) == .trash)
    #expect(Uninstall.method(declared: nil, source: .other) == .trash)
}

@Test func launchdToggleSteps() {
    let off = Launchd.toggleSteps(domain: "gui/501", label: "a.b", plist: "/p.plist", on: false)
    let on = Launchd.toggleSteps(domain: "gui/501", label: "a.b", plist: "/p.plist", on: true)

    #expect(off == [["bootout", "gui/501/a.b"], ["disable", "gui/501/a.b"]])
    #expect(on == [["enable", "gui/501/a.b"], ["bootstrap", "gui/501", "/p.plist"]])
    #expect(off.map(Launchd.mustSucceed) == [false, true])
    #expect(on.map(Launchd.mustSucceed) == [true, false])
}

@Test func careScheduleAndAlerts() {
    let now = Date.now
    #expect(CareSchedule.due(last: nil, now: now))
    #expect(!CareSchedule.due(last: now.addingTimeInterval(-6 * 86400), now: now))
    #expect(CareSchedule.due(last: now.addingTimeInterval(-7 * 86400), now: now))

    #expect(CareSchedule.alerts(junk: 1024, outdated: 0, findings: 0).isEmpty)
    let alerts = CareSchedule.alerts(junk: 3 * 1024 * 1024 * 1024, outdated: 2, findings: 1)
    #expect(alerts.map(\.id) == ["care junk", "care updates", "care health"])
    #expect(alerts.allSatisfy { $0.id.hasPrefix("care") })
}

@Test func caskIndexMapsAppsToCasks() throws {
    let payload = #"{"casks":{"raycast":{"raw_artifacts":[[":uninstall",{":quit":"x"}],[":app",["Raycast.app"]]]},"#
        + #""zoom":{"raw_artifacts":[[":pkg",["zoom.pkg"]]]},"vscode":{"raw_artifacts":[[":app",["Visual Studio Code.app",{"target":"x"}]]]}}}"#
    let jws = try JSONSerialization.data(withJSONObject: ["payload": payload, "signature": "s"])

    #expect(CaskIndex.apps(jws: jws) == ["Raycast.app": "raycast", "Visual Studio Code.app": "vscode"])

    var a = Item(name: "a", kind: "cask", state: "ok"); a.target = "apps"
    var b = Item(name: "b", kind: "cask", state: "ok"); b.target = "apps"
    var c = Item(name: "c", kind: "cask", state: "ok"); c.target = "dev"
    var d = Item(name: "d", kind: "brew", state: "ok"); d.target = "dev"
    #expect(CaskIndex.target(items: [a, b, c, d]) == "apps")
    #expect(CaskIndex.target(items: [d]) == nil)
}

@Test func idleProjectDependenciesOnly() throws {
    let root = try tempDir()
    let old = Date.now.addingTimeInterval(-200 * 86400)
    try write(root.appendingPathComponent("idle/node_modules/a/index.js"), bytes: 4096)
    try write(root.appendingPathComponent("idle/package.json"), bytes: 10)
    try write(root.appendingPathComponent("busy/node_modules/b/index.js"), bytes: 4096)
    try write(root.appendingPathComponent("busy/package.json"), bytes: 10)
    try write(root.appendingPathComponent("rusty/target/debug/x"), bytes: 4096)
    try write(root.appendingPathComponent("rusty/Cargo.toml"), bytes: 10)
    try write(root.appendingPathComponent("plain/target/x"), bytes: 4096)
    try write(root.appendingPathComponent("plain/notes.txt"), bytes: 10)
    for path in ["idle/package.json", "rusty/Cargo.toml", "plain/notes.txt"] {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(path).path)
    }
    let found = ProjectDependencies.find(roots: [root]).map { $0.url.pathComponents.suffix(2).joined(separator: "/") }
    #expect(Set(found) == ["idle/node_modules", "rusty/target"])
}

@Test func ollamaModelsKeepSharedBlobs() throws {
    let root = try tempDir()
    func manifest(_ path: String, _ digests: [String]) throws {
        let layers = digests.map { "{\"digest\":\"\($0)\",\"size\":100}" }.joined(separator: ",")
        let url = root.appendingPathComponent("manifests/registry.ollama.ai/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"layers\":[\(layers)]}".utf8).write(to: url)
    }
    try manifest("library/llama3/latest", ["sha256:aa", "sha256:shared"])
    try manifest("someone/coder/7b", ["sha256:bb", "sha256:shared"])
    let models = AIModels.ollama(root: root).sorted { $0.name < $1.name }
    #expect(models.map(\.name) == ["llama3:latest", "someone/coder:7b"])
    #expect(models[0].size == 200)
    #expect(models[0].paths.map(\.lastPathComponent) == ["latest", "sha256-aa"])
}

@Test func huggingFaceFoldersNameModels() throws {
    let hub = try tempDir()
    try write(hub.appendingPathComponent("models--org--tiny-model/blobs/x"), bytes: 4096)
    try write(hub.appendingPathComponent("datasets--org--set/blobs/x"), bytes: 4096)
    #expect(AIModels.huggingFace(hub: hub).map(\.name) == ["org/tiny-model"])
}

@Test func diskImagesByExtension() throws {
    let dir = try tempDir()
    try write(dir.appendingPathComponent("App.dmg"), bytes: 4096)
    try write(dir.appendingPathComponent("Tool.PKG"), bytes: 8192)
    try write(dir.appendingPathComponent("notes.txt"), bytes: 4096)
    #expect(DiskImages.files(in: [dir]).map(\.name) == ["Tool.PKG", "App.dmg"])
}

@Test func orphansSkipInstalledAppleAndHelpers() throws {
    let home = try tempDir()
    try write(home.appendingPathComponent("Library/Caches/com.gone.app/x"), bytes: 4096)
    try write(home.appendingPathComponent("Library/Preferences/com.gone.app.plist"), bytes: 10)
    try write(home.appendingPathComponent("Library/Caches/com.here.app.helper/x"), bytes: 10)
    try write(home.appendingPathComponent("Library/Caches/com.apple.Safari/x"), bytes: 10)
    try write(home.appendingPathComponent("Library/Caches/Firefox/x"), bytes: 10)
    let orphans = Leftovers.orphans(home: home.path) { $0 == "com.here.app" }
    #expect(orphans.map(\.bundleID) == ["com.gone.app"])
    #expect(orphans[0].paths.count == 2)
    #expect(Leftovers.bundleID("Some.Thing.app") == nil)
    #expect(Leftovers.bundleID("org.x.y.savedState") == "org.x.y")
}

@Test func maintenanceQuotesAdminSteps() {
    let script = Maintenance.adminScript([["/usr/bin/killall", "-HUP", "it's"], ["/bin/echo", "a \"b\""]])
    #expect(script == #"do shell script "'/usr/bin/killall' '-HUP' 'it'\\''s' && '/bin/echo' 'a \"b\"'" with administrator privileges"#)
    #expect(Maintenance.tasks(brew: nil, docker: nil, xcode: false).allSatisfy { $0.id != "brew" && $0.id != "docker" })
    #expect(Maintenance.tasks(brew: "/b", docker: "/d", xcode: true).contains { $0.id == "docker" })
}

@Test func devCachesStayOutOfAppCaches() {
    let spots = Junk.spots(home: "/h")
    let caches = spots.first { $0.id == "caches" }!
    for spot in spots where spot.path.hasPrefix("/h/Library/Caches/") {
        #expect(caches.keep.contains((spot.path as NSString).lastPathComponent))
    }
}

@Test func aiClutterFindsJunkAndKeepsTheRunningVersion() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let versions = home.appendingPathComponent(".local/share/claude/versions")
    try write(versions.appendingPathComponent("2.1.0"), bytes: 300_000)
    try write(versions.appendingPathComponent("2.2.0"), bytes: 200_000)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: home.path + "/.local/bin/claude", withDestinationPath: versions.path + "/2.2.0")
    let temp = home.appendingPathComponent("tmp/claude-501")
    try write(temp.appendingPathComponent("old/x"), bytes: 100_000)
    try write(temp.appendingPathComponent("busy/x"), bytes: 100_000)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86400)],
                                          ofItemAtPath: temp.appendingPathComponent("old").path)
    try write(home.appendingPathComponent("Library/Application Support/Cursor/Cache/a"), bytes: 50_000)
    try write(home.appendingPathComponent("Library/Application Support/Cursor/User/settings.json"), bytes: 50_000)

    let found = AIClutter.find(home: home.path, claudeTemp: temp.path)

    #expect(found.map(\.id) == ["Claude Code Stale Versions", "Claude Code Temp Files", "Cursor Caches"])
    #expect(found[0].paths.map(\.lastPathComponent) == ["2.1.0"])
    #expect(found[1].paths.map(\.lastPathComponent) == ["old"])
}

@Test func aiClutterCallsNoVersionStaleWithoutTheLink() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent(".local/share/claude/versions/2.1.0"), bytes: 300_000)

    #expect(AIClutter.find(home: home.path, claudeTemp: home.path + "/none").isEmpty)
}

@Test func activityLogTotalsByKind() throws {
    let now = Date()
    let log = ActivityLog(entries: [
        ActivityEntry(date: now.addingTimeInterval(-10 * 86400), kind: .junk, title: "Caches", bytes: 500),
        ActivityEntry(date: now.addingTimeInterval(-86400), kind: .ai, title: "Claude Code", bytes: 300),
        ActivityEntry(date: now, kind: .junk, title: "Logs", bytes: 100),
        ActivityEntry(date: now, kind: .maintenance, title: "Flush DNS Cache", bytes: 0),
    ])

    #expect(log.freed == 900)
    #expect(log.freedByKind.map(\.kind) == [.junk, .ai])
    #expect(log.runsByKind.first?.count == 2)
    #expect(log.freed(lastDays: 7, now: now) == 400)

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zcbar-\(UUID().uuidString)/activity.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try log.save(to: url)
    #expect(ActivityLog.load(from: url) == log)
}
