import AppKit
import SwiftUI

/// Owns the desktop floating widget: a borderless, transparent, draggable
/// panel hosting DesktopWidgetView.
@MainActor
final class FloatingWidgetController: NSObject, NSWindowDelegate {
    private let store: BoardStore
    private let defaults: UserDefaults
    private var window: NSWindow?
    private let originKey = "widgetOrigin"
    /// false (default) → a normal window the active app covers; true → floats
    /// on top of everything.
    private var pinned = false

    /// Top-left anchor: the widget grows/shrinks downward from this fixed point
    /// instead of from AppKit's default bottom-left, so the top edge stays put
    /// as sessions are added or removed.
    private let topLeftKey = "widgetTopLeft"
    private var anchorTopLeft: NSPoint?
    private var lastWindowSize: NSSize?
    private var isRepositioning = false

    init(store: BoardStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
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
            positionAnchored(window)
            window.makeKeyAndOrderFront(nil)
            return
        }
        makeWindow().orderFront(nil)
    }

    /// Construct and lay out the panel separately from presenting it. This also
    /// lets AppKit integration tests exercise resizing without showing a window.
    func makeWindow() -> NSWindow {
        if let window { return window }
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
        // SwiftUI consumes mouse events for its content. Use an explicit native
        // header drag region instead of relying on background event forwarding.
        window.isMovableByWindowBackground = false
        applyLevel(window)

        let root = DesktopWidgetView(
            store: store,
            onClose: { [weak self] in self?.hide() },
            onTogglePin: { [weak self] in self?.togglePin() },
            onOpen: { task in SessionOpener.open(task) },
            onEndDragging: { [weak self] in self?.finishDragging() },
            isPinned: pinned
        )
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor   // no gray frame
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        self.window = window
        positionAnchored(window)
        window.delegate = self
        return window
    }

    // MARK: - position persistence

    func windowDidMove(_ notification: Notification) {
        guard let window, !isRepositioning else { return }
        // AppKit can report an origin change while SwiftUI changes the window's
        // size. That is a resize, not a user drag: keep the previous top edge.
        guard window.frame.size == lastWindowSize else { return }
        let f = window.frame
        let tl = NSPoint(x: f.minX, y: f.maxY)
        anchorTopLeft = tl
        defaults.set([Double(tl.x), Double(tl.y)], forKey: topLeftKey)
    }

    /// Keep the top edge fixed when the content (and thus the window) resizes.
    func windowDidResize(_ notification: Notification) {
        guard let window, !isRepositioning else { return }
        positionAnchored(window)
    }

    /// Place the window so its top-left sits at the saved anchor (migrating an
    /// old bottom-left origin if present), then remember that anchor.
    private func positionAnchored(_ window: NSWindow) {
        let requested = anchorTopLeft ?? WidgetWindowPlacement.restoredTopLeft(
            savedTopLeft: defaults.array(forKey: topLeftKey) as? [Double],
            savedOrigin: defaults.array(forKey: originKey) as? [Double],
            size: window.frame.size
        )
        // Prefer the active screen for a first launch; preserve a valid saved
        // position on any other screen. The view already supplies 24pt padding.
        let screens = NSScreen.screens
        let frames = ([NSScreen.main].compactMap { $0 } + screens.filter { $0 != NSScreen.main })
            .map(\.visibleFrame)
        let tl = WidgetWindowPlacement.constrainedTopLeft(
            requested, size: window.frame.size, visibleFrames: frames
        )
        isRepositioning = true
        window.setFrameOrigin(NSPoint(x: tl.x, y: tl.y - window.frame.height))
        isRepositioning = false
        let frame = window.frame
        anchorTopLeft = NSPoint(x: frame.minX, y: frame.maxY)
        lastWindowSize = frame.size
        defaults.set([Double(frame.minX), Double(frame.maxY)], forKey: topLeftKey)
    }

    private func finishDragging() {
        guard let window else { return }
        // Read the final frame directly as well: the move notification may be
        // delivered after AppKit's native drag loop returns.
        anchorTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        positionAnchored(window)
    }

    @objc private func screenParametersDidChange() {
        guard let window else { return }
        positionAnchored(window)
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
                onOpen: { task in SessionOpener.open(task) },
                onEndDragging: { [weak self] in self?.finishDragging() },
                isPinned: pinned
            )
            (window.contentView as? NSHostingView<DesktopWidgetView>)?.rootView = root
        }
    }
}

/// Pure placement rules, including disconnected displays and oversized content.
enum WidgetWindowPlacement {
    static func restoredTopLeft(savedTopLeft: [Double]?, savedOrigin: [Double]?, size: NSSize) -> NSPoint? {
        func point(_ values: [Double]?) -> NSPoint? {
            guard let values, values.count == 2, values.allSatisfy(\.isFinite) else { return nil }
            return NSPoint(x: values[0], y: values[1])
        }
        if let topLeft = point(savedTopLeft) { return topLeft }
        guard let origin = point(savedOrigin) else { return nil }
        return NSPoint(x: origin.x, y: origin.y + size.height)
    }

    static func constrainedTopLeft(_ requested: NSPoint?, size: NSSize, visibleFrames: [NSRect]) -> NSPoint {
        guard let first = visibleFrames.first else {
            return requested ?? NSPoint(x: 0, y: size.height)
        }
        guard let requested, requested.x.isFinite, requested.y.isFinite else {
            return NSPoint(x: max(first.minX, first.maxX - size.width), y: first.maxY)
        }
        // Anchor ownership keeps a tall widget on the screen carrying its header.
        // If that display disappeared, choose the closest remaining screen.
        func distance(to frame: NSRect) -> CGFloat {
            let dx = max(frame.minX - requested.x, 0, requested.x - frame.maxX)
            let dy = max(frame.minY - requested.y, 0, requested.y - frame.maxY)
            return dx * dx + dy * dy
        }
        let screen = visibleFrames.min { distance(to: $0) < distance(to: $1) } ?? first
        return NSPoint(
            x: min(max(requested.x, screen.minX), max(screen.minX, screen.maxX - size.width)),
            y: min(max(requested.y, screen.minY + min(size.height, screen.height)), screen.maxY)
        )
    }
}
