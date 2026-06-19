import AppKit
import SwiftUI

/// Owns the desktop floating widget: a borderless, transparent, draggable,
/// always-on-top window hosting DesktopWidgetView.
@MainActor
final class FloatingWidgetController: NSObject, NSWindowDelegate {
    private let store: BoardStore
    private var window: NSWindow?
    private let originKey = "widgetOrigin"
    /// false (default) → sits on the desktop behind other windows, like a macOS
    /// desktop widget; true → floats on top of everything.
    private var pinned = false

    /// Just above the wallpaper, below all normal app windows.
    private let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

    init(store: BoardStore) {
        self.store = store
        super.init()
    }

    private func applyLevel(_ window: NSWindow) {
        window.level = pinned ? .floating : desktopLevel
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 324, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false                      // SwiftUI draws its own
        applyLevel(window)
        window.isMovableByWindowBackground = true     // drag anywhere
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let root = DesktopWidgetView(
            store: store,
            onClose: { [weak self] in self?.hide() },
            onTogglePin: { [weak self] in self?.togglePin() },
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

    private func togglePin() {
        pinned.toggle()
        if let window { applyLevel(window) }
        // re-host to reflect the pin icon state
        if let window {
            let root = DesktopWidgetView(
                store: store,
                onClose: { [weak self] in self?.hide() },
                onTogglePin: { [weak self] in self?.togglePin() },
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
