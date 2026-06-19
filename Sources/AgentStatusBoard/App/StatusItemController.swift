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

    private func alphas(for status: BoardOverallStatus, time t: Double) -> (Double, Double, Double) {
        let dim = 0.18
        func wave(_ period: Double, _ phase: Double = 0) -> Double {
            0.35 + 0.55 * (0.5 + 0.5 * sin(2 * .pi * t / period + phase))
        }
        switch status {
        case .idle:
            return (dim, dim, dim)
        case .needsAttention:
            let on = t.truncatingRemainder(dividingBy: 0.5) < 0.25   // 2Hz flash
            return (on ? 1.0 : 0.25, dim, dim)
        case .running:
            return (dim, wave(0.9), wave(0.9, .pi))                   // amber/green marquee
        case .thinking:
            return (dim, 0.30 + 0.70 * (0.5 + 0.5 * sin(2 * .pi * t / 1.5)), dim)
        case .done:
            return (dim, dim, 1.0)
        }
    }

    private func renderImage(status: BoardOverallStatus, count: Int, time: Double) -> NSImage {
        let d: CGFloat = 8                 // LED diameter
        let gap: CGFloat = 5
        let padX: CGFloat = 6
        let h: CGFloat = 18
        let ledsWidth = d * 3 + gap * 2
        let showCount = count > 0
        let countText = showCount ? "\(count)" : ""
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textWidth: CGFloat = showCount
            ? (countText as NSString).size(withAttributes: [.font: font]).width + 5
            : 0
        let w = padX * 2 + ledsWidth + textWidth

        let (ra, aa, ga) = alphas(for: status, time: time)
        let colors = [red.withAlphaComponent(ra), amber.withAlphaComponent(aa), green.withAlphaComponent(ga)]

        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        let y = (h - d) / 2
        for (i, color) in colors.enumerated() {
            let x = padX + CGFloat(i) * (d + gap)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
        }
        if showCount {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
            let size = (countText as NSString).size(withAttributes: attrs)
            (countText as NSString).draw(
                at: NSPoint(x: padX + ledsWidth + 5, y: (h - size.height) / 2),
                withAttributes: attrs
            )
        }
        image.unlockFocus()
        image.isTemplate = false           // keep LED colors
        return image
    }
}
