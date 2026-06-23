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

    private let collectors: [any TaskCollecting]
    private let activityLog = ActivityLog()
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
