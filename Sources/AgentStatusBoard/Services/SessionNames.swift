import Foundation

/// User-editable display-name overrides, read from
/// ~/.agent-status-board/names.json — a flat `{ "<key>": "<name>" }` map.
///
/// A key is matched one of two ways:
///   • **Path key** (starts with `/` or `~`): the name applies to any session
///     whose working directory is at or under that path. Longest match wins.
///   • **Session-id key** (anything else, e.g. a CC/Codex session UUID): the
///     name applies to exactly that one session. Session-id matches take
///     precedence over path matches.
///
/// Why both exist — and why this is the ONLY way to show some names:
/// Claude Code stores NO short human title for a session unless the user
/// explicitly renames it (a `custom-title` entry). An un-renamed session only
/// has the verbose auto `ai-title` (e.g. "建立知识库会议纪要管理系统") and the
/// folder name — so the short name a user thinks the session by (e.g. "会议纪要")
/// often lives nowhere on disk. This map is the only place to pin it. A path
/// key cannot distinguish several sessions sharing one folder (e.g. ~/LinkView
/// hosting four different CC sessions); a session-id key can, so prefer it when
/// a folder holds more than one workstream.
struct SessionNames: Sendable {
    private let pathEntries: [(path: String, name: String)]   // cwd prefix match
    private let idEntries: [String: String]                   // exact session-id match

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-status-board/names.json")) {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            pathEntries = []
            idEntries = [:]
            return
        }
        var paths: [(path: String, name: String)] = []
        var ids: [String: String] = [:]
        for (key, value) in dict where !value.isEmpty {
            if key.hasPrefix("/") || key.hasPrefix("~") {
                paths.append((path: Self.normalize(key), name: value))
            } else {
                ids[key] = value
            }
        }
        // Longest path first so the most specific mapping wins.
        pathEntries = paths.sorted { $0.path.count > $1.path.count }
        idEntries = ids
    }

    /// The pinned name for an exact session id, or nil if unmapped. Takes
    /// precedence over `name(forCwd:)` — one folder may host several differently
    /// named sessions, which a cwd match cannot tell apart.
    func name(forSessionId id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return idEntries[id]
    }

    /// The override name for a working directory, or nil if unmapped.
    func name(forCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let c = Self.normalize(cwd)
        for e in pathEntries where c == e.path || c.hasPrefix(e.path + "/") {
            return e.name
        }
        return nil
    }

    private static func normalize(_ p: String) -> String {
        var s = (p as NSString).expandingTildeInPath
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
