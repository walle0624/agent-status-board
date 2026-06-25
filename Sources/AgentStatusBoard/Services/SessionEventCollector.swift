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
    /// A "running" CC session whose latest transcript entry is a tool-use still
    /// awaiting its result for this long is treated as waiting on you (red).
    /// Claude Code doesn't reliably fire the permission Notification (especially
    /// for MCP tools), so such a session would otherwise sit amber.
    let pendingApprovalAfter: TimeInterval
    /// A "running" CC session whose latest transcript turn is a *completed*
    /// assistant answer (nothing pending) and has been idle this long is treated
    /// as finished. Goal / auto mode runs autonomously and often stops firing the
    /// CC hooks, so the event record freezes at "running" forever — the
    /// transcript, not the stale record, is the truth about whether it's done.
    let idleAfter: TimeInterval

    init(
        dir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-status-board/sessions"),
        staleAfter: TimeInterval = 60 * 60 * 12,
        runningStaleAfter: TimeInterval = 60 * 15,
        keepCompletedAfter: TimeInterval = 60 * 60 * 24 * 14,
        pendingApprovalAfter: TimeInterval = 90,
        idleAfter: TimeInterval = 60
    ) {
        self.dir = dir
        self.staleAfter = staleAfter
        self.runningStaleAfter = runningStaleAfter
        self.keepCompletedAfter = keepCompletedAfter
        self.pendingApprovalAfter = pendingApprovalAfter
        self.idleAfter = idleAfter
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

            // For an ACTIVE Claude Code session, read its transcript directly:
            //  • the live title (the ai/custom title is often generated AFTER the
            //    last hook fired, so the hook-captured title is stale — folder name);
            //  • the last REAL turn's time, so a long-running session whose hooks
            //    went quiet isn't wrongly dropped (while title-generation writes,
            //    which bump the file mtime, are ignored);
            //  • a tool-use pending past pendingApprovalAfter ⇒ waiting on you (CC
            //    often doesn't fire the permission Notification, esp. for MCP).
            var liveTitle: String?
            var lastActivity = record.updatedAt
            if source == .claudeCode, status == .running || status == .thinking,
               let url = liveCC[rawId] {
                let d = Self.ccDetail(url)
                liveTitle = d.title
                if let real = d.lastReal { lastActivity = max(lastActivity, real) }
                status = Self.refinedStatus(
                    status, pendingSince: d.pendingSince, idleSince: d.idleSince,
                    now: now, pendingApprovalAfter: pendingApprovalAfter, idleAfter: idleAfter
                )
            }

            // A running/thinking session with no recent REAL activity is not
            // actually running (finished without Stop, killed, or deleted) — drop
            // it, so a dead/deleted session never lingers as "正在执行".
            if (status == .running || status == .thinking),
               now.timeIntervalSince(lastActivity) > runningStaleAfter {
                continue
            }

            // Retention: keep finished work for keepCompletedAfter (recent ones
            // survive restarts / overnight); drop anything else past staleAfter.
            // Measure from lastActivity (transcript-derived for live CC), not the
            // hook record's time, so a goal-mode session whose hooks froze isn't
            // aged out while it's still active (and a finished one is dated by its
            // real last turn, not a stale hook write).
            let age = now.timeIntervalSince(lastActivity)
            if status == .done {
                if age > keepCompletedAfter { continue }
            } else if age > staleAfter {
                continue
            }

            // A session-id pin in names.json wins over everything (it's the only
            // place a session's short human name may exist — CC stores none for
            // un-renamed sessions, and one folder can host several sessions). Then
            // a cwd pin, then the live custom/ai title, then the hook's fallback.
            let title = names.name(forSessionId: rawId)
                ?? names.name(forCwd: record.cwd)
                ?? liveTitle
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
    /// (~/.claude/projects/<cwd>/<id>.jsonl), mapped to its URL. A deleted
    /// session loses its file (and drops out).
    private static func liveClaudeSessions() -> [String: URL] {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }
        var ids: [String: URL] = [:]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                ids[f.deletingPathExtension().lastPathComponent] = f
            }
        }
        return ids
    }

    /// Reads the tail of a Claude Code transcript and extracts: the live title
    /// (user-set custom-title preferred, else the auto ai-title); the timestamp
    /// of the last REAL turn (user/assistant — not title-generation metadata, so
    /// it reflects actual work); when the latest turn is an assistant tool-use
    /// still awaiting its result, when that tool-use was emitted (a "waiting on
    /// you / running a tool" signal); and `idleSince` — set when the last
    /// conversational turn is a *completed* assistant answer (Claude replied and
    /// nothing is pending), i.e. the turn ended and the session is idle.
    private static func ccDetail(_ url: URL) -> (title: String?, lastReal: Date?, pendingSince: Date?, idleSince: Date?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil, nil, nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 262_144
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return (nil, nil, nil, nil) }
        var lines = data.split(separator: 0x0a, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // drop the partial first line

        let isoF = ISO8601DateFormatter(); isoF.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { isoF.date(from: $0) ?? iso.date(from: $0) } }

        var customTitle: String?; var aiTitle: String?
        var lastReal: Date?; var pendingSince: Date?; var lastWasAssistant = false
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "custom-title": if let t = obj["customTitle"] as? String, !t.isEmpty { customTitle = t }
            case "ai-title": if let t = obj["aiTitle"] as? String, !t.isEmpty { aiTitle = t }
            case "user", "assistant":
                let ts = date(obj["timestamp"])
                if let ts { lastReal = ts }
                let hasToolUse = (obj["message"] as? [String: Any])
                    .flatMap { $0["content"] as? [[String: Any]] }?
                    .contains { ($0["type"] as? String) == "tool_use" } ?? false
                pendingSince = (type == "assistant" && hasToolUse) ? (ts ?? pendingSince) : nil
                lastWasAssistant = (type == "assistant")
            default:
                break
            }
        }
        // The turn has ended (session idle) when the last conversational entry is
        // an assistant message with no tool-use awaiting a result — Claude gave
        // its answer and is waiting. A trailing `user` entry (a fresh prompt or a
        // tool_result) instead means Claude is about to work → not idle.
        let idleSince = (lastWasAssistant && pendingSince == nil) ? lastReal : nil
        return (customTitle ?? aiTitle, lastReal, pendingSince, idleSince)
    }

    /// Refines a CC session's hook-reported status using transcript signals.
    /// Goal / auto mode runs autonomously and often stops firing the CC hooks, so
    /// the event record freezes — the transcript decides the truth. Only a
    /// `.running` record is refined: a tool-use pending past `pendingApprovalAfter`
    /// ⇒ waiting on you (red); a finished turn (completed assistant answer) idle
    /// past `idleAfter` ⇒ done. Anything else stays as reported.
    static func refinedStatus(
        _ status: AgentTaskStatus, pendingSince: Date?, idleSince: Date?, now: Date,
        pendingApprovalAfter: TimeInterval, idleAfter: TimeInterval
    ) -> AgentTaskStatus {
        guard status == .running else { return status }
        if let p = pendingSince, now.timeIntervalSince(p) > pendingApprovalAfter { return .waitingReview }
        if let idle = idleSince, now.timeIntervalSince(idle) > idleAfter { return .done }
        return status
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
