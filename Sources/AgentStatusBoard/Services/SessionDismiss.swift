import Foundation

/// Manually closing out a session from the board: "忽略，标为完成".
///
/// The needs-you (red) verdict is partly an LLM call (`classify.py`), so it is
/// sometimes wrong — a session that merely ended with a few suggestions gets
/// flagged as waiting on you. Rather than leaving the board permanently red,
/// the row's context menu writes `done` straight into the hook's own state file
/// (~/.agent-status-board/sessions/<key>.json, the path carried by
/// `AgentTask.evidence`). The collector re-reads that file on the next refresh,
/// so the row moves to 最近完成 with no extra state to keep anywhere.
///
/// The record is rewritten field-by-field through a plain JSON dictionary — NOT
/// through a typed model — so any key the hooks add later (or that this build
/// doesn't know about) survives untouched.
enum SessionDismiss {
    /// Marks the session record at `recordPath` as finished.
    ///
    /// Sets `status` to `done` and `updatedAt` to now, leaves every other field
    /// exactly as it was, and swaps the file in atomically (temp file + rename)
    /// so a hook writing at the same moment can never observe a half-written
    /// record. Never throws: any problem (missing file, unreadable JSON, a
    /// read-only directory) just returns false and leaves the file alone.
    ///
    /// - Parameter now: injected for tests; defaults to the current time.
    @discardableResult
    static func dismiss(recordPath: String, now: Date = Date()) -> Bool {
        guard !recordPath.isEmpty else { return false }
        let url = URL(fileURLWithPath: recordPath)
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              var record = parsed as? [String: Any] else {
            return false
        }

        record["status"] = AgentTaskStatus.done.rawValue
        record["updatedAt"] = timestamp(now)

        guard let encoded = try? JSONSerialization.data(
            withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return false }

        // Sibling temp file (same volume, so the swap is a rename), hidden and
        // without a .json extension so a refresh mid-write can't pick it up as a
        // session record.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).dismiss-\(UUID().uuidString)")
        do {
            try encoded.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// ISO8601 with fractional seconds in UTC — the shape
    /// `JSONDecoder.DateDecodingStrategy.iso8601WithFractionalSeconds` reads
    /// (it accepts the hooks' whole-second form too).
    private static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
