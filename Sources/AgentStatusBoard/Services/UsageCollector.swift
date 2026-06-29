import Foundation
import os

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

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AgentStatusBoard", category: "usage")

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

    // MARK: Claude Code (live, via unified rate-limit response headers)

    /// Claude Code keeps no local usage cache, and its /api/oauth/usage needs a
    /// broader scope than a setup-token grants. But the 5-hour and weekly
    /// utilization come back as `anthropic-ratelimit-unified-*` headers on any
    /// inference call — which an inference-scoped token CAN make. So we send a
    /// max_tokens:1 ping to /v1/messages (negligible cost) and read the headers.
    /// Token: ~/.agent-status-board/cc-token.json (from `claude setup-token`).
    func claudeUsage() async -> ProviderUsage? {
        guard let token = claudeToken() else { return nil }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data(#"{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}"#.utf8)

        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }

        func window(_ tag: String, _ minutes: Int) -> UsageWindow? {
            guard let util = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-\(tag)-utilization").flatMap(Double.init),
                  let reset = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-\(tag)-reset").flatMap(Double.init)
            else { return nil }
            return UsageWindow(usedPercent: util * 100, windowMinutes: minutes,
                               resetsAt: Date(timeIntervalSince1970: reset))
        }

        let short = window("5h", 300)
        let long = window("7d", 10080)
        guard short != nil || long != nil else { return nil }   // 401/403/no headers
        return ProviderUsage(source: .claudeCode, plan: claudePlan(),
                             short: short, long: long, snapshotAt: Date())
    }

    private func claudeToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-status-board/cc-token.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let t = (obj["token"] as? String) ?? (obj["access_token"] as? String)
        return (t?.isEmpty == false) ? t : nil
    }

    /// Best-effort plan label from Claude Code's own config (e.g. "claude_max").
    private func claudePlan() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oa = obj["oauthAccount"] as? [String: Any] else { return nil }
        return oa["organizationType"] as? String
    }

    // MARK: Codex (live, via the ChatGPT backend usage endpoint)

    /// Codex's live usage — a free GET to the ChatGPT backend that its own CLI
    /// uses (`/backend-api/wham/usage`), authed with the chatgpt-mode token in
    /// ~/.codex/auth.json. Far more accurate than the rollout snapshot, which
    /// only updates when Codex runs. Returns nil on any failure (caller then
    /// falls back to the local snapshot).
    func codexUsageLive() async -> ProviderUsage? {
        guard let (token, account) = codexAuth() else {
            Self.log.error("codex live: no auth token"); return nil
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !account.isEmpty { req.setValue(account, forHTTPHeaderField: "chatgpt-account-id") }
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else {
            Self.log.error("codex live: request failed (network/proxy)"); return nil
        }
        guard http.statusCode == 200 else {
            Self.log.error("codex live: HTTP \(http.statusCode, privacy: .public)"); return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.log.error("codex live: bad JSON body"); return nil
        }

        let rl = obj["rate_limit"] as? [String: Any]
        func window(_ key: String) -> UsageWindow? {
            guard let w = rl?[key] as? [String: Any],
                  let pct = (w["used_percent"] as? NSNumber)?.doubleValue,
                  let secs = (w["limit_window_seconds"] as? NSNumber)?.intValue,
                  let reset = (w["reset_at"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(usedPercent: pct, windowMinutes: secs / 60,
                               resetsAt: Date(timeIntervalSince1970: reset))
        }
        let short = window("primary_window")
        let long = window("secondary_window")
        guard short != nil || long != nil else { Self.log.error("codex live: no windows parsed"); return nil }
        Self.log.info("codex live OK: 5h used \(Int(short?.usedPercent ?? -1), privacy: .public)%, weekly used \(Int(long?.usedPercent ?? -1), privacy: .public)%")
        return ProviderUsage(source: .codex, plan: obj["plan_type"] as? String,
                             short: short, long: long, snapshotAt: Date())
    }

    private func codexAuth() -> (token: String, account: String)? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return (token, (tokens["account_id"] as? String) ?? "")
    }
}
