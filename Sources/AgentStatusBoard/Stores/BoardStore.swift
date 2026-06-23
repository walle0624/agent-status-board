import Combine
import Foundation

@MainActor
final class BoardStore: ObservableObject {
    /// Shared instance so the custom status-bar item and the dashboard window
    /// observe the same data.
    static let shared = BoardStore()

    @Published private(set) var snapshot = AgentSnapshot(tasks: [], refreshedAt: Date())
    @Published private(set) var isRefreshing = false
    @Published private(set) var activity: [ActivityEntry] = []
    /// Codex / Claude Code 5-hour + weekly usage, refreshed slower than sessions.
    @Published private(set) var codexUsage: ProviderUsage?
    @Published private(set) var claudeUsage: ProviderUsage?

    private let collectors: [any TaskCollecting]
    private let activityLog = ActivityLog()
    private let usageCollector = UsageCollector()
    private var lastUsageAt: Date = .distantPast
    private var lastClaudeUsageAt: Date = .distantPast
    private var timer: Timer?

    init(collectors: [any TaskCollecting] = [
        SessionEventCollector()
    ]) {
        self.collectors = collectors
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        let now = Date()
        let activeCollectors = collectors
        let collected = await withTaskGroup(of: [AgentTask].self) { group in
            for collector in activeCollectors {
                group.addTask {
                    await collector.collect(now: now)
                }
            }

            var tasks: [AgentTask] = []
            for await result in group {
                tasks.append(contentsOf: result)
            }
            return tasks
        }

        snapshot = AgentSnapshot(tasks: deduplicate(collected), refreshedAt: now)
        activity = activityLog.recent(limit: 30)
        isRefreshing = false
        refreshUsageIfDue(now: now)
    }

    /// Usage changes slowly; reparse the latest rollout at most every ~25s, off
    /// the main thread, and publish the result without blocking the session loop.
    private func refreshUsageIfDue(now: Date) {
        if now.timeIntervalSince(lastUsageAt) > 25 {
            lastUsageAt = now
            let collector = usageCollector
            Task.detached(priority: .utility) { [weak self] in
                let usage = collector.codexUsage()
                // Keep the last good snapshot if a read momentarily finds none
                // (e.g. a brand-new Codex session with no token_count yet), so
                // the usage doesn't blink out.
                await MainActor.run { if let usage { self?.codexUsage = usage } }
            }
        }
        // CC usage costs a tiny inference ping, so poll it much less often and
        // keep the last good value across transient failures.
        if now.timeIntervalSince(lastClaudeUsageAt) > 300 {
            lastClaudeUsageAt = now
            let collector = usageCollector
            Task.detached(priority: .utility) { [weak self] in
                let usage = await collector.claudeUsage()
                await MainActor.run { if let usage { self?.claudeUsage = usage } }
            }
        }
    }

    private func deduplicate(_ tasks: [AgentTask]) -> [AgentTask] {
        var seen: Set<String> = []
        return tasks.filter { task in
            if seen.contains(task.id) {
                return false
            }
            seen.insert(task.id)
            return true
        }
    }
}
