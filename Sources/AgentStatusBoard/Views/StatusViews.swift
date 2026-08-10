import AppKit
import SwiftUI

enum LED {
    static let red = Color(.sRGB, red: 0.886, green: 0.294, blue: 0.290)
    static let amber = Color(.sRGB, red: 0.937, green: 0.624, blue: 0.153)
    static let green = Color(.sRGB, red: 0.388, green: 0.600, blue: 0.133)
    static let dim = 0.18

    /// Per-LED opacity for (red, amber, green) given the aggregate state and time.
    /// Mirrors StatusItemController so the panel and the menu bar animate identically.
    static func alphas(_ status: BoardOverallStatus, _ t: Double) -> (Double, Double, Double) {
        func wave(_ period: Double, _ phase: Double = 0) -> Double {
            0.35 + 0.55 * (0.5 + 0.5 * sin(2 * .pi * t / period + phase))
        }
        switch status {
        case .idle:
            return (dim, dim, dim)
        case .needsAttention:
            let on = t.truncatingRemainder(dividingBy: 0.5) < 0.25
            return (on ? 1.0 : 0.25, dim, dim)
        case .running:
            return (dim, wave(0.9), wave(0.9, .pi))
        case .thinking:
            return (dim, 0.30 + 0.70 * (0.5 + 0.5 * sin(2 * .pi * t / 1.5)), dim)
        case .done:
            return (dim, dim, 1.0)
        }
    }

    static func label(_ status: BoardOverallStatus) -> String {
        switch status {
        case .idle: "空闲"
        case .running: "正在执行"
        case .thinking: "思考中"
        case .needsAttention: "需要确认"
        case .done: "执行完成"
        }
    }
}

/// The animated three-LED pill, reused at any size.
struct LEDRow: View {
    let status: BoardOverallStatus
    var diameter: CGFloat = 13

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let (ra, aa, ga) = LED.alphas(status, t)
            HStack(spacing: diameter * 0.42) {
                Circle().fill(LED.red).frame(width: diameter, height: diameter).opacity(ra)
                Circle().fill(LED.amber).frame(width: diameter, height: diameter).opacity(aa)
                Circle().fill(LED.green).frame(width: diameter, height: diameter).opacity(ga)
            }
        }
    }
}

struct OverallStatusView: View {
    let snapshot: AgentSnapshot
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 10) {
            LEDRow(status: snapshot.overallStatus, diameter: 14)
            Text(LED.label(snapshot.overallStatus))
                .font(.headline)
            if isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// Backwards-compatible alias used by the dashboard toolbar.
struct OverallLamp: View {
    let status: BoardOverallStatus
    var body: some View { LEDRow(status: status, diameter: 14) }
}

/// A single static dot for a per-task row.
struct StatusDot: View {
    let status: AgentTaskStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
    }

    private var color: Color {
        switch status {
        case .running, .thinking:
            LED.amber
        case .waitingReview, .blocked, .stale:
            LED.red
        case .failed:
            .red
        case .done:
            LED.green
        }
    }
}

/// A mini "thinking orb" — a 3-D point-lattice sphere (经纬网格) drawn in a
/// Canvas, whose motion mirrors the session state. Inspired by the Thinking
/// Orbs reference: near dots render bigger/brighter, far dots smaller/dimmer,
/// which is what sells the "little living thing" feel.
///
/// CPU: only animated modes spin a TimelineView (throttled to ~30 fps);
/// `.settled` draws one static frame — no timeline, zero idle cost.
struct ThinkingOrb: View {
    enum Mode {
        case working     // steady rotation        → running
        case breathing   // slow radius breath      → thinking
        case pulsing     // fast urgent pulse       → needs attention
        case settled     // static, dim, collapsed  → done
    }

    let mode: Mode
    /// The status hue (Glass.red / .amber / .green). Dots are this color
    /// blended toward white, so the orb keeps the "white particle" character
    /// while the state color stays unmistakable.
    var color: Color = .white
    var size: CGFloat = 16

    // MARK: tunables

    /// Lat/long lattice: (latitude°, points on that ring). 44 ring points + 2 poles.
    private static let rings: [(lat: Double, count: Int)] = [
        (-72, 4), (-44, 8), (-16, 10), (16, 10), (44, 8), (72, 4)
    ]
    private static let perspective = 2.9   // camera distance, in sphere radii
    private static let tilt = 0.45         // rad, fixed lean for a 3-D read
    private var spinPeriod: Double {       // seconds per revolution
        switch mode {
        case .working: 5.5
        case .breathing: 14
        case .pulsing: 2.6
        case .settled: 0
        }
    }

