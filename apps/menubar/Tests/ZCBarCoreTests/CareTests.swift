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

    let paths = ["Movies/big.mov", "Downloads/mid.zip", "Downloads/tiny.txt", "Library/Caches/huge.bin",
                 ".cache/hidden.bin", "Gone/missing.bin"].map { home.path + "/" + $0 } + ["/elsewhere/x.bin"]
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
