import AppKit
import SwiftUI

/// Owns the desktop floating widget: a borderless, transparent, draggable
/// panel hosting DesktopWidgetView.
@MainActor
final class FloatingWidgetController: NSObject, NSWindowDelegate {
    private let store: BoardStore
    private var window: NSWindow?
    private let originKey = "widgetOrigin"
    /// false (default) → a normal window the active app covers; true → floats
    /// on top of everything.
    private var pinned = false

    init(store: BoardStore) {
        self.store = store
        super.init()
    }

    /// Unpinned → a normal draggable window that the app you're working in
    /// covers, so it never sits on top of everything. Pinned (📌) → floats
    /// above all windows and follows you across every space.
    private func applyLevel(_ window: NSWindow) {
        if pinned {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else {
            window.level = .normal
            window.collectionBehavior = [.stationary, .ignoresCycle]
        }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // A non-activating panel can be dragged to reposition without stealing
        // focus from the app you're working in.
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 324, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false                      // SwiftUI draws its own
        window.becomesKeyOnlyIfNeeded = true          // clicks/drags don't grab focus
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true     // drag anywhere
        applyLevel(window)

        let root = DesktopWidgetView(
            store: store,
            onClose: { [weak self] in self?.hide() },
            onTogglePin: { [weak self] in self?.togglePin() },
            onOpen: { [weak self] task in self?.open(task) },
            isPinned: pinned
        )
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor   // no gray frame
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.delegate = self

        if let saved = savedOrigin() {
            window.setFrameOrigin(saved)
        } else {
            positionTopRight(window)
        }
        window.orderFront(nil)
        self.window = window
    }

    // MARK: - position persistence

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        let o = window.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: originKey)
    }

    private func savedOrigin() -> NSPoint? {
        guard let xy = UserDefaults.standard.array(forKey: originKey) as? [Double],
              xy.count == 2 else { return nil }
        return NSPoint(x: xy[0], y: xy[1])
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    func toggle() {
        if window == nil { show() } else { hide() }
    }

    /// Bring the app that owns this session to the front, deep-linking to the
    /// specific session when the app supports it.
    private func open(_ task: AgentTask) {
        switch task.source {
        case .codex:
            // Codex exposes codex://threads/<id>, jumping straight to the thread.
            if let id = task.sessionId, !id.isEmpty,
               let url = URL(string: "codex://threads/\(id)") {
                NSWorkspace.shared.open(url)
            } else {
                foreground(bundleId: "com.openai.codex")
            }
        case .claudeCode:
            // The Claude desktop app has no public per-session deep link; the
            // best we can do is bring it to the front.
            foreground(bundleId: "com.anthropic.claudefordesktop")
        default:
            break
        }
    }

    private func foreground(bundleId: String) {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: bundleId) else { return }
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func togglePin() {
        pinned.toggle()
        if let window { applyLevel(window) }
        // re-host to reflect the pin icon state
        if let window {
            let root = DesktopWidgetView(
                store: store,
                onClose: { [weak self] in self?.hide() },
                onTogglePin: { [weak self] in self?.togglePin() },
                onOpen: { [weak self] task in self?.open(task) },
                isPinned: pinned
            )
            (window.contentView as? NSHostingView<DesktopWidgetView>)?.rootView = root
        }
    }

    private func positionTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(x: v.maxX - size.width - 24, y: v.maxY - size.height - 24)
        window.setFrameOrigin(origin)
    }
}
