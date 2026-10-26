import Foundation
import Darwin

struct UpdateProgress: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case starting, checking, downloading, building, installing, refreshing, completed, failed
    }
    var phase: Phase
    var version: String = ""
    var updatedAt: Double
    var exitCode: Int?
    var failedPhase: String?
    var pid: Int32?

    var isRunning: Bool { phase != .completed && phase != .failed }
    var message: String {
        switch phase {
        case .starting: "正在启动更新…"
        case .checking: "正在检查更新…"
        case .downloading: "正在下载更新…"
        case .building: "正在编译更新，请稍候…"
        case .installing: "正在安装并重启…"
        case .refreshing: "正在完成更新…"
        case .completed: "更新已完成"
        case .failed:
            exitCode == 75 ? "另一个更新正在进行，请稍后重试" : "更新失败\(exitCode.map { "（退出码 \($0)）" } ?? "") · 点击重试"
        }
    }
}

struct UpdateAttempt: Codable, Sendable {
    let label: String
    let statusURL: URL
    let logURL: URL
    let jobURL: URL
    let startedAt: Date

    func progress() -> UpdateProgress? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder().decode(UpdateProgress.self, from: data)
    }

    func updaterIsAlive(_ progress: UpdateProgress) -> Bool {
        guard let pid = progress.pid, pid > 0 else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

enum UpdateLaunchError: Error, LocalizedError {
    case configuration, scriptMissing, launchFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .configuration: "更新来源尚未配置，请重新安装组件"
        case .scriptMissing: "找不到更新程序，请重新安装组件"
        case .launchFailed(let code): "无法启动更新（退出码 \(code)），请重试"
        }
    }
}

/// Source self-update: checks the GitHub repo this app was built from (recorded
/// by install.sh in ~/.agent-status-board/update.json) for a newer `VERSION`,
/// and launches its bundled updater (source archive + rebuild + reinstall +
/// relaunch). The rebuilt app receives a local ad-hoc signature.
struct UpdateChecker: Sendable {
    let configURL: URL
    let runtimeDirectory: URL
    private let bundledUpdaterURL: URL?

    init(configURL: URL? = nil, runtimeDirectory: URL? = nil, bundledUpdaterURL: URL? = nil) {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-status-board")
        self.configURL = configURL ?? base.appendingPathComponent("update.json")
        self.runtimeDirectory = runtimeDirectory ?? base.appendingPathComponent("updates")
        self.bundledUpdaterURL = bundledUpdaterURL ?? Bundle.main.url(forResource: "update", withExtension: "sh")
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

    /// A separate launchd job survives restarting/re-registering the app's job.
    /// nohup alone does not provide that isolation.
    func runUpdate() throws -> UpdateAttempt {
        let attempt = try prepareUpdate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootstrap", "gui/\(getuid())", attempt.jobURL.path]
        let log = try FileHandle(forWritingTo: attempt.logURL)
        defer { try? log.close() }
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        do { try p.run() }
        catch {
            try? write(UpdateProgress(phase: .failed, updatedAt: Date().timeIntervalSince1970,
                                      failedPhase: "starting"), to: attempt.statusURL)
            throw error
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? write(UpdateProgress(phase: .failed, updatedAt: Date().timeIntervalSince1970,
                                      exitCode: Int(p.terminationStatus), failedPhase: "starting"), to: attempt.statusURL)
            throw UpdateLaunchError.launchFailed(p.terminationStatus)
        }
        return attempt
    }

    /// Prepare without launching so tests can inspect paths/permissions safely.
    func prepareUpdate(now: Date = Date()) throws -> UpdateAttempt {
        guard let cfg = config(), let checkout = cfg["checkout"] as? String,
              checkout.hasPrefix("/"), !checkout.isEmpty else { throw UpdateLaunchError.configuration }
        // Git installations deliberately keep their checkout unchanged during
        // self-update. Ship the updater with the app so the next upgrade never
        // goes back to an older checkout's updater.
        let source = bundledUpdaterURL ?? URL(fileURLWithPath: checkout).appendingPathComponent("script/update.sh")
        guard FileManager.default.fileExists(atPath: source.path) else { throw UpdateLaunchError.scriptMissing }
        let id = UUID().uuidString.lowercased()
        let directory = runtimeDirectory.appendingPathComponent(id)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("update.sh")
        try fm.copyItem(at: source, to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let attempt = UpdateAttempt(label: "ai.linkingdigital.AgentStatusBoard.update.\(id)",
                                    statusURL: directory.appendingPathComponent("status.json"),
                                    logURL: directory.appendingPathComponent("update.log"),
                                    jobURL: directory.appendingPathComponent("job.plist"), startedAt: now)
        try write(UpdateProgress(phase: .starting, updatedAt: now.timeIntervalSince1970), to: attempt.statusURL)
        try Data().write(to: attempt.logURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: attempt.logURL.path)
        var environment = ["ASB_UPDATE_STATUS_FILE": attempt.statusURL.path,
                           "ASB_UPDATE_RUNNING_VERSION": currentVersion,
                           "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        let job: [String: Any] = ["Label": attempt.label,
                                 "ProgramArguments": ["/bin/bash", script.path, checkout],
                                 "RunAtLoad": true, "KeepAlive": false, "ProcessType": "Background",
                                 "EnvironmentVariables": environment,
                                 "StandardOutPath": attempt.logURL.path, "StandardErrorPath": attempt.logURL.path]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try data.write(to: attempt.jobURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: attempt.jobURL.path)
        try write(attempt, to: runtimeDirectory.appendingPathComponent("active.json"))
        return attempt
    }

    func currentAttempt() -> UpdateAttempt? {
        guard let data = try? Data(contentsOf: runtimeDirectory.appendingPathComponent("active.json")) else { return nil }
        return try? JSONDecoder().decode(UpdateAttempt.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
