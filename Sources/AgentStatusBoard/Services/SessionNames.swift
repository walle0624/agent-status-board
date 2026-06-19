import Foundation

/// User-editable display-name overrides, read from
/// ~/.agent-status-board/names.json — a flat `{ "<path>": "<name>" }` map.
/// A session whose working directory is at or under a mapped path shows that
/// name instead of the folder basename. Longest matching path wins.
///
/// Claude Code does not store a human session title anywhere, so this is the
/// only reliable way to show the name a user thinks of a session by.
struct SessionNames: Sendable {
    private let entries: [(path: String, name: String)]

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-status-board/names.json")) {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            entries = []
            return
        }
        // Longest path first so the most specific mapping wins.
        entries = dict
            .map { (path: Self.normalize($0.key), name: $0.value) }
            .sorted { $0.path.count > $1.path.count }
    }

    /// Returns the override name for a working directory, or nil if unmapped.
    func name(forCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let c = Self.normalize(cwd)
        for e in entries where c == e.path || c.hasPrefix(e.path + "/") {
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
