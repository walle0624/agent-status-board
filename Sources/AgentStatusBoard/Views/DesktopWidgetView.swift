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

    /// Traffic-light color for a usage load: green (充足) / amber (偏高) / red (耗尽).
    static func load(_ pct: Double) -> Color {
        if pct >= 80 { return red }
        if pct >= 50 { return amber }
        return green
    }

    /// Traffic-light color for a REMAINING level (like a battery): green when
    /// plenty is left (充足) → amber → red when almost out (耗尽).
    static func loadRemaining(_ remaining: Double) -> Color {
        if remaining <= 20 { return red }
        if remaining <= 50 { return amber }
        return green
    }
}

struct DesktopWidgetView: View {
    @ObservedObject var store: BoardStore
    var onClose: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onOpen: (AgentTask) -> Void = { _ in }
    var isPinned: Bool = true
    /// Hosted inside the menu-bar popover rather than the floating window:
    /// drop the window chrome (pin/close, drop shadow, outer margin).
    var inPopover: Bool = false
    @State private var appeared = false
    @State private var updating = false

    private var snapshot: AgentSnapshot { store.snapshot }
    private var attention: [AgentTask] {
        snapshot.visibleTasks.filter { [.waitingReview, .blocked, .failed, .stale].contains($0.status) }
    }
    private var running: [AgentTask] {
        snapshot.visibleTasks.filter { $0.status == .running || $0.status == .thinking }
    }
    /// The most-recent completed sessions, newest first and de-duplicated by
    /// session (one row per session, its latest finish). Kept across restarts
    /// and overnight so you can see — and click back into — what you last
    /// worked on. Capped to a handful to stay glanceable.
    private var recentDone: [AgentTask] {
        var seen = Set<String>()
        return snapshot.visibleTasks
            .filter { $0.status == .done }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .filter { seen.insert($0.sessionId ?? $0.id).inserted }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let v = store.availableUpdate {
                updateBanner(v)
            }
            if !attention.isEmpty {
                attentionBlock                         // red hero: needs you
                if !running.isEmpty { runningListBlock }   // keep running as a list
            } else if !running.isEmpty {
                runningBlock                           // amber hero: work in progress
            }
            if !recentDone.isEmpty {
                recentDoneBlock                        // 最近完成（跨天保留，可点击回去继续）
            }
            if attention.isEmpty && running.isEmpty && recentDone.isEmpty {
                calmState                              // truly idle
            }
            if store.claudeAvailable || store.codexUsage != nil {
                usageBlock                             // 仅显示本机装了的工具的用量
            }
        }
        .padding(18)
        .frame(width: 312, alignment: .leading)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow)
                // Deep navy base for the glassy look.
                LinearGradient(
                    colors: [Color(.sRGB, red: 0.09, green: 0.11, blue: 0.17).opacity(0.74),
                             Color(.sRGB, red: 0.05, green: 0.06, blue: 0.11).opacity(0.84)],
                    startPoint: .top, endPoint: .bottom
                )
                // Ambient corner glows give the card depth.
                RadialGradient(
                    colors: [Color(.sRGB, red: 0.30, green: 0.52, blue: 0.95).opacity(0.12), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 300
                )
                RadialGradient(
                    colors: [Color(.sRGB, red: 0.52, green: 0.32, blue: 0.85).opacity(0.12), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 320
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
        // In the popover the system provides the chrome, so drop both.
        .shadow(color: .black.opacity(inPopover ? 0 : 0.28), radius: 8, y: 4)
        .padding(inPopover ? 10 : 22)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.97)
        .onAppear { withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { appeared = true } }
    }

    // MARK: header

    private var header: some View {
        let st = snapshot.overallStatus
        return HStack(spacing: 8) {
            if !inPopover {
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(isPinned ? Glass.textSecondary : Glass.textTertiary)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "取消置顶" : "置顶")
            }

            Text("Agent 状态")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Glass.textPrimary)

            statePill(st)

            Spacer()

            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Glass.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("刷新")

            if !inPopover {
                Button(action: onClose) {
                    LEDDot(color: Glass.red, flashing: false, size: 12)
                }
                .buttonStyle(.plain)
                .help("隐藏（可从菜单栏重新打开）")
            }
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

    // MARK: update banner

    @ViewBuilder
    private func updateBanner(_ version: String) -> some View {
        let accent = Color(.sRGB, red: 0.40, green: 0.66, blue: 1.0)
        Button {
            if !updating { updating = true; store.applyUpdate() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: updating ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                    .font(.system(size: 11))
                Text(updating ? "更新中…（完成后自动重启）" : "有新版本 v\(version) · 点击更新")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                if !updating {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(0.25), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .disabled(updating)
        .onHover { h in
            if h && !updating { NSCursor.pointingHand.push() } else if !h { NSCursor.pop() }
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

    // MARK: recently completed (kept across days)

    /// "最近完成" — the last few finished sessions, deduped and kept across days
    /// so you can pick up yesterday's work. Each row is clickable to reopen its
    /// session right where you left off.
    private var recentDoneBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().overlay(Glass.hairline)
            Text("最近完成 · \(recentDone.count)")
                .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
            ForEach(recentDone) { task in
                sessionRow(task, color: Glass.green, detail: doneDetail(task), detailLines: 1)
            }
        }
    }

    /// Detail line for a completed row: when it finished (calendar-aware, so it
    /// reads right across days), plus the LLM summary of what happened (falling
    /// back to the workspace path).
    private func doneDetail(_ task: AgentTask) -> String {
        var parts = [doneWhen(task.lastActivityAt)]
        if let n = task.note, !n.isEmpty {
            parts.append(n)
        } else if let w = task.workspace, !w.isEmpty {
            parts.append((w as NSString).abbreviatingWithTildeInPath)
        }
        return parts.joined(separator: " · ")
    }

    /// Calendar-aware finish time for a completed row: "今天 14:30" /
    /// "昨天 19:25" / "6/21 10:00".
    private func doneWhen(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm"; return "今天 " + f.string(from: date) }
        if cal.isDateInYesterday(date) { f.dateFormat = "HH:mm"; return "昨天 " + f.string(from: date) }
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
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
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Glass.hairline)
            HStack(spacing: 6) {
                Text("余量").font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                Spacer()
                legendItem(Glass.green, "充足")
                legendItem(Glass.amber, "偏低")
                legendItem(Glass.red, "耗尽")
            }
            if store.claudeAvailable {
                if let u = store.claudeUsage {
                    usageProvider("CC", u)
                } else {
                    Text("CC · 用量获取中…（首次约几秒；长期为空则检查 cc-token.json）")
                        .font(.system(size: 10)).foregroundStyle(Glass.textTertiary)
                }
            }
            if let u = store.codexUsage {
                usageProvider("Codex", u)
            }
        }
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            LEDDot(color: color, flashing: false, size: 6)
            Text(label).font(.system(size: 10)).foregroundStyle(Glass.textTertiary)
        }
    }

    private func usageProvider(_ name: String, _ u: ProviderUsage) -> some View {
        let peak = max(u.short?.usedPercent ?? 0, u.long?.usedPercent ?? 0)
        // The reading is a point-in-time snapshot: CC re-pings every few minutes,
        // but Codex only updates when it makes a request, so an idle Codex goes
        // stale. Mark it so the number isn't read as live.
        let stale = u.snapshotAt.timeIntervalSince(snapshot.refreshedAt) < -360
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                LEDDot(color: Glass.load(peak), flashing: false, size: 11)
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.textPrimary)
                if let p = u.plan, !p.isEmpty {
                    Text("· \(p)").font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                }
                if stale {
                    Text("· \(timeAgo(u.snapshotAt))快照")
                        .font(.system(size: 10)).foregroundStyle(Glass.amber.opacity(0.75))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if let w = u.short { usageRow(usageLabel(w), w) }
                if let w = u.long { usageRow(usageLabel(w), w) }
            }
            .opacity(stale ? 0.55 : 1)   // dim a stale snapshot
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
        let remaining = max(0, 100 - w.usedPercent)        // 像电量：还剩多少
        return HStack(spacing: 10) {
            Text(label).font(.system(size: 11)).foregroundStyle(Glass.textSecondary)
                .frame(width: 40, alignment: .leading)
            UsageBar(remaining: remaining).frame(maxWidth: .infinity)
            Text("剩\(Int(remaining.rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Glass.textPrimary)
                .frame(width: 46, alignment: .trailing)
            Text(resetText(w.resetsAt))
                .font(.system(size: 10)).foregroundStyle(Glass.textTertiary).fixedSize()
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(hover ? 0.08 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(hover ? 0.07 : 0), lineWidth: 0.5)
                    )
                    .padding(.horizontal, -8)   // bleed the highlight outward only
                    .animation(.easeOut(duration: 0.16), value: hover)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { h in
                hover = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// A glossy battery-style meter: rounded track + a gradient fill whose WIDTH is
/// the remaining quota (drains as you use it) and whose color goes green (full)
/// → amber → red (almost out). The fill animates when the value changes.
private struct UsageBar: View {
    /// 0…100 — how much quota REMAINS.
    let remaining: Double
    var body: some View {
        GeometryReader { geo in
            let w = max(7, geo.size.width * min(1, max(0, remaining) / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.85), color],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        Capsule().fill(LinearGradient(
                            colors: [Color.white.opacity(0.35), .clear],
                            startPoint: .top, endPoint: .center))
                    )
                    .frame(width: w)
                    .shadow(color: color.opacity(0.45), radius: 3, y: 0)
                    .animation(.easeOut(duration: 0.55), value: remaining)
            }
        }
        .frame(height: 7)
    }
    private var color: Color { Glass.loadRemaining(remaining) }
}

/// A glossy 3D sphere: a radial body (top-left highlight → color), a small
/// specular dot, and a soft colored outer glow. When `flashing`, the glow
/// breathes to draw the eye (used for the needs-attention state).
private struct LEDDot: View {
    let color: Color
    var flashing: Bool
    var size: CGFloat = 10

    var body: some View {
        if flashing {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * 2 * .pi / 1.4) + 1) / 2   // 0…1, ~1.4s period
                sphere(glow: 0.30 + 0.55 * phase)
            }
        } else {
            sphere(glow: 0.45)
        }
    }

    private func sphere(glow: Double) -> some View {
        let gradient = RadialGradient(
            colors: [Color.white.opacity(0.95), color, color.opacity(0.72)],
            center: UnitPoint(x: 0.34, y: 0.28),
            startRadius: 0, endRadius: size * 0.9
        )
        let highlightSize: CGFloat = size * 0.30
        let highlight = Circle()
            .fill(Color.white.opacity(0.85))
            .frame(width: highlightSize, height: highlightSize)
            .blur(radius: size * 0.05)
            .offset(x: -size * 0.18, y: -size * 0.20)
        let rim = Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
        return Circle()
            .fill(gradient)
            .overlay(highlight)
            .overlay(rim)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(glow), radius: size * 0.5)
    }
}
