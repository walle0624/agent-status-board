import AppKit
import SwiftUI
import Testing
@testable import AgentStatusBoard

private let widgetSize = NSSize(width: 360, height: 400)
private let laptopVisibleFrame = NSRect(x: 0, y: 81, width: 1512, height: 868)

@Test func widgetDefaultsToTopRightWithoutDoublePadding() {
    let topLeft = WidgetWindowPlacement.constrainedTopLeft(
        nil, size: widgetSize, visibleFrames: [laptopVisibleFrame]
    )
    #expect(topLeft == NSPoint(x: 1152, y: 949))
}

@Test func widgetPreservesAnOnscreenUserPosition() {
    let saved = NSPoint(x: 700, y: 800)
    #expect(WidgetWindowPlacement.constrainedTopLeft(
        saved, size: widgetSize, visibleFrames: [laptopVisibleFrame]
    ) == saved)
}

@Test func widgetMigratesLegacyOriginAndRejectsInvalidAnchors() {
    #expect(WidgetWindowPlacement.restoredTopLeft(
        savedTopLeft: [1152, 898], savedOrigin: [1156, 577], size: widgetSize
    ) == NSPoint(x: 1152, y: 898))
    #expect(WidgetWindowPlacement.restoredTopLeft(
        savedTopLeft: [.nan, 898], savedOrigin: [700, 400], size: widgetSize
    ) == NSPoint(x: 700, y: 800))
    #expect(WidgetWindowPlacement.restoredTopLeft(
        savedTopLeft: [12], savedOrigin: [700, .infinity], size: widgetSize
    ) == nil)
}

@Test func widgetRecoversFromDisconnectedDisplay() {
    let oldDisplayPosition = NSPoint(x: -1200, y: 1300)
    let recovered = WidgetWindowPlacement.constrainedTopLeft(
        oldDisplayPosition, size: widgetSize, visibleFrames: [laptopVisibleFrame]
    )
    #expect(recovered == NSPoint(x: 0, y: 949))
    #expect(laptopVisibleFrame.contains(NSRect(
        x: recovered.x, y: recovered.y - widgetSize.height,
        width: widgetSize.width, height: widgetSize.height
    )))
}

@Test func widgetKeepsItsHeaderOnTheChosenSecondaryDisplay() {
    let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
    let saved = NSPoint(x: -700, y: 950)
    #expect(WidgetWindowPlacement.constrainedTopLeft(
        saved, size: widgetSize, visibleFrames: [laptopVisibleFrame, secondary]
    ) == saved)
}

@Test func widgetGrowthKeepsTopEdgeUntilScreenBoundsRequireAdjustment() {
    let saved = NSPoint(x: 700, y: 800)
    let taller = WidgetWindowPlacement.constrainedTopLeft(
        saved, size: NSSize(width: 360, height: 600), visibleFrames: [laptopVisibleFrame]
    )
    #expect(taller == saved)
    let low = NSPoint(x: 700, y: 500)
    let corrected = WidgetWindowPlacement.constrainedTopLeft(
        low, size: NSSize(width: 360, height: 600), visibleFrames: [laptopVisibleFrame]
    )
    #expect(corrected == NSPoint(x: 700, y: 681))
    #expect(WidgetWindowPlacement.constrainedTopLeft(
        corrected, size: widgetSize, visibleFrames: [laptopVisibleFrame]
    ) == corrected)
}

@Test func oversizedWidgetKeepsItsHeaderReachable() {
    #expect(WidgetWindowPlacement.constrainedTopLeft(
        NSPoint(x: 700, y: 500), size: NSSize(width: 2000, height: 1600),
        visibleFrames: [laptopVisibleFrame]
    ) == NSPoint(x: 0, y: 949))
}

@MainActor
private func dragHandle(in view: NSView) -> WidgetDragHandleView? {
    if let handle = view as? WidgetDragHandleView { return handle }
    return view.subviews.lazy.compactMap { dragHandle(in: $0) }.first
}

@MainActor
private final class DragProbePanel: NSPanel {
    var draggedEvent: NSEvent?
    override func performDrag(with event: NSEvent) { draggedEvent = event }
}

