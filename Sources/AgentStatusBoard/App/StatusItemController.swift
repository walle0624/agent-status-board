import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Custom NSStatusItem that renders the three-LED pill and animates it every
/// frame (marquee / breathing / flashing). SwiftUI's MenuBarExtra label is a
/// static snapshot and cannot animate, so we draw the icon ourselves.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: BoardStore
    private let onSummon: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var animationTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    // LED colors (kept vivid so they read on light and dark menu bars).
    private let red = NSColor(srgbRed: 0.886, green: 0.294, blue: 0.290, alpha: 1)
    private let amber = NSColor(srgbRed: 0.937, green: 0.624, blue: 0.153, alpha: 1)
    private let green = NSColor(srgbRed: 0.388, green: 0.600, blue: 0.133, alpha: 1)

    init(store: BoardStore, onSummon: @escaping () -> Void = {}) {
        self.store = store
        self.onSummon = onSummon
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView(store: store, onSummon: { [weak self] in
                self?.popover.performClose(nil)
                self?.onSummon()
            }).frame(width: 360)
        )

        // Redraw on data changes immediately, plus a steady frame timer for animation.
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.redraw() }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        redraw()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Drawing

    private func redraw() {
        let status = store.snapshot.overallStatus
        let count = store.snapshot.liveCount()
        statusItem.button?.image = renderImage(status: status, count: count, time: CACurrentMediaTime())
    }

    /// Aggregate state → one dot color + an animated alpha (flash / breathe).
    private func dotStyle(_ status: BoardOverallStatus, _ t: Double) -> (color: NSColor, alpha: CGFloat) {
        func breathe(_ period: Double) -> CGFloat { CGFloat(0.5 + 0.5 * sin(2 * .pi * t / period)) }
        switch status {
        case .idle:           return (NSColor.secondaryLabelColor, 0.45)
        case .needsAttention:
            let on = t.truncatingRemainder(dividingBy: 0.6) < 0.3      // ~1.7 Hz flash
            return (red, on ? 1.0 : 0.4)
        case .running:        return (amber, 0.6 + 0.4 * breathe(1.1))
        case .thinking:       return (amber, 0.45 + 0.5 * breathe(1.7))
        case .done:           return (green, 1.0)
        }
    }

    /// A single glossy status sphere (radial highlight + faint rim) plus the
    /// active-session count — cleaner in the menu bar than three flat dots.
    private func renderImage(status: BoardOverallStatus, count: Int, time t: Double) -> NSImage {
        let d: CGFloat = 12
        let h: CGFloat = 18
        let padX: CGFloat = 5
        let showCount = count > 0
        let countText = showCount ? "\(count)" : ""
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textWidth: CGFloat = showCount
            ? (countText as NSString).size(withAttributes: [.font: font]).width + 4 : 0
        let w = padX * 2 + d + textWidth

        let (color, alpha) = dotStyle(status, t)
        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        let rect = NSRect(x: padX, y: (h - d) / 2, width: d, height: d)

        // Glossy sphere: radial gradient, highlight pulled to the upper-left.
        let top = NSColor.white.withAlphaComponent(0.55 * alpha)
        let mid = color.withAlphaComponent(alpha)
        let bottom = (color.blended(withFraction: 0.22, of: .black) ?? color).withAlphaComponent(alpha)
        NSGradient(colors: [top, mid, bottom])?
            .draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: NSPoint(x: -0.32, y: 0.4))
        NSColor.black.withAlphaComponent(0.18 * alpha).setStroke()
        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 0.4, dy: 0.4)); rim.lineWidth = 0.6; rim.stroke()

        if showCount {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let size = (countText as NSString).size(withAttributes: attrs)
            (countText as NSString).draw(at: NSPoint(x: padX + d + 4, y: (h - size.height) / 2), withAttributes: attrs)
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
