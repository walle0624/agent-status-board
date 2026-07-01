import Foundation
import Testing
@testable import AgentStatusBoard

private func task(_ id: String, _ source: AgentSource, _ status: AgentTaskStatus, at t: TimeInterval) -> AgentTask {
    AgentTask(
        id: id, source: source, title: id, workspace: "/Users/walle/Game",
        status: status, lastActivityAt: Date(timeIntervalSince1970: t),
        summary: "", evidence: "test"
    )
}

@Test func onlyRunningIsRunning() {
    let s = AgentSnapshot(tasks: [task("a", .codex, .running, at: 100)], refreshedAt: Date())
    #expect(s.overallStatus == .running)
    #expect(s.count(for: .running) == 1)
}

@Test func attentionWinsOverRunning() {
    // A session that needs the user is the most urgent → red, even while other work runs.
    let s = AgentSnapshot(tasks: [
        task("a", .codex, .waitingReview, at: 100),
        task("b", .claudeCode, .running, at: 120)
    ], refreshedAt: Date())
    #expect(s.overallStatus == .needsAttention)
    #expect(s.attentionCount == 1)
    #expect(s.liveCount() == 2)
}

@Test func thinkingState() {
    let s = AgentSnapshot(tasks: [task("a", .claudeCode, .thinking, at: 100)], refreshedAt: Date())
    #expect(s.overallStatus == .thinking)
}

@Test func doneAndEmpty() {
    let done = AgentSnapshot(tasks: [task("a", .claudeCode, .done, at: 300)], refreshedAt: Date())
    #expect(done.overallStatus == .done)
    #expect(AgentSnapshot(tasks: [], refreshedAt: Date()).overallStatus == .idle)
}

@Test func perSourceAggregate() {
    let s = AgentSnapshot(tasks: [
        task("a", .codex, .running, at: 100),
        task("b", .claudeCode, .waitingReview, at: 120)
    ], refreshedAt: Date())
    #expect(s.overallStatus(for: .codex) == .running)
    #expect(s.overallStatus(for: .claudeCode) == .needsAttention)
}

/// Writes a names.json with the given map to a temp file and returns a
/// SessionNames reading it.
private func sessionNames(_ map: [String: String]) throws -> SessionNames {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("asb-names-\(UUID().uuidString).json")
    try JSONEncoder().encode(map).write(to: url)
    return SessionNames(url: url)
}

@Test func sessionIdPinWinsOverCwd() throws {
    // ~/LinkView hosts several CC sessions; a session-id key must name exactly
    // one of them and beat any folder-wide cwd mapping. This is the regression
    // the user kept hitting ("代码管理"/"会议纪要" shown as the verbose ai-title).
    let names = try sessionNames([
        "/Users/walle/LinkView": "folder-wide",
        "cb2a74a7-221a-46dc-ba57-2bd27c2733d5": "代码管理"
    ])
    #expect(names.name(forSessionId: "cb2a74a7-221a-46dc-ba57-2bd27c2733d5") == "代码管理")
    // A different session in the same folder still gets the cwd name, not the pin.
    #expect(names.name(forSessionId: "00000000-0000-0000-0000-000000000000") == nil)
    #expect(names.name(forCwd: "/Users/walle/LinkView") == "folder-wide")
}

@Test func pathAndIdKeysAreRoutedSeparately() throws {
    let names = try sessionNames([
        "~/Obsidian": "folder",
        "90625db1-5c6e-4fb8-9eb3-21e13cd5d102": "会议纪要"
    ])
    // A session-id key never matches as a path...
    #expect(names.name(forCwd: "90625db1-5c6e-4fb8-9eb3-21e13cd5d102") == nil)
    // ...and a path key never matches as a session id.
    #expect(names.name(forSessionId: "/Users/walle/Obsidian") == nil)
    // Tilde paths expand and match by prefix.
    #expect(names.name(forCwd: "/Users/walle/Obsidian/notes") == "folder")
    #expect(names.name(forSessionId: "90625db1-5c6e-4fb8-9eb3-21e13cd5d102") == "会议纪要")
}

@Test func emptyNameAndMissingFileIgnored() throws {
    let names = try sessionNames(["abc": "", "/x": "  keep  "])
    #expect(names.name(forSessionId: "abc") == nil)          // empty value dropped
    #expect(names.name(forCwd: "/x") == "  keep  ")
    // A missing file is fine — no overrides, never crashes.
    let none = SessionNames(url: URL(fileURLWithPath: "/no/such/names.json"))
    #expect(none.name(forSessionId: "abc") == nil)
    #expect(none.name(forCwd: "/Users/walle/Game") == nil)
}

@Test func goalModeIdleSessionBecomesDone() {
    let now = Date(timeIntervalSince1970: 10_000)
    let old = Date(timeIntervalSince1970: 10_000 - 600)    // 10 min ago
    let fresh = Date(timeIntervalSince1970: 10_000 - 10)   // 10 s ago
    func refine(_ s: AgentTaskStatus, pending: Date? = nil, idle: Date? = nil) -> AgentTaskStatus {
        SessionEventCollector.refinedStatus(s, pendingSince: pending, idleSince: idle, now: now,
                                            pendingApprovalAfter: 90, idleAfter: 60)
    }
    // Goal/auto mode froze the hook record at "running"; the transcript shows a
    // finished turn idle 10 min → it's actually done (the user-reported bug).
    #expect(refine(.running, idle: old) == .done)
    // A turn that only just finished (<idleAfter) stays running — avoids flicker
    // between the assistant's text entry and a following tool-use, or a brief
    // pause between goal-mode steps.
    #expect(refine(.running, idle: fresh) == .running)
    // A tool-use pending past pendingApprovalAfter → waiting on you, and that
    // wins over idle (a pending call is not a finished turn).
    #expect(refine(.running, pending: old) == .waitingReview)
    #expect(refine(.running, pending: old, idle: old) == .waitingReview)
    // Mid-work (nothing pending, last turn not a completed answer) stays running.
    #expect(refine(.running) == .running)
    // Non-running statuses are never second-guessed.
    #expect(refine(.done, idle: old) == .done)
    #expect(refine(.waitingReview, idle: old) == .waitingReview)
    #expect(refine(.thinking, idle: old) == .thinking)
}

@Test func detectsAutomationCodexSessions() {
    // Scheduled / cron `codex exec` runs carry thread_source == "automation".
    #expect(SessionEventCollector.isAutomationMeta(#"{"payload":{"cwd":"/x","thread_source":"automation","model_provider":"openai"}}"#))
    #expect(SessionEventCollector.isAutomationMeta(#""thread_source": "automation""#))   // pretty-printed spacing
    // Interactive sessions are not hidden.
    #expect(!SessionEventCollector.isAutomationMeta(#"{"thread_source":"user"}"#))
    #expect(!SessionEventCollector.isAutomationMeta(#"{"thread_source":"vscode"}"#))
    // The word appearing in free text (e.g. base_instructions) must not trigger it.
    #expect(!SessionEventCollector.isAutomationMeta(#"{"base_instructions":{"text":"you may run automation tasks"},"thread_source":"user"}"#))
    #expect(!SessionEventCollector.isAutomationMeta("{}"))
}

@Test func updateVersionCompare() {
    #expect(UpdateChecker.isNewer("1.12", than: "1.11"))
    #expect(UpdateChecker.isNewer("1.11", than: "1.2"))   // numeric, not lexical
    #expect(UpdateChecker.isNewer("2.0", than: "1.99"))
    #expect(!UpdateChecker.isNewer("1.11", than: "1.11"))
    #expect(!UpdateChecker.isNewer("1.10", than: "1.11"))
}
