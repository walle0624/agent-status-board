import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Custom NSStatusItem that renders one glossy liquid "battery" ball per
/// installed tool (Codex / Claude Code) and animates the water-wave every frame.
/// Each ball's fill = that tool's 5-hour usage; the number inside = its active
/// task count, colored by the highest-priority status. SwiftUI's MenuBarExtra
/// label is a static snapshot and can't animate, so we draw the icon ourselves.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: BoardStore
    private let onSummon: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var animationTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    // Bright traffic-light palette (亮色系).
    private let brightGreen = NSColor(srgbRed: 0.24, green: 0.85, blue: 0.42, alpha: 1)
    private let brightAmber = NSColor(srgbRed: 1.00, green: 0.74, blue: 0.20, alpha: 1)
    private let brightRed = NSColor(srgbRed: 1.00, green: 0.34, blue: 0.31, alpha: 1)
    private let neutral = NSColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1)

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

        // The dropdown now mirrors the desktop widget (需处理 / 正在执行 / 最近完成 /
        // 用量), reusing the same view chromeless.
        popover.behavior = .transient
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(
            rootView: DesktopWidgetView(store: store, onOpen: { SessionOpener.open($0) }, inPopover: true)
        )

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

    // MARK: - Per-tool ball specs

    private struct Ball {
        let fill: Double          // 0…1 — 5h USAGE (fills up as you use it)
        let body: NSColor         // load color (bright)
        let reading: Int          // 5h usage % — the big number inside (<0 → none)
        let count: Int            // active task count — number beside (0 → none)
        let countColor: NSColor   // task-status priority color
    }

    private func load(_ pct: Double) -> NSColor {
        if pct >= 80 { return brightRed }
        if pct >= 50 { return brightAmber }
        return brightGreen
    }

    private func statusColor(_ s: BoardOverallStatus) -> NSColor {
        switch s {
        case .needsAttention: return brightRed
        case .running, .thinking: return brightAmber
        case .done: return brightGreen
        case .idle: return neutral
        }
    }

    private func balls() -> [Ball] {
        var out: [Ball] = []
        func add(_ source: AgentSource, _ usage: ProviderUsage?, _ available: Bool) {
            guard available else { return }
            let used = max(0, min(100, usage?.short?.usedPercent ?? 0))   // 5h 使用量
            let (count, priority) = store.snapshot.toolSummary(for: source)
            out.append(Ball(fill: used / 100, body: load(used),
                            reading: Int(used.rounded()),
                            count: count, countColor: statusColor(priority)))
        }
        add(.codex, store.codexUsage, store.codexAvailable)
        add(.claudeCode, store.claudeUsage, store.claudeAvailable)
        // No tool installed: one neutral ball carrying the aggregate live count.
        if out.isEmpty {
            out.append(Ball(fill: 0, body: neutral, reading: -1,
                            count: store.snapshot.liveCount(),
                            countColor: statusColor(store.snapshot.overallStatus)))
        }
        return out
    }

    // MARK: - Drawing

    private func redraw() {
        statusItem.button?.image = renderImage(balls: balls(), time: CACurrentMediaTime())
    }

    private func renderImage(balls: [Ball], time t: Double) -> NSImage {
        let H = max(22, NSStatusBar.system.thickness)   // fill the real menu-bar height
        let ballD = H - 2.5                              // as large as fits
        let ballY = (H - ballD) / 2
        let gap: CGFloat = 6
        let taskFont = NSFont.systemFont(ofSize: ballD * 0.5, weight: .bold)
        func textW(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }

        // Each unit: a ball plus an optional task-count number beside it (球边上).
        let units = balls.map { b -> (ball: Ball, task: String, content: CGFloat) in
            let task = b.count > 0 ? "\(b.count)" : ""
            return (b, task, ballD + (task.isEmpty ? 0 : 2 + textW(task, taskFont)))
        }
        let w = units.reduce(0) { $0 + $1.content } + gap * CGFloat(max(0, units.count - 1)) + 4

        let image = NSImage(size: NSSize(width: max(ballD + 4, w), height: H))
        image.lockFocus()

        var x: CGFloat = 2
        for u in units {
            let rect = NSRect(x: x, y: ballY, width: ballD, height: ballD)
            drawBall(u.ball, in: rect, t: t)

            // Task count beside the ball, in the highest-priority status color,
            // haloed so it reads on a light or dark menu bar.
            if !u.task.isEmpty {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
                shadow.shadowBlurRadius = 1.5
                shadow.shadowOffset = .zero
                let attrs: [NSAttributedString.Key: Any] = [.font: taskFont, .foregroundColor: u.ball.countColor, .shadow: shadow]
                let s = u.task as NSString
                let sz = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: rect.maxX + 2, y: rect.midY - sz.height / 2), withAttributes: attrs)
            }
            x += u.content + gap
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// One glossy liquid ball that fills up with 5h usage: dark body, a sloshing
    /// colored fill to the usage level, a sheen, the usage-% number (centered,
    /// white), and a rim. (The task count is drawn beside it by the caller.)
    private func drawBall(_ ball: Ball, in rect: NSRect, t: Double) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()

        // Empty body: a dark tint of the load color, so the ball always reads as
        // a colored glass sphere even when nearly drained.
        (ball.body.blended(withFraction: 0.72, of: .black) ?? .black)
            .withAlphaComponent(0.95).setFill()
        rect.fill()

        // Liquid filled to the remaining level, with a sloshing sine surface.
        let level = rect.minY + rect.height * CGFloat(max(0, min(1, ball.fill)))
        let amp = max(0.5, rect.height * 0.06)
        let phase = t * 2.3
        let steps = 16
        func surface(_ shift: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: rect.minX, y: rect.minY))
            for s in 0...steps {
                let fx = CGFloat(s) / CGFloat(steps)
                let px = rect.minX + rect.width * fx
                let py = level + shift + amp * sin(phase + fx * 2 * .pi * 1.5)
                p.line(to: NSPoint(x: px, y: py))
            }
            p.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            p.close()
            return p
        }
        ball.body.withAlphaComponent(0.96).setFill()
        surface(0).fill()
        // Brighter sheen line just under the surface.
        (ball.body.blended(withFraction: 0.35, of: .white) ?? ball.body)
            .withAlphaComponent(0.6).setFill()
        surface(amp * 1.4).fill()

        // Glossy top-left highlight.
        NSColor.white.withAlphaComponent(0.26).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * 0.16, y: rect.maxY - rect.height * 0.42,
                                    width: rect.width * 0.48, height: rect.height * 0.30)).fill()
        ctx.restoreGraphicsState()

        // Center: 5h usage %, white, haloed for legibility on any fill.
        if ball.reading >= 0 {
            let s = "\(ball.reading)" as NSString
            let scale: CGFloat = s.length >= 3 ? 0.34 : (s.length == 2 ? 0.46 : 0.56)
            let f = NSFont.systemFont(ofSize: rect.height * scale, weight: .semibold)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 1.4
            shadow.shadowOffset = .zero
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white, .shadow: shadow]
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2), withAttributes: attrs)
        }

        // (The task-count number is drawn beside the ball — 球边上 — by the caller.)

        // Rim.
        NSColor.white.withAlphaComponent(0.20).setStroke()
        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)); rim.lineWidth = 0.8; rim.stroke()
    }
}
