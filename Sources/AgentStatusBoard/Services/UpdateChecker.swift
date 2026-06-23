import Foundation

/// Source self-update: checks the GitHub repo this app was built from (recorded
/// by install.sh in ~/.agent-status-board/update.json) for a newer `VERSION`,
/// and can launch the local update script (git pull + rebuild + reinstall +
/// relaunch). No code-signing / notarization needed — the app is built locally.
struct UpdateChecker: Sendable {
    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-status-board/update.json")
    }

    private func config() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// The newer version string if the remote `VERSION` is ahead of this app,
    /// else nil. Reads raw.githubusercontent.com (works for public repos).
    func latestIfNewer() async -> String? {
        guard let cfg = config(),
              let owner = cfg["owner"] as? String,
              let repo = cfg["repo"] as? String else { return nil }
        let branch = (cfg["branch"] as? String) ?? "main"
        guard let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/VERSION")
        else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let remote = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty
        else { return nil }
        return Self.isNewer(remote, than: currentVersion) ? remote : nil
    }

    /// Launch the detached update script. It outlives this app being killed
    /// mid-rebuild (it isn't named "AgentStatusBoard", so the script's own
    /// pkill won't hit it) and relaunches the freshly-built app when done.
    func runUpdate() {
        guard let cfg = config(), let checkout = cfg["checkout"] as? String else { return }
        let script = "\(checkout)/script/update.sh"
        guard FileManager.default.fileExists(atPath: script) else { return }
        // Run a temp copy of the updater (passing the checkout dir) so it isn't
        // clobbered when it refreshes the source tree mid-update.
        let cmd = "cp \(quote(script)) /tmp/asb-update.sh && nohup bash /tmp/asb-update.sh \(quote(checkout)) > /tmp/asb-update.log 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        try? p.run()
    }

    private func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Numeric, dot-separated version comparison: a > b ?
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
