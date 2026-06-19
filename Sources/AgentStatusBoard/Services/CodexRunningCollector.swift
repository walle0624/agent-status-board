import Foundation

/// Best-effort "Codex is actively running" signal.
///
/// Codex's `notify` only fires when a turn *ends*, so there is no event for
/// "turn started". The one live signal we have is the rollout transcript file:
/// while a turn streams, Codex keeps appending to today's rollout .jsonl, so a
/// very recent mtime means a turn is in progress.
struct CodexRunningCollector: TaskCollecting {
    let sessionsRoot: URL
    let sessionIndexURL: URL
    /// A rollout touched within this window counts as "running".
    let activeWindow: TimeInterval

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions"),
        sessionIndexURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl"),
        activeWindow: TimeInterval = 15
    ) {
        self.sessionsRoot = sessionsRoot
        self.sessionIndexURL = sessionIndexURL
        self.activeWindow = activeWindow
    }

    func collect(now: Date) async -> [AgentTask] {
        guard let (latest, mtime) = newestRollout(now: now) else { return [] }
        guard now.timeIntervalSince(mtime) <= activeWindow else { return [] }

        // The rollout filename ends with the 36-char session uuid; map it to the
        // thread's name via the session index so we show the real session name.
        let uuid = String(latest.deletingPathExtension().lastPathComponent.suffix(36))
        let title = threadName(for: uuid) ?? "Codex 会话"

        return [
            AgentTask(
                id: "codex-running",
                source: .codex,
                title: title,
                workspace: nil,
                status: .running,
                lastActivityAt: mtime,
                summary: "检测到 Codex 回合正在进行",
                evidence: latest.lastPathComponent
            )
        ]
    }

    /// Latest thread_name for a session id from ~/.codex/session_index.jsonl.
    private func threadName(for uuid: String) -> String? {
        guard uuid.count == 36,
              let content = try? String(contentsOf: sessionIndexURL, encoding: .utf8) else {
            return nil
        }
        var name: String?
        for line in content.split(separator: "\n") where line.contains(uuid) {
            if let data = line.data(using: .utf8),
               let entry = try? JSONDecoder().decode(IndexEntry.self, from: data),
               entry.id == uuid, !entry.thread_name.isEmpty {
                name = entry.thread_name
            }
        }
        return name
    }

    private struct IndexEntry: Decodable { let id: String; let thread_name: String }

    /// Only scans the day directories around `now` (today + yesterday for the
    /// midnight boundary) to stay cheap regardless of total history size.
    private func newestRollout(now: Date) -> (URL, Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current

        var best: (URL, Date)?
        for dayOffset in [0, -1] {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let dir = sessionsRoot
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { continue }
                if best == nil || mtime > best!.1 {
                    best = (file, mtime)
                }
            }
        }
        return best
    }
}
