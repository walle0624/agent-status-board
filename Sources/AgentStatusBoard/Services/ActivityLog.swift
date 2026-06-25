import Foundation

/// One line in the activity timeline, written by the hook scripts to
/// ~/.agent-status-board/activity.jsonl (one JSON object per line).
struct ActivityEntry: Identifiable, Equatable, Sendable {
    let id: String
    let at: Date
    let sessionKey: String
    let source: AgentSource
    let status: AgentTaskStatus
    let title: String
}

/// Tails the activity.jsonl file and returns the most recent entries, newest first.
struct ActivityLog: Sendable {
    let url: URL

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-status-board/activity.jsonl")) {
        self.url = url
    }

    func recent(limit: Int) -> [ActivityEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let names = SessionNames()

        var entries: [ActivityEntry] = []
        // Walk the tail of the file; cap work regardless of total size.
        for (i, line) in content.split(separator: "\n").suffix(limit * 6).enumerated() {
            guard let data = String(line).data(using: .utf8),
                  let raw = try? decoder.decode(RawActivity.self, from: data),
                  let source = AgentSource(rawValue: raw.source),
                  let status = AgentTaskStatus(rawValue: raw.status) else {
                continue
            }
            // key is "<source>-<id>"; recover the raw id so a session-id pin in
            // names.json (highest priority) can name this entry — same rule as
            // SessionEventCollector.
            let prefix = raw.source + "-"
            let rawId = (raw.key ?? "").hasPrefix(prefix)
                ? String((raw.key ?? "").dropFirst(prefix.count))
                : (raw.key ?? "")
            let title = names.name(forSessionId: rawId)
                ?? names.name(forCwd: raw.cwd)
                ?? (raw.title.isEmpty ? status.displayName : raw.title)
            entries.append(
                ActivityEntry(
                    id: "\(raw.at.timeIntervalSince1970)-\(i)",
                    at: raw.at,
                    sessionKey: raw.key ?? title,
                    source: source,
                    status: status,
                    title: title
                )
            )
        }

        // Newest first, then keep only the most recent entry per session so the
        // same session does not appear multiple times.
        var seen = Set<String>()
        var deduped: [ActivityEntry] = []
        for entry in entries.reversed() {
            guard !seen.contains(entry.sessionKey) else { continue }
            seen.insert(entry.sessionKey)
            deduped.append(entry)
            if deduped.count >= limit { break }
        }
        return deduped
    }
}

private struct RawActivity: Decodable, Sendable {
    let at: Date
    let key: String?
    let source: String
    let status: String
    let title: String
    let cwd: String?
}
