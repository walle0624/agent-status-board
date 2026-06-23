import Foundation

/// Reads event-driven session state written by the hook scripts into
/// ~/.agent-status-board/sessions/*.json. This is the authoritative,
/// accurate signal: Claude Code emits running/waitingReview/done via hooks,
/// Codex emits done via the notify wrapper.
struct SessionEventCollector: TaskCollecting {
    let dir: URL
    /// Drop any entry not refreshed within this window (process likely died without cleanup).
    let staleAfter: TimeInterval
    /// Hide `done` entries older than this so finished work clears on its own.
    let hideDoneAfter: TimeInterval

    init(
        dir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-status-board/sessions"),
        staleAfter: TimeInterval = 60 * 60 * 12,
        hideDoneAfter: TimeInterval = 60 * 60 * 3
    ) {
        self.dir = dir
        self.staleAfter = staleAfter
        self.hideDoneAfter = hideDoneAfter
    }

    func collect(now: Date) async -> [AgentTask] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let names = SessionNames()

        // Hide sessions whose underlying artifact is gone — a CC session the
        // user deleted (its transcript removed) or a Codex session they archived
        // (its rollout moved out of ~/.codex/sessions/). Built once per pass;
        // an empty set means the listing failed, so we fail open (show).
        let liveCC = Self.liveClaudeSessionIds()
        let liveCodex = Self.liveCodexRolloutIds()

        var tasks: [AgentTask] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(SessionEventRecord.self, from: data) else {
                continue
            }

            let age = now.timeIntervalSince(record.updatedAt)
            if age > staleAfter { continue }

            guard let source = AgentSource(rawValue: record.source),
                  let status = AgentTaskStatus(rawValue: record.status) else {
                continue
            }

            if status == .done && age > hideDoneAfter { continue }

            let title = names.name(forCwd: record.cwd)
                ?? (record.title.isEmpty ? "\(source.displayName) 会话" : record.title)

            // key is "<source>-<id>"; recover the raw provider session id.
            let prefix = record.source + "-"
            let rawId = record.key.hasPrefix(prefix)
                ? String(record.key.dropFirst(prefix.count))
                : record.key

            // Drop sessions the user deleted/archived (artifact no longer present).
            switch source {
            case .claudeCode:
                if !liveCC.isEmpty, !rawId.isEmpty, !liveCC.contains(rawId) { continue }
            case .codex:
                if !liveCodex.isEmpty, !rawId.isEmpty, !liveCodex.contains(rawId) { continue }
            default:
                break
            }

            tasks.append(
                AgentTask(
                    id: "event-\(record.key)",
                    source: source,
                    title: title,
                    workspace: record.cwd.isEmpty ? nil : record.cwd,
                    status: status,
                    lastActivityAt: record.updatedAt,
                    summary: Self.summary(for: status),
                    evidence: file.path,
                    model: (record.model?.isEmpty == false) ? record.model : nil,
                    lastTool: (record.lastTool?.isEmpty == false) ? record.lastTool : nil,
                    note: (record.summary?.isEmpty == false) ? record.summary : nil,
                    sessionId: rawId.isEmpty ? nil : rawId
                )
            )
        }
        return tasks
    }

    /// Session ids that still have a Claude Code transcript on disk
    /// (~/.claude/projects/<cwd>/<id>.jsonl). A deleted session loses its file.
    private static func liveClaudeSessionIds() -> Set<String> {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var ids = Set<String>()
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                ids.insert(f.deletingPathExtension().lastPathComponent)
            }
        }
        return ids
    }

    /// UUIDs of Codex rollouts still under ~/.codex/sessions/. Archiving a
    /// session moves its rollout to ~/.codex/archived_sessions/, so it drops out.
    private static func liveCodexRolloutIds() -> Set<String> {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let en = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var ids = Set<String>()
        for case let url as URL in en {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let stem = name.dropLast(6)                 // strip ".jsonl"
            if stem.count >= 36 { ids.insert(String(stem.suffix(36))) }   // trailing uuid
        }
        return ids
    }

    private static func summary(for status: AgentTaskStatus) -> String {
        switch status {
        case .running: "正在执行中"
        case .thinking: "正在思考（压缩上下文）"
        case .waitingReview: "已停下，等待你的输入或授权"
        case .done: "本轮已完成，结果可查看"
        default: status.displayName
        }
    }
}

private struct SessionEventRecord: Decodable, Sendable {
    let key: String
    let source: String
    let status: String
    let title: String
    let cwd: String
    let updatedAt: Date
    let model: String?
    let lastTool: String?
    let summary: String?
}
