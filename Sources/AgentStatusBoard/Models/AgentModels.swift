import Foundation

enum AgentSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode
    case automation
    case process

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            "Codex"
        case .claudeCode:
            "CC"
        case .automation:
            "Automation"
        case .process:
            "Process"
        }
    }
}

enum AgentTaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case running
    case thinking
    case waitingReview
    case blocked
    case failed
    case stale
    case done

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .running:
            "正在执行"
        case .thinking:
            "思考中"
        case .waitingReview:
            "需要确认"
        case .blocked:
            "等待信息"
        case .failed:
            "执行失败"
        case .stale:
            "疑似停滞"
        case .done:
            "已完成"
        }
    }

    var sortPriority: Int {
        switch self {
        case .blocked:
            0
        case .failed:
            1
        case .waitingReview:
            2
        case .running:
            3
        case .thinking:
            4
        case .stale:
            5
        case .done:
            6
        }
    }
}

/// The visual signal-light state shown in the menu bar pill, mirroring the
/// CodexBar traffic-light vocabulary. Aggregated across all sessions.
enum BoardOverallStatus: Sendable {
    case idle
    case running      // 黄绿跑马灯
    case thinking     // 黄灯呼吸
    case needsAttention // 红灯闪烁
    case done         // 绿灯常亮
}

struct AgentTask: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let source: AgentSource
    let title: String
    let workspace: String?
    let status: AgentTaskStatus
    let lastActivityAt: Date
    let summary: String
    let evidence: String
    var model: String? = nil
    var lastTool: String? = nil
}

struct AgentSnapshot: Equatable, Sendable {
    let tasks: [AgentTask]
    let refreshedAt: Date

    var visibleTasks: [AgentTask] {
        tasks.sorted {
            if $0.status.sortPriority != $1.status.sortPriority {
                return $0.status.sortPriority < $1.status.sortPriority
            }
            return $0.lastActivityAt > $1.lastActivityAt
        }
    }

    var activeCount: Int {
        tasks.filter { $0.status != .done }.count
    }

    var overallStatus: BoardOverallStatus {
        Self.aggregate(of: tasks)
    }

    func overallStatus(for source: AgentSource) -> BoardOverallStatus {
        Self.aggregate(of: tasks.filter { $0.source == source })
    }

    /// Priority for the aggregate pill: a session that needs you (red) is the
    /// most urgent and wins, then active work, then thinking, then done, then idle.
    private static func aggregate(of tasks: [AgentTask]) -> BoardOverallStatus {
        if tasks.isEmpty { return .idle }
        if tasks.contains(where: { [.waitingReview, .blocked, .failed, .stale].contains($0.status) }) {
            return .needsAttention
        }
        if tasks.contains(where: { $0.status == .running }) { return .running }
        if tasks.contains(where: { $0.status == .thinking }) { return .thinking }
        if tasks.contains(where: { $0.status == .done }) { return .done }
        return .idle
    }

    func count(for status: AgentTaskStatus) -> Int {
        tasks.filter { $0.status == status }.count
    }

    /// Sessions that are not finished — used for the pill's active-count badge.
    func liveCount(for source: AgentSource? = nil) -> Int {
        tasks.filter { task in
            (source == nil || task.source == source) && task.status != .done
        }.count
    }

    var attentionCount: Int {
        tasks.filter { [.waitingReview, .blocked, .failed, .stale].contains($0.status) }.count
    }

    func count(for source: AgentSource, status: AgentTaskStatus? = nil) -> Int {
        tasks.filter { task in
            task.source == source && (status == nil || task.status == status)
        }.count
    }
}
