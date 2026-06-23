import Foundation

/// One rate-limit window (e.g. the 5-hour or weekly bucket).
struct UsageWindow: Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
}

/// A provider's current usage snapshot. `short` is the rolling 5-hour window
/// (Codex "primary"), `long` the weekly window (Codex "secondary").
struct ProviderUsage: Equatable, Sendable {
    let source: AgentSource
    let plan: String?
    let short: UsageWindow?
    let long: UsageWindow?
    /// When this reading was recorded (token_count event time) — lets the UI
    /// flag stale data if the provider hasn't run recently.
    let snapshotAt: Date
}

/// Reads Codex's rate-limit usage from the newest rollout file. Codex logs a
/// `token_count` event whose `payload.rate_limits` carries the 5-hour
/// (`primary`) and weekly (`secondary`) windows with `used_percent` +
/// `resets_at`, plus `plan_type`. Claude Code keeps no equivalent local data.
struct UsageCollector: Sendable {
    let sessionsDir: URL

    init(sessionsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")) {
        self.sessionsDir = sessionsDir
    }

    func codexUsage() -> ProviderUsage? {
        guard let rollout = latestRollout() else { return nil }
        return lastRateLimits(in: rollout)
    }

    // MARK: newest rollout

    /// The most-recently-modified rollout anywhere under sessions/. Picking by
    /// mtime (not folder date) correctly follows a long-running session whose
    /// file lives in an older day folder but is still being appended to.
    private func latestRollout() -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

        var best: (url: URL, date: Date)?
        for case let url as URL in en {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if best == nil || m > best!.date { best = (url, m) }
        }
        return best?.url
    }

    // MARK: parse

    private func lastRateLimits(in url: URL) -> ProviderUsage? {
        guard let data = readTail(url, maxBytes: 512 * 1024),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("rate_limits"), line.contains("used_percent"),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }

            func window(_ key: String) -> UsageWindow? {
                guard let w = rl[key] as? [String: Any],
                      let pct = (w["used_percent"] as? NSNumber)?.doubleValue,
                      let mins = (w["window_minutes"] as? NSNumber)?.intValue,
                      let reset = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
                return UsageWindow(usedPercent: pct, windowMinutes: mins,
                                   resetsAt: Date(timeIntervalSince1970: reset))
            }

            let ts = (obj["timestamp"] as? String).flatMap(Self.parseTimestamp) ?? Date()
            return ProviderUsage(
                source: .codex,
                plan: rl["plan_type"] as? String,
                short: window("primary"),
                long: window("secondary"),
                snapshotAt: ts
            )
        }
        return nil
    }

    private func readTail(_ url: URL, maxBytes: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        return try? h.readToEnd()
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
