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
    /// Whether each tool is present locally — a tool the user doesn't have gets
    /// no usage row at all.
    @Published private(set) var codexAvailable = false
    @Published private(set) var claudeAvailable = false
    /// Newer version available from the source GitHub repo, if any (drives the
    /// in-app "click to update" banner).
    @Published private(set) var availableUpdate: String?

    private let collectors: [any TaskCollecting]
    private let activityLog = ActivityLog()
    private let usageCollector = UsageCollector()
    private let updateChecker = UpdateChecker()
    private var lastUsageAt: Date = .distantPast
    private var lastClaudeUsageAt: Date = .distantPast
    private var lastUpdateCheck: Date = .distantPast
    private var timer: Timer?

    /// Run the source self-update (download latest source from GitHub over HTTP,
    /// rebuild locally, reinstall, relaunch — no git required).
    func applyUpdate() { updateChecker.runUpdate() }

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
        updateAvailability()
        refreshUsageIfDue(now: now)
    }

    /// Detect whether Codex / Claude Code are present locally, so we only show a
    /// tool's usage when the user actually has it. Cheap existence checks.
    private func updateAvailability() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: home.appendingPathComponent(rel).path) }
        // Codex: its logged-in state file is what live usage needs.
        codexAvailable = exists(".codex/auth.json")
        // Claude Code: a usage token set up, or any local CC transcript (i.e.
        // the user actually uses CC). Just having the chat app doesn't count.
        let ccProjects = (try? fm.contentsOfDirectory(
            atPath: home.appendingPathComponent(".claude/projects").path))?.isEmpty == false
        claudeAvailable = exists(".agent-status-board/cc-token.json") || ccProjects
    }

    /// Usage changes slowly; reparse the latest rollout at most every ~25s, off
    /// the main thread, and publish the result without blocking the session loop.
    private func refreshUsageIfDue(now: Date) {
        if codexAvailable, now.timeIntervalSince(lastUsageAt) > 60 {
            lastUsageAt = now
            let collector = usageCollector
            Task.detached(priority: .utility) { [weak self] in
                // Prefer Codex's live usage endpoint. On a transient failure do
                // NOT downgrade to the local rollout snapshot — it reports a
                // different (lower) number than the live limit, so swapping to it
                // made the board flicker to a wrong value. Keep the last good live
                // value instead; only use the snapshot before we ever have one
                // (first load / offline at startup).
                if let live = await collector.codexUsageLive() {
                    await MainActor.run { self?.codexUsage = live }
                    return
                }
                let hasValue = await MainActor.run { self?.codexUsage != nil }
                if !hasValue, let snap = collector.codexUsage() {
                    UsageCollector.log.info("codex usage: live unavailable, showing local snapshot")
                    await MainActor.run { self?.codexUsage = snap }
                }
            }
        }
        // CC usage costs a tiny inference ping, so poll it much less often and
        // keep the last good value across transient failures.
        if claudeAvailable, now.timeIntervalSince(lastClaudeUsageAt) > 300 {
            lastClaudeUsageAt = now
            let collector = usageCollector
            Task.detached(priority: .utility) { [weak self] in
                let usage = await collector.claudeUsage()
                await MainActor.run { if let usage { self?.claudeUsage = usage } }
            }
        }
        // Check the source repo for a newer version hourly.
        if now.timeIntervalSince(lastUpdateCheck) > 3600 {
            lastUpdateCheck = now
            let checker = updateChecker
            Task.detached(priority: .utility) { [weak self] in
                let latest = await checker.latestIfNewer()
                await MainActor.run { self?.availableUpdate = latest }
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
