import AppKit

/// Brings the app that owns a session to the front, deep-linking to the
/// specific session when the app supports it. Shared by the desktop widget and
/// the menu-bar popover so a click behaves the same in both.
@MainActor
enum SessionOpener {
    static func open(_ task: AgentTask) {
        switch task.source {
        case .codex:
            // Codex exposes codex://threads/<id>, jumping straight to the thread.
            if let id = task.sessionId, !id.isEmpty,
               let url = URL(string: "codex://threads/\(id)") {
                NSWorkspace.shared.open(url)
            } else {
                foreground("com.openai.codex")
            }
        case .claudeCode:
            // The Claude desktop app has no public per-session deep link; bring
            // it to the front.
            foreground("com.anthropic.claudefordesktop")
        default:
            break
        }
    }

    private static func foreground(_ bundleId: String) {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: bundleId) else { return }
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
