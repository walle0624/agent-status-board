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
    var onOpen: (AgentTask) -> Void = { _ in }
    var isPinned: Bool = true

    private var snapshot: AgentSnapshot { store.snapshot }
    private var attention: [AgentTask] {
        snapshot.visibleTasks.filter { [.waitingReview, .blocked, .failed, .stale].contains($0.status) }
    }
    private var running: [AgentTask] {
        snapshot.visibleTasks.filter { $0.status == .running || $0.status == .thinking }
    }
    /// Completed sessions in the snapshot window, newest first — listed under
    /// "今日完成" at the bottom. Count equals the list length, so the number and
    /// the detail always agree.
    private var doneTasks: [AgentTask] {
        snapshot.visibleTasks
            .filter { $0.status == .done }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
    private var doneCount: Int { doneTasks.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !attention.isEmpty {
                attentionBlock                         // red hero: needs you
                if !running.isEmpty { runningListBlock }   // keep running as a list
            } else if !running.isEmpty {
                runningBlock                           // amber hero: work in progress
            }
            if doneCount > 0 {
                todayDoneBlock                         // 今日完成 N + 明细列表
            }
            if attention.isEmpty && running.isEmpty && doneCount == 0 {
                calmState                              // truly idle
            }
            if store.codexUsage != nil {
                usageBlock                             // Codex 5 小时 / 周 用量
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
                sessionRow(task, color: Glass.red, detail: reason(for: task), detailLines: 2)
            }
        }
    }

    /// One session row: dot, title · source, a detail line, and a chevron. The
    /// whole row opens the owning app/session on click.
    @ViewBuilder
    private func sessionRow(_ task: AgentTask, color: Color, detail: String, detailLines: Int) -> some View {
        ClickableRow(onTap: { onOpen(task) }) {
            HStack(alignment: .top, spacing: 9) {
                LEDDot(color: color, flashing: false).padding(.top, 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(task.title.isEmpty ? "\(task.source.displayName) 会话" : task.title)
                            .font(.system(size: 13)).foregroundStyle(Glass.textPrimary)
                            .lineLimit(1)
                        Text("· \(task.source.displayName)")
                            .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                    }
                    Text(detail)
                        .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                        .lineLimit(detailLines)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Glass.textTertiary)
                    .padding(.top, 3)
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

    // MARK: running

    /// Big hero, shown when nothing needs attention.
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
                sessionRow(task, color: Glass.amber, detail: runningDetail(task), detailLines: 1)
            }
        }
    }

    /// Secondary list, shown under the attention hero so running sessions stay
    /// visible as rows (never collapsed into a count) when something needs you.
    private var runningListBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().overlay(Glass.hairline)
            Text("正在执行 · \(running.count)")
                .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
            ForEach(running.prefix(4)) { task in
                sessionRow(task, color: Glass.amber, detail: runningDetail(task), detailLines: 1)
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

    // MARK: today's completed

    /// "今日完成 N" plus a detail list of completed sessions (newest first),
    /// each row clickable to reopen. The count equals the listed total.
    private var todayDoneBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().overlay(Glass.hairline)
            Text("今日完成 · \(doneCount)")
                .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
            ForEach(doneTasks.prefix(6)) { task in
                sessionRow(task, color: Glass.green, detail: doneDetail(task), detailLines: 1)
            }
            if doneCount > 6 {
                Text("…还有 \(doneCount - 6) 个")
                    .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                    .padding(.leading, 2)
            }
        }
    }

    /// Detail line for a completed row: when it finished, plus the LLM summary
    /// of what happened (falling back to the workspace path).
    private func doneDetail(_ task: AgentTask) -> String {
        var parts = [timeAgo(task.lastActivityAt)]
        if let n = task.note, !n.isEmpty {
            parts.append(n)
        } else if let w = task.workspace, !w.isEmpty {
            parts.append((w as NSString).abbreviatingWithTildeInPath)
        }
        return parts.joined(separator: " · ")
    }

    /// Short relative time like "刚刚" / "3 分钟前" / "2 小时前", per the snapshot.
    private func timeAgo(_ date: Date) -> String {
        let secs = Int(snapshot.refreshedAt.timeIntervalSince(date))
        if secs < 60 { return "刚刚" }
        let mins = secs / 60
        if mins < 60 { return "\(mins) 分钟前" }
        return "\(mins / 60) 小时前"
    }

    // MARK: usage (Codex 5h / weekly)

    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Glass.hairline)
            HStack(spacing: 6) {
                Text("用量").font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                if let u = store.codexUsage {
                    Text(u.plan.map { "Codex · \($0)" } ?? "Codex")
                        .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                    // Flag a clearly stale reading (no Codex activity for a while).
                    if u.snapshotAt.timeIntervalSince(snapshot.refreshedAt) < -1800 {
                        Text("· 截至 \(timeAgo(u.snapshotAt))")
                            .font(.system(size: 10)).foregroundStyle(Glass.textTertiary)
                    }
                }
            }
            if let w = store.codexUsage?.short { usageRow(usageLabel(w), w) }
            if let w = store.codexUsage?.long { usageRow(usageLabel(w), w) }
            Text("CC · 用量需登录态实时查询，暂未接入")
                .font(.system(size: 10)).foregroundStyle(Glass.textTertiary)
        }
    }

    private func usageLabel(_ w: UsageWindow) -> String {
        switch w.windowMinutes {
        case ..<360: return "5 小时"
        case 360..<2880: return "\(w.windowMinutes / 60) 小时"
        case 10080: return "本周"
        default: return "\(w.windowMinutes / 1440) 天"
        }
    }

    private func usageRow(_ label: String, _ w: UsageWindow) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Glass.textSecondary)
                .frame(width: 38, alignment: .leading)
            UsageBar(percent: w.usedPercent).frame(width: 84)
            Text("\(Int(w.usedPercent.rounded()))%")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Glass.textSecondary)
                .frame(width: 34, alignment: .trailing)
            Text(resetText(w.resetsAt))
                .font(.system(size: 10)).foregroundStyle(Glass.textTertiary).fixedSize()
            Spacer(minLength: 0)
        }
    }

    /// Compact countdown to the window reset, anchored to the snapshot.
    private func resetText(_ date: Date) -> String {
        let secs = Int(date.timeIntervalSince(snapshot.refreshedAt))
        if secs <= 0 { return "重置中" }
        if secs < 3600 { return "\(secs / 60)m 后重置" }
        if secs < 86400 { return "\(secs / 3600)h 后重置" }
        return "\(secs / 86400)d 后重置"
    }
}

/// A full-width row that opens the owning session on click, with a subtle hover
/// highlight and a pointing-hand cursor as the affordance. Dragging the widget
/// still works from the header and the empty areas between rows.
private struct ClickableRow<Content: View>: View {
    let onTap: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(hover ? 0.07 : 0))
                    .padding(.horizontal, -8)   // bleed the highlight outward only
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { h in
                hover = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// A thin usage meter: faint track + a fill whose color escalates with load.
private struct UsageBar: View {
    let percent: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(color)
                    .frame(width: max(3, geo.size.width * min(1, max(0, percent) / 100)))
            }
        }
        .frame(height: 4)
    }
    private var color: Color {
        if percent >= 80 { return Glass.red }
        if percent >= 50 { return Glass.amber }
        return Glass.green
    }
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
