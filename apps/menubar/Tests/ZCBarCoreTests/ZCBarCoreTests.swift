import Foundation
import Testing
@testable import ZCBarCore

/// Answers each command with canned output, keyed by its first argument.
struct FakeRunner: Runner {
    var outputs: [String: CommandResult]

    func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult {
        outputs[args.first ?? ""] ?? CommandResult(status: 1, stderr: "error: no such command")
    }
}

func ok(_ json: String) -> CommandResult { CommandResult(status: 0, stdout: Data(json.utf8)) }

@Test func snapshotCountsGapsUpdatesAndFindings() async {
    let fake = FakeRunner(outputs: [
        "status": ok("""
        [{"target":"packages","provider":"packages","summary":"","in_place":123,"declared":124},
         {"target":"linux","provider":"packages","summary":"","in_place":0,"declared":0,"skipped":true},
         {"target":"home","provider":"dotfiles","summary":"","in_place":36,"declared":36}]
        """),
        "list": ok("""
        [{"target":"packages","provider":"packages","items":[{"name":"tmux","kind":"brew","state":"outdated","version":"3.7c","latest":"3.8"}]}]
        """),
        // The doctor exits 1 when a check fails; its report still counts.
        "doctor": CommandResult(status: 1, stdout: Data("""
        {"schemaVersion":1,"checks":[{"name":"binary","status":"ok"},
         {"name":"security firewall","status":"warn","detail":"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"},
         {"name":"security servers on every network interface","status":"warn","detail":"limactl:53"}]}
        """.utf8)),
    ])
    let ws = Workstation(binary: "/zc", config: "/c.yaml", env: [:], runner: fake)
    let s = await ws.snapshot()

    #expect(s.errors.isEmpty)
    #expect(s.visibleTargets.map(\.target) == ["packages", "home"])
    #expect(s.outdated.map(\.resource) == ["brew:tmux"])
    #expect(s.findings.map(\.title) == ["Firewall", "Servers on every network interface"])
    #expect(s.attention(ignoring: []) == 4)
    #expect(s.attention(ignoring: ["security servers on every network interface"]) == 3)
}

@Test func aFailingPartLeavesAnErrorAndTheRest() async {
    let fake = FakeRunner(outputs: ["status": ok(#"[{"target":"home","provider":"dotfiles","summary":"","in_place":1,"declared":1}]"#)])
    let s = await Workstation(binary: "/zc", config: "/c.yaml", env: [:], runner: fake).snapshot()
    #expect(s.targets.count == 1)
    #expect(s.errors.count == 2)
    #expect(s.errors.allSatisfy { $0.hasSuffix("error: no such command") })
}

@Test func planDecodesAndSpotsDeletes() throws {
    let doc = try JSONDecoder().decode(PlanDoc.self, from: Data("""
    {"changes":2,"manual":0,"actions":[{"op":"UPDATE","target":"packages","resource":"brew:tmux","detail":"upgrade","manual":false},
     {"op":"DELETE","target":"notes","resource":"stray.txt","manual":false}]}
    """.utf8))
    #expect(doc.changes == 2)
    #expect(doc.deletes)
}

@Test func fixesFollowTheDoctorsDetail() {
    let sudo = Check(name: "security firewall", status: "warn", detail: "sudo socketfilterfw --setglobalstate on")
    #expect(Fix(for: sudo) == .command("socketfilterfw --setglobalstate on"))

    let lock = Check(name: "security password after sleep or screen saver", status: "warn",
                     detail: "System Settings, Lock Screen: require a password immediately")
    guard case .settings(let url, _) = Fix(for: lock) else { Issue.record("not a settings fix"); return }
    #expect(url.absoluteString.hasSuffix("Lock-Screen-Settings.extension"))

    #expect(Fix(for: Check(name: "program brew", status: "fail", detail: "not on PATH")) == .info("not on PATH"))
}

@Test func adminScriptQuotesTheCommand() {
    #expect(adminScript(#"sed "s/^#auth/auth/" a | tee b"#)
        == #"do shell script "sed \"s/^#auth/auth/\" a | tee b" with administrator privileges"#)
}

@Test func discoveryPrefersTheChoiceThenTheEnvironment() {
    let exists: (String) -> Bool = { $0 != "/gone.yaml" }
    #expect(Discovery.config(chosen: "/mine.yaml", env: ["ZC_WORKSTATION_CONFIG": "/env.yaml"], home: "/h", exists: exists) == "/mine.yaml")
    #expect(Discovery.config(chosen: "/gone.yaml", env: ["ZC_WORKSTATION_CONFIG": "/env.yaml"], home: "/h", exists: exists) == "/env.yaml")
    #expect(Discovery.config(chosen: nil, env: [:], home: "/h", exists: exists) == "/h/.config/zc-workstation/zc-workstation.yaml")

    let bin = Discovery.binary(env: ["PATH": "/usr/bin:/opt/homebrew/bin"], home: "/h") { $0 == "/h/.local/bin/zc-workstation" }
    #expect(bin == "/h/.local/bin/zc-workstation")
}

@Test func loginEnvironmentParsesNulSeparatedPairs() {
    let env = Discovery.parseEnv(Data("PATH=/a:/b\0EMPTY=\0X=1=2\0".utf8))
    #expect(env == ["PATH": "/a:/b", "EMPTY": "", "X": "1=2"])
}
