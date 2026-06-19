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