    /// Unit-sphere lattice, precomputed once: (x, y, z, hash 0…1 for scatter).
    private static let lattice: [(x: Double, y: Double, z: Double, h: Double)] = {
        var pts: [(Double, Double, Double, Double)] = []
        var i = 0
        func hash() -> Double {   // deterministic pseudo-random per point
            defer { i += 1 }
            let s = sin(Double(i) * 12.9898) * 43758.5453
            return s - s.rounded(.down)
        }
        for (latDeg, count) in Self.rings {
            let lat = latDeg * Double.pi / 180
            for j in 0..<count {
                let lon = 2 * Double.pi * Double(j) / Double(count)
                pts.append((cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon), hash()))
            }
        }
        pts.append((0, 1, 0, hash()))    // poles
        pts.append((0, -1, 0, hash()))
        return pts
    }()

    /// Near-white particle color derived from the status hue.
    private var tint: Color {
        guard let base = NSColor(color).usingColorSpace(.sRGB),
              let mixed = base.blended(withFraction: 0.68, of: .white) else { return color }
        return Color(mixed)
    }

    var body: some View {
        Group {
            if mode == .settled {
                canvas(t: 0)                                  // static: no timeline
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    canvas(t: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: rendering

    private func canvas(t: Double) -> some View {
        let dyn = dynamics(t: t)
        return Canvas { ctx, bounds in
            let c = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            let R = Double(min(bounds.width, bounds.height)) / 2 * 0.72

            // Soft halo bleeding outward; its strength follows the motion.
            let haloR = R * 1.35
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - haloR, y: c.y - haloR,
                                       width: haloR * 2, height: haloR * 2)),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(0.34 * dyn.alpha), .clear]),
                    center: c, startRadius: 0, endRadius: haloR
                )
            )

            // A settled orb gets a dense, quiet core — "安定的收拢感".
            if mode == .settled {
                let coreR = R * 0.5
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR,
                                           width: coreR * 2, height: coreR * 2)),
                    with: .radialGradient(
                        Gradient(colors: [tint.opacity(0.8), color.opacity(0.25), .clear]),
                        center: c, startRadius: 0, endRadius: coreR
                    )
                )
            }

            for p in project(dyn) {
                let pr = max(0.6, size * 0.055 * p.k)          // near bigger, far smaller
                let a = dyn.alpha * (0.22 + 0.78 * ((p.z + 1) / 2))  // near brighter
                let d = R * dyn.rScale
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x + p.x * d - pr, y: c.y + p.y * d - pr,
                                           width: pr * 2, height: pr * 2)),
                    with: .color(tint.opacity(a))
                )
            }
        }
    }

    /// Per-mode motion parameters at time t.
    private func dynamics(t: Double) -> (angle: Double, rScale: Double, alpha: Double, scatter: Double) {
        switch mode {
        case .working:
            return (2 * .pi * t / spinPeriod, 1.0, 0.92, 0)
        case .breathing:
            let b = sin(2 * .pi * t / 3.8)
            return (2 * .pi * t / spinPeriod, 0.94 + 0.11 * b, 0.60 + 0.30 * b, 0)
        case .pulsing:
            let w = 0.5 + 0.5 * sin(2 * .pi * t / 0.85)   // fast period — urgency
            let p = w * w * (3 - 2 * w)                   // smoothstep: sharp crest
            return (2 * .pi * t / spinPeriod, 0.90 + 0.26 * p, 0.55 + 0.45 * p, 0.10 * p)
        case .settled:
            return (0.8, 0.58, 0.55, 0)
        }
    }

    /// Spin around Y, lean around X, perspective-divide; sorted far → near so
    /// near dots paint on top. Returns unit-screen coords + depth + scale k.
    private func project(_ dyn: (angle: Double, rScale: Double, alpha: Double, scatter: Double))
        -> [(x: Double, y: Double, z: Double, k: Double)] {
        let ca = cos(dyn.angle), sa = sin(dyn.angle)
        let ct = cos(Self.tilt), st = sin(Self.tilt)
        var out: [(x: Double, y: Double, z: Double, k: Double)] = []
        out.reserveCapacity(Self.lattice.count)
        for p in Self.lattice {
            var x = p.x, y = p.y, z = p.z
            if dyn.scatter > 0 {   // per-point outward jitter along its own axis
                let s = 1 + dyn.scatter * (p.h * 2 - 1)
                x *= s; y *= s; z *= s
            }
            let x1 = x * ca + z * sa
            let z1 = z * ca - x * sa
            let y2 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            let k = Self.perspective / (Self.perspective - z2)
            out.append((x1 * k, -y2 * k, z2, k))
        }
        out.sort { $0.z < $1.z }
        return out
    }
}
