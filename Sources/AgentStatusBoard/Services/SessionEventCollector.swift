import Foundation

/// Reads event-driven session state written by the hook scripts into
/// ~/.agent-status-board/sessions/*.json. This is the authoritative,
/// accurate signal: Claude Code emits running/waitingReview/done via hooks,
/// Codex emits done via the notify wrapper.
struct SessionEventCollector: TaskCollecting {
    let dir: URL
    /// Drop any unfinished entry not refreshed within this window (process likely died without cleanup).
    let staleAfter: TimeInterval
    /// A running/thinking session whose hook hasn't fired within this window is
    /// not actually running (finished without Stop, killed, or deleted) and is
    /// dropped from the board. Keyed on the hook's own timestamp — NOT the
    /// transcript file mtime, which background writes (title generation, a
    /// deletion touching the file) would otherwise make look like activity.
    let runningStaleAfter: TimeInterval
    /// Keep finished sessions this long so the most-recent few stay visible
    /// across restarts and overnight ("明早一眼看到昨天干了啥").
    let keepCompletedAfter: TimeInterval

    init(
        dir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-status-board/sessions"),
        staleAfter: TimeInterval = 60 * 60 * 12,
        runningStaleAfter: TimeInterval = 60 * 15,
        keepCompletedAfter: TimeInterval = 60 * 60 * 24 * 14
    ) {
        self.dir = dir
        self.staleAfter = staleAfter
        self.runningStaleAfter = runningStaleAfter
        self.keepCompletedAfter = keepCompletedAfter
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
        let liveCC = Self.liveClaudeSessions()
        let liveCodex = Self.liveCodexRollouts()

        var tasks: [AgentTask] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(SessionEventRecord.self, from: data) else {
                continue
            }

            guard let source = AgentSource(rawValue: record.source),
                  let status = AgentTaskStatus(rawValue: record.status) else {
                continue
            }

            // key is "<source>-<id>"; recover the raw provider session id.
            let prefix = record.source + "-"
            let rawId = record.key.hasPrefix(prefix)
                ? String(record.key.dropFirst(prefix.count))
                : record.key

            // Drop sessions the user deleted (CC transcript removed) or archived
            // (Codex rollout moved out of ~/.codex/sessions/). An empty map means
            // the listing failed, so we fail open (show).
            switch source {
            case .claudeCode:
                if !liveCC.isEmpty, rawId.isEmpty || liveCC[rawId] == nil { continue }
            case .codex:
                if !liveCodex.isEmpty, rawId.isEmpty || liveCodex[rawId] == nil { continue }
            default:
                break
            }

            // Activity = the hook's OWN timestamp. We deliberately do not use the
            // transcript/rollout file mtime: background writes (title generation,
            // or the app touching a session you just deleted) bump the file mtime
            // and would make a dead/deleted session look like it's still running.
            let age = now.timeIntervalSince(record.updatedAt)

            // A "running"/"thinking" session whose hooks have gone quiet this long
            // is not actually running — it finished without firing Stop, was
            // killed, or was deleted. Drop it entirely, so a deleted session never
            // lingers as "正在执行" (and doesn't reappear as a fake completion).
            if (status == .running || status == .thinking), age > runningStaleAfter {
                continue
            }

            // Retention: keep finished work for keepCompletedAfter (recent ones
            // survive restarts / overnight); drop anything else past staleAfter.
            if status == .done {
                if age > keepCompletedAfter { continue }
            } else if age > staleAfter {
                continue
            }

            let title = names.name(forCwd: record.cwd)
                ?? (record.title.isEmpty ? "\(source.displayName) 会话" : record.title)

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

    /// Claude Code session ids that still have a transcript on disk
    /// (~/.claude/projects/<cwd>/<id>.jsonl), mapped to the transcript's
    /// last-write time. A deleted session loses its file (and drops out).
    private static func liveClaudeSessions() -> [String: Date] {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }
        var ids: [String: Date] = [:]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let id = f.deletingPathExtension().lastPathComponent
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                ids[id] = m
            }
        }
        return ids
    }

    /// UUIDs of Codex rollouts still under ~/.codex/sessions/, mapped to the
    /// rollout's last-write time. Archiving moves the rollout to
    /// ~/.codex/archived_sessions/, so it drops out.
    private static func liveCodexRollouts() -> [String: Date] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let en = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        var ids: [String: Date] = [:]
        for case let url as URL in en {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let stem = name.dropLast(6)                 // strip ".jsonl"
            guard stem.count >= 36 else { continue }
            let id = String(stem.suffix(36))            // trailing uuid
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            ids[id] = m
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
