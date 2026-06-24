import Foundation

/// Reads event-driven session state written by the hook scripts into
/// ~/.agent-status-board/sessions/*.json. This is the authoritative,
/// accurate signal: Claude Code emits running/waitingReview/done via hooks,
/// Codex emits done via the notify wrapper.
struct SessionEventCollector: TaskCollecting {
    let dir: URL
    /// Drop any unfinished entry not refreshed within this window (process likely died without cleanup).
    let staleAfter: TimeInterval
    /// A running/thinking session with no real activity (its transcript/rollout
    /// untouched) for this long is treated as finished. A session that was
    /// closed or killed never fires Stop, so it would otherwise hang in
    /// "正在执行" until `staleAfter`. Such an entry is reclassified to `done`.
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
                  var status = AgentTaskStatus(rawValue: record.status) else {
                continue
            }

            // key is "<source>-<id>"; recover the raw provider session id.
            let prefix = record.source + "-"
            let rawId = record.key.hasPrefix(prefix)
                ? String(record.key.dropFirst(prefix.count))
                : record.key

            // Drop sessions the user deleted/archived (artifact gone), and grab
            // the artifact's own last-write time when it's still there. An empty
            // map means the listing failed, so we fail open (show).
            var artifactMtime: Date?
            switch source {
            case .claudeCode:
                if !liveCC.isEmpty {
                    guard !rawId.isEmpty, let m = liveCC[rawId] else { continue }
                    artifactMtime = m
                }
            case .codex:
                if !liveCodex.isEmpty {
                    guard !rawId.isEmpty, let m = liveCodex[rawId] else { continue }
                    artifactMtime = m
                }
            default:
                break
            }

            // Last real activity = newest of the hook's status write and the
            // session artifact's own last write (a killed session can leave the
            // status frozen while its transcript was written slightly later).
            let lastActivity = max(record.updatedAt, artifactMtime ?? record.updatedAt)

            // A "running"/"thinking" session idle past runningStaleAfter was
            // closed/killed without firing Stop — treat it as finished so it
            // leaves 正在执行 instead of hanging there until staleAfter.
            if status == .running || status == .thinking,
               now.timeIntervalSince(lastActivity) > runningStaleAfter {
                status = .done
            }

            // Retention: keep finished work for keepCompletedAfter (so the most
            // recent few survive restarts / overnight); drop unfinished entries
            // whose process clearly died.
            if status == .done {
                if now.timeIntervalSince(lastActivity) > keepCompletedAfter { continue }
            } else if now.timeIntervalSince(record.updatedAt) > staleAfter {
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
                    lastActivityAt: lastActivity,
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
