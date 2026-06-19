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
