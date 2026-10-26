import Foundation
import Darwin
import Testing
@testable import AgentStatusBoard

@Test func instanceLockAllowsOneOwnerAndRecoversAfterRelease() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("instance.lock")
    let first = AppInstanceLock(url: url), second = AppInstanceLock(url: url)
    #expect(try first.acquire())
    #expect(try !second.acquire())
    first.release()
    #expect(try second.acquire())
    second.release()
}

@Test func updatePreparationPreservesQuotedPathsAndIsolatesTheLaunchdJob() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asb-'quoted \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let checkout = dir.appendingPathComponent("checkout with spaces")
    try FileManager.default.createDirectory(at: checkout.appendingPathComponent("script"), withIntermediateDirectories: true)
    try Data("#!/bin/bash\nexit 0\n".utf8).write(to: checkout.appendingPathComponent("script/update.sh"))
    let cfg = dir.appendingPathComponent("update.json")
    try JSONSerialization.data(withJSONObject: ["checkout": checkout.path]).write(to: cfg)
    let checker = UpdateChecker(configURL: cfg, runtimeDirectory: dir.appendingPathComponent("runs"))
    let attempt = try checker.prepareUpdate()
    let data = try Data(contentsOf: attempt.jobURL)
    let job = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let args = try #require(job["ProgramArguments"] as? [String])
    #expect(args.count == 3)
    #expect(args[0] == "/bin/bash")
    #expect(args[2] == checkout.path)
    #expect(args[1] != checkout.appendingPathComponent("script/update.sh").path)
    #expect(job["Label"] as? String == attempt.label)
    #expect(attempt.label != "com.linkingdigital.agentstatusboard")
    #expect(attempt.progress()?.phase == .starting)
    #expect(checker.currentAttempt()?.label == attempt.label)
    let mode = try FileManager.default.attributesOfItem(atPath: attempt.jobURL.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func unavailableUpdateConfigurationFailsExplicitly() {
    let checker = UpdateChecker(configURL: URL(fileURLWithPath: "/nonexistent/update.json"))
    #expect(throws: UpdateLaunchError.self) { try checker.prepareUpdate() }
}

@Test func updatedAppUsesItsBundledUpdaterInsteadOfAnOldGitCheckout() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let checkout = dir.appendingPathComponent("checkout")
    try FileManager.default.createDirectory(at: checkout.appendingPathComponent("script"), withIntermediateDirectories: true)
    let old = Data("#!/bin/bash\n# old checkout updater\n".utf8)
    try old.write(to: checkout.appendingPathComponent("script/update.sh"))
    let bundled = dir.appendingPathComponent("bundled-update.sh")
    let current = Data("#!/bin/bash\n# new bundled updater\n".utf8)
    try current.write(to: bundled)
    let cfg = dir.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: ["checkout": checkout.path]).write(to: cfg)
    let checker = UpdateChecker(configURL: cfg, runtimeDirectory: dir.appendingPathComponent("runs"), bundledUpdaterURL: bundled)
    let attempt = try checker.prepareUpdate()
    #expect(try Data(contentsOf: attempt.statusURL.deletingLastPathComponent().appendingPathComponent("update.sh")) == current)
    #expect(try Data(contentsOf: checkout.appendingPathComponent("script/update.sh")) == old)
}

@Test func failedUpdateCanBeRetriedAndStagesAreVisible() throws {
    let failed = try JSONDecoder().decode(UpdateProgress.self, from: Data(
        #"{"phase":"failed","version":"1.34","updatedAt":2000000000,"failedPhase":"building","exitCode":65,"pid":123}"#.utf8))
    #expect(!failed.isRunning)
    #expect(failed.message.contains("65"))
    #expect(failed.message.contains("重试"))
    let building = UpdateProgress(phase: .building, updatedAt: 2000000000)
    #expect(building.isRunning)
    #expect(building.message.contains("编译"))
}

/// Opt-in native smoke test: runs only a harmless local fixture, never the real
/// updater, network download or app installer. Confirms launchd job isolation.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ASB_LAUNCHD_SMOKE_TEST"] == "1"))
func updateJobActuallyRunsOutsideTheApplicationJob() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asb-launch-smoke-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let checkout = dir.appendingPathComponent("fixture")
    try FileManager.default.createDirectory(at: checkout.appendingPathComponent("script"), withIntermediateDirectories: true)
    let script = """
    #!/bin/bash
    /usr/bin/python3 - <<'PY'
    import json,os,time,pathlib
    path=pathlib.Path(os.environ['ASB_UPDATE_STATUS_FILE'])
    (path.parent/'environment.json').write_text(json.dumps({'job':os.environ.get('XPC_SERVICE_NAME',''),'pid':os.getpid(),'parent':os.getppid()}))
    path.write_text(json.dumps({'phase':'completed','version':'0','updatedAt':time.time(),'pid':os.getpid()}))
    time.sleep(0.5)
    PY
    """
    try Data(script.utf8).write(to: checkout.appendingPathComponent("script/update.sh"))
    let cfg = dir.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: ["checkout": checkout.path]).write(to: cfg)
    let checker = UpdateChecker(configURL: cfg, runtimeDirectory: dir.appendingPathComponent("runs"))
    let attempt = try checker.runUpdate()
    defer {
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        cleanup.arguments = ["bootout", "gui/\(getuid())/\(attempt.label)"]
        cleanup.standardOutput = FileHandle.nullDevice
        cleanup.standardError = FileHandle.nullDevice
        try? cleanup.run()
        cleanup.waitUntilExit()
    }
    for _ in 0..<200 {
        if attempt.progress()?.phase == .completed { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(attempt.progress()?.phase == .completed)
    let envData = try Data(contentsOf: attempt.statusURL.deletingLastPathComponent().appendingPathComponent("environment.json"))
    let env = try #require(try JSONSerialization.jsonObject(with: envData) as? [String: Any])
    #expect(env["job"] as? String != "com.linkingdigital.agentstatusboard")
    // Some macOS versions expose XPC_SERVICE_NAME=0 for these jobs. Inspect
    // launchd's actual label/PID instead of treating that environment as truth.
    let inspect = Process(), output = Pipe()
    inspect.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    inspect.arguments = ["print", "gui/\(getuid())/\(attempt.label)"]
    inspect.standardOutput = output
    inspect.standardError = FileHandle.nullDevice
    try inspect.run()
    let listing = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    inspect.waitUntilExit()
    #expect(inspect.terminationStatus == 0)
    let pid = try #require(env["pid"] as? Int), parent = try #require(env["parent"] as? Int)
    #expect(listing.contains("pid = \(pid)") || listing.contains("pid = \(parent)"))
}