@Suite(.serialized)
@MainActor
struct WidgetDragTests {
    @Test func headerDragRegionDoesNotCoverButtonsOrContent() async throws {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: widgetSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: DesktopWidgetView(store: BoardStore(collectors: [])))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        // The root fades/scales in on appearance; wait for that one animation
        // before measuring the actual hit region.
        try await Task.sleep(for: .milliseconds(700))
        hosting.layoutSubtreeIfNeeded()
        let handle = try #require(dragHandle(in: hosting))
        let rect = hosting.convert(handle.bounds, from: handle)
        func hit(_ local: NSPoint) -> NSView? {
            // AppKit hitTest takes parent coordinates; the SwiftUI host is
            // flipped while NSThemeFrame is not.
            hosting.hitTest(hosting.convert(local, to: hosting.superview))
        }
        #expect(rect.width > 100)
        #expect(rect.height >= 22)
        let receivesHeaderMouse = hit(NSPoint(x: rect.midX, y: rect.midY)) === handle
        #expect(receivesHeaderMouse)
        // Pin to the left; refresh/close to the right. Neither is under the handle.
        #expect(hit(NSPoint(x: rect.minX - 12, y: rect.midY)) !== handle)
        #expect(hit(NSPoint(x: rect.maxX + 12, y: rect.midY)) !== handle)
        #expect(hit(NSPoint(x: rect.midX, y: hosting.bounds.midY)) !== handle)
    }

    @Test func popoverDoesNotInstallAWindowDragRegion() {
        let hosting = NSHostingView(rootView: DesktopWidgetView(
            store: BoardStore(collectors: []), inPopover: true
        ))
        hosting.setFrameSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        #expect(dragHandle(in: hosting) == nil)
    }

    @Test func dragTracksEventsAndCompletesOnlyAfterMouseRelease() throws {
        let panel = DragProbePanel(
            contentRect: NSRect(origin: .zero, size: widgetSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        let handle = WidgetDragHandleView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        panel.contentView = handle
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 40, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        var finished = false
        var pressed = true
        handle.leftMouseIsPressed = { pressed }
        handle.onEndDragging = {
            finished = true
        }
        #expect(handle.acceptsFirstMouse(for: event))
        handle.mouseDown(with: event)
        #expect(panel.draggedEvent == nil)
        #expect(!finished)
        #expect(handle.isDragging)
        let origin = panel.frame.origin
        let moved = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 70, y: 40), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 1
        ))
        handle.mouseDragged(with: moved)
        #expect(panel.frame.origin == NSPoint(x: origin.x + 30, y: origin.y + 30))
        handle.completeDragIfMouseReleased()
        #expect(!finished)
        pressed = false
        handle.completeDragIfMouseReleased()
        #expect(finished)
        #expect(!handle.isDragging)
    }

    @Test func syntheticMouseEventsDoNotFinishBeforeMouseUp() throws {
        let panel = DragProbePanel(
            contentRect: NSRect(origin: .zero, size: widgetSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        let handle = WidgetDragHandleView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        panel.contentView = handle
        handle.leftMouseIsPressed = { false }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 40, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        var completed = false
        handle.onEndDragging = { completed = true }
        handle.mouseDown(with: event)
        handle.completeDragIfMouseReleased()
        #expect(handle.isDragging)
        #expect(!completed)
        handle.mouseUp(with: event)
        #expect(completed)
        #expect(!handle.isDragging)
    }

    @Test func removingDragHandleCancelsWithoutSavingAPartialPosition() throws {
        let panel = DragProbePanel(
            contentRect: NSRect(origin: .zero, size: widgetSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        let handle = WidgetDragHandleView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        panel.contentView = handle
        handle.leftMouseIsPressed = { true }
        var finished = false
        handle.onEndDragging = { finished = true }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 40, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        handle.mouseDown(with: event)
        handle.viewWillMove(toWindow: nil)
        #expect(!handle.isDragging)
        #expect(!finished)
    }

    @Test func movedAnchorPersistsAndResizeNotificationsCannotOverwriteIt() throws {
        let suite = "asb-widget-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let screen = try #require(NSScreen.main).visibleFrame
        let original = NSPoint(x: screen.minX + 100, y: screen.maxY - 40)
        defaults.set([original.x, original.y], forKey: "widgetTopLeft")
        let controller = FloatingWidgetController(store: BoardStore(collectors: []), defaults: defaults)
        let window = controller.makeWindow()
        defer { controller.hide() }
        #expect(window.frame.maxY == original.y)

        let moved = NSPoint(x: original.x + 40, y: original.y - 20)
        let expected = [Double(moved.x), Double(moved.y)]
        window.delegate = nil
        window.setFrameOrigin(NSPoint(x: moved.x, y: moved.y - window.frame.height))
        window.delegate = controller
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let handle = try #require(dragHandle(in: content))
        // The native drag completion also saves the final frame when AppKit's
        // move notification has not arrived yet.
        handle.onEndDragging()
        #expect(defaults.array(forKey: "widgetTopLeft") as? [Double] == expected)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(defaults.array(forKey: "widgetTopLeft") as? [Double] == expected)

        // Reproduce the move-before-resize callback order without showing the
        // panel. An automatic size change must never become a saved user drag.
        window.delegate = nil
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(
            width: window.frame.width, height: window.frame.height + 100
        )), display: false)
        window.delegate = controller
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(defaults.array(forKey: "widgetTopLeft") as? [Double] == expected)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(window.frame.maxY == moved.y)
        #expect(defaults.array(forKey: "widgetTopLeft") as? [Double] == expected)
    }
}
