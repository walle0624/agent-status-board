import AppKit
import SwiftUI

/// NSVisualEffectView bridge for the liquid-glass blur behind the widget.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// Vivid traffic-light colors used on the dark glass surface.
enum Glass {
    static let red = Color(.sRGB, red: 1.0, green: 0.353, blue: 0.322)     // #FF5A52
    static let amber = Color(.sRGB, red: 1.0, green: 0.698, blue: 0.243)   // #FFB23E
    static let green = Color(.sRGB, red: 0.212, green: 0.820, blue: 0.373) // #36D15F
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.52)
    static let textTertiary = Color.white.opacity(0.34)
    static let hairline = Color.white.opacity(0.10)
}

struct DesktopWidgetView: View {
    @ObservedObject var store: BoardStore
    var onClose: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var isPinned: Bool = true

    private var snapshot: AgentSnapshot { store.snapshot }
    private var attention: [AgentTask] {
        snapshot.visibleTasks.filter { [.waitingReview, .blocked, .failed, .stale].contains($0.status) }
    }
    private var running: [AgentTask] {
        snapshot.visibleTasks.filter { $0.status == .running || $0.status == .thinking }
    }
    private var doneCount: Int { snapshot.count(for: .done) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !attention.isEmpty {
                attentionBlock           // red: needs you
            } else if !running.isEmpty {
                runningBlock             // amber: work in progress
            } else {
                calmState                // green: truly idle / done
            }
            summaryRow
            if !store.activity.isEmpty {
                activityBlock
            }
        }
        .padding(18)
        .frame(width: 312, alignment: .leading)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow)
                // Glassy depth: a richer dark base for the "liquid glass" look.
                LinearGradient(
                    colors: [Color(.sRGB, red: 0.10, green: 0.11, blue: 0.13).opacity(0.50),
                             Color(.sRGB, red: 0.06, green: 0.07, blue: 0.09).opacity(0.66)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
        )
        // Tight contact shadow only. Must stay well inside the outer padding
        // below, or the window edge clips it into a hard rectangular line.
        .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
        .padding(22)
    }

    // MARK: header

    private var header: some View {
        let st = snapshot.overallStatus
        return HStack(spacing: 8) {
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(isPinned ? Glass.textSecondary : Glass.textTertiary)
            }
            .buttonStyle(.plain)
            .help(isPinned ? "取消置顶" : "置顶")

            Text("Agent 状态")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Glass.textPrimary)

            statePill(st)

            Spacer()

            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Glass.textTertiary)
            }
            .buttonStyle(.plain)
            .help("刷新")

            Button(action: onClose) {
                Circle().fill(Color(.sRGB, red: 1, green: 0.37, blue: 0.34))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help("隐藏（可从菜单栏重新打开）")
        }
    }

    private func statePill(_ st: BoardOverallStatus) -> some View {
        let (color, text) = pill(st)
        return HStack(spacing: 5) {
            LEDDot(color: color, flashing: st == .needsAttention)
            Text(text).font(.system(size: 11)).foregroundStyle(color.opacity(0.95))
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.16)))
    }

    private func pill(_ st: BoardOverallStatus) -> (Color, String) {
        switch st {
        case .needsAttention: (Glass.red, "需要处理")
        case .running: (Glass.amber, "正在执行")
        case .thinking: (Glass.amber, "思考中")
        case .done: (Glass.green, "已完成")
        case .idle: (Glass.green, "空闲")
        }
    }

    // MARK: attention (hero)

    private var attentionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(attention.count)")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Glass.red)
                    .monospacedDigit()
                Text("项需要你处理")
                    .font(.system(size: 12))
                    .foregroundStyle(Glass.textSecondary)
            }
            ForEach(attention.prefix(4)) { task in
                HStack(alignment: .top, spacing: 9) {
                    LEDDot(color: Glass.red, flashing: false).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(task.title.isEmpty ? "\(task.source.displayName) 会话" : task.title)
                                .font(.system(size: 13)).foregroundStyle(Glass.textPrimary)
                                .lineLimit(1)
                            Text("· \(task.source.displayName)")
                                .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                        }
                        Text(reason(for: task))
                            .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func reason(for task: AgentTask) -> String {
        // Prefer the LLM-written note about what it's waiting for.
        if let n = task.note, !n.isEmpty { return n }
        var base: String
        switch task.status {
        case .waitingReview: base = "等待你的输入或授权"
        case .blocked: base = "被阻塞，等待信息"
        case .failed: base = "执行失败，需检查"
        case .stale: base = "疑似停滞"
        default: base = task.status.displayName
        }
        if let t = task.lastTool, !t.isEmpty { base += " · ⚙ \(t)" }
        if let w = task.workspace, !w.isEmpty {
            base += " · " + (w as NSString).abbreviatingWithTildeInPath
        }
        return base
    }

    // MARK: running (hero, no attention)

    private var runningBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(running.count)")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Glass.amber)
                    .monospacedDigit()
                Text("个任务执行中")
                    .font(.system(size: 12))
                    .foregroundStyle(Glass.textSecondary)
            }
            ForEach(running.prefix(4)) { task in
                HStack(alignment: .top, spacing: 9) {
                    LEDDot(color: Glass.amber, flashing: false).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(task.title.isEmpty ? "\(task.source.displayName) 会话" : task.title)
                                .font(.system(size: 13)).foregroundStyle(Glass.textPrimary)
                                .lineLimit(1)
                            Text("· \(task.source.displayName)")
                                .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                        }
                        Text(runningDetail(task))
                            .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func runningDetail(_ task: AgentTask) -> String {
        var parts = [task.status == .thinking ? "思考中" : "正在执行"]
        if let m = task.model, !m.isEmpty { parts.append(m) }
        if let w = task.workspace, !w.isEmpty {
            parts.append((w as NSString).abbreviatingWithTildeInPath)
        }
        if let t = task.lastTool, !t.isEmpty { parts.append("⚙ \(t)") }
        return parts.joined(separator: " · ")
    }

    // MARK: calm state

    private var calmState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(Glass.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("没有待处理事项")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Glass.textPrimary)
                Text("所有会话已收口")
                    .font(.system(size: 12)).foregroundStyle(Glass.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: summary

    private var summaryRow: some View {
        HStack(spacing: 16) {
            // Running is the hero unless attention is present; only echo it here
            // when attention has taken the hero slot, so it stays visible.
            if !attention.isEmpty && !running.isEmpty {
                summaryItem(Glass.amber, "正在执行", "\(running.count)")
            }
            if doneCount > 0 {
                summaryItem(Glass.green, "今日完成", "\(doneCount)")
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    private func summaryItem(_ color: Color, _ label: String, _ count: String) -> some View {
        HStack(spacing: 7) {
            LEDDot(color: color, flashing: false)
            Text(label).font(.system(size: 12)).foregroundStyle(Glass.textSecondary)
            Text(count).font(.system(size: 12, weight: .medium)).foregroundStyle(Glass.textPrimary)
                .monospacedDigit()
        }
    }

    // MARK: activity

    private var activityBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().overlay(Glass.hairline)
            Text("最近活动").font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
            ForEach(store.activity.prefix(4)) { entry in
                HStack(spacing: 8) {
                    Text(Self.hhmm.string(from: entry.at))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Glass.textTertiary)
                        .frame(width: 32, alignment: .leading)
                    LEDDot(color: dotColor(entry.status), flashing: false, size: 7)
                    Text("\(entry.source.displayName) \(entry.status.displayName) — \(entry.title)")
                        .font(.system(size: 12)).foregroundStyle(Glass.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func dotColor(_ s: AgentTaskStatus) -> Color {
        switch s {
        case .running, .thinking: Glass.amber
        case .done: Glass.green
        default: Glass.red
        }
    }

    private static let hhmm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

private struct LEDDot: View {
    let color: Color
    var flashing: Bool
    var size: CGFloat = 10

    var body: some View {
        if flashing {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let on = t.truncatingRemainder(dividingBy: 0.6) < 0.3
                Circle().fill(color).frame(width: size, height: size).opacity(on ? 1 : 0.35)
            }
        } else {
            Circle().fill(color).frame(width: size, height: size)
        }
    }
}
