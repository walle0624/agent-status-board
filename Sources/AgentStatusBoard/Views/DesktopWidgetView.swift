import AppKit
import SwiftUI
import os

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
    // Evened-out brightness, slightly lower saturation: the three states now
    // carry equal weight instead of red/amber shouting over green.
    static let red = Color(.sRGB, red: 0.957, green: 0.396, blue: 0.365)   // #F4655D
    static let amber = Color(.sRGB, red: 0.937, green: 0.675, blue: 0.286) // #EFAC49
    static let green = Color(.sRGB, red: 0.263, green: 0.784, blue: 0.471) // #43C878
    /// The status orb at rest — a dark, unlit glass ball for an idle board.
    static let inert = Color(.sRGB, red: 0.42, green: 0.46, blue: 0.54)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.52)
    static let textTertiary = Color.white.opacity(0.34)

    /// Blend a color toward another. The liquid meter needs "this color, 30%
    /// lighter at the top / 18% darker at the bottom"; `Color.mix(with:by:)`
    /// would do it but is macOS 15+, and this package targets 14.
    static func blend(_ c: Color, toward other: Color, _ t: Double) -> Color {
        let a = NSColor(c).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let f = CGFloat(min(1, max(0, t)))
        return Color(
            .sRGB,
            red: Double(a.redComponent + (b.redComponent - a.redComponent) * f),
            green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * f),
            blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * f),
            opacity: Double(a.alphaComponent)
        )
    }

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
    var onEndDragging: () -> Void = {}
    var isPinned: Bool = true
    /// Hosted inside the menu-bar popover rather than the floating window:
    /// drop the window chrome (pin/close, drop shadow, outer margin).
    var inPopover: Bool = false
    @State private var appeared = false

    private var snapshot: AgentSnapshot { store.snapshot }
    /// The statuses that put a row in the red "needs you" block — and the only
    /// ones that may be dismissed by hand. Named once so the block and its
    /// context menu can't drift apart.
    static let attentionStatuses: Set<AgentTaskStatus> = [.waitingReview, .blocked, .failed, .stale]
    private var attention: [AgentTask] {
        snapshot.visibleTasks.filter { Self.attentionStatuses.contains($0.status) }
    }
    private var running: [AgentTask] {
        snapshot.visibleTasks.filter { $0.status == .running || $0.status == .thinking }
    }
    /// The system is "idle" once nothing has happened for an hour. Running tasks
    /// keep their activity timestamp fresh (and the collector drops silent ones),
    /// so an hour of no activity also means nothing is running. Idle → the board
    /// shows the last-5 "recently done" resume list; active → it shows only this
    /// burst's completions instead (see `recentDone`).
    private var systemIdle: Bool {
        guard let last = snapshot.visibleTasks.map(\.lastActivityAt).max() else { return true }
        return Date().timeIntervalSince(last) >= 3600
    }
    /// What finished, adapted to the moment — never a fixed count parked forever:
    ///  • idle ≥1h → the last 5 completed sessions (the "pick up where I left
    ///    off" resume list);
    ///  • active   → only sessions that finished within the last hour (this
    ///    working burst), which age out on their own as time passes.
    /// Newest first, de-duplicated by session (one row per session).
    private var recentDone: [AgentTask] {
        var seen = Set<String>()
        let done = snapshot.visibleTasks
            .filter { $0.status == .done }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .filter { seen.insert($0.sessionId ?? $0.id).inserted }
        if systemIdle { return Array(done.prefix(5)) }
        let cutoff = Date().addingTimeInterval(-3600)
        return done.filter { $0.lastActivityAt >= cutoff }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let v = store.availableUpdate {
                updateBanner(v)
            } else if store.isUpdating || store.updateError != nil {
                updateBanner(store.updateProgress?.version ?? "")
            }
            if !attention.isEmpty {
                attentionBlock                         // red hero: needs you
                if !running.isEmpty { runningListBlock }   // keep running as a list
            } else if !running.isEmpty {
                runningBlock                           // amber hero: work in progress
            }
            if !recentDone.isEmpty {
                recentDoneBlock   // active → this burst's completions；idle ≥1h → last-5 resume list
            }
            if attention.isEmpty && running.isEmpty && recentDone.isEmpty {
                calmState                              // truly idle
            }
            if store.claudeAvailable || store.codexUsage != nil {
                usageBlock                             // 仅显示本机装了的工具的用量
            }
        }
        .padding(16)
        .frame(width: 312, alignment: .leading)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow)
                // Deep water: light filtering through the surface at the top,
                // going properly dark at the bottom. Three stops so the middle
                // doesn't flatten into grey.
                LinearGradient(
                    colors: [Color(.sRGB, red: 0.07, green: 0.13, blue: 0.19).opacity(0.82),
                             Color(.sRGB, red: 0.05, green: 0.07, blue: 0.12).opacity(0.86),
                             Color(.sRGB, red: 0.02, green: 0.03, blue: 0.07).opacity(0.93)],
                    startPoint: .top, endPoint: .bottom
                )
                // The light now has a source you can point at: a wash of the
                // aggregate state's color blooming from behind the header orb,
                // instead of two corner glows coming from nowhere. Static —
                // only the orb itself is allowed to move.
                GeometryReader { geo in
                    RadialGradient(
                        colors: [orbColor(snapshot.overallStatus)
                            .opacity(haloOpacity(snapshot.overallStatus)), .clear],
                        center: UnitPoint(x: 34 / max(geo.size.width, 1),
                                          y: 30 / max(geo.size.height, 1)),
                        startRadius: 0, endRadius: 130
                    )
                }
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
        .padding(inPopover ? 12 : 24)
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

            // The window's face: one glass orb carrying the aggregate state,
            // and one line saying what that means. Only the needs-you orb moves.
            // 16pt — a step above the 10pt row LEDs to hold the hierarchy,
            // without the orb becoming the thing you look at first.
            HStack(spacing: 8) {
                LEDDot(color: orbColor(st), flashing: st == .needsAttention, size: 16)
                digest.lineLimit(1)   // header stays exactly one line, whatever the counts
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .overlay {
                if !inPopover { WidgetDragRegion(onEndDragging: onEndDragging) }
            }

            Button { Task { await store.refresh(forceUsage: true) } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Glass.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("刷新")

            if !inPopover {
                CloseButton(action: onClose)
            }
        }
    }

    /// The orb's color for the aggregate state — the same traffic-light
    /// vocabulary the old pill used, except idle is an unlit ball rather than
    /// green, so "nothing happening" doesn't read as "all clear, look at me".
    private func orbColor(_ st: BoardOverallStatus) -> Color {
        switch st {
        case .needsAttention: Glass.red
        case .running, .thinking: Glass.amber
        case .done: Glass.green
        case .idle: Glass.inert
        }
    }

    /// Strength of the header halo per state — urgent states carry more light,
    /// an idle board barely glows at all.
    private func haloOpacity(_ st: BoardOverallStatus) -> Double {
        switch st {
        case .needsAttention: 0.12
        case .running, .thinking: 0.09
        case .done: 0.06
        case .idle: 0.04
        }
    }

    /// How a run of the digest reads. The wording and the coloring are decided
    /// together in `digestRuns` so they can't drift apart.
    enum DigestTone: Equatable { case attention, running, plain, calm }

    /// The header's one-line verdict, as (text, tone) runs. Pure — the whole
    /// wording rule is unit-testable without building a view.
    static func digestRuns(attention: Int, running: Int) -> [(text: String, tone: DigestTone)] {
        if attention > 0 {
            var runs: [(text: String, tone: DigestTone)] =
                [("\(attention)", .attention), (" 待处理", .plain)]
            if running > 0 {
                runs += [(" · ", .plain), ("\(running)", .running), (" 运行中", .plain)]
            }
            return runs
        }
        if running > 0 {
            return [("\(running)", .running), (" 个任务执行中", .plain)]
        }
        return [("一切就绪", .calm)]
    }

    private var digest: Text {
        Self.digestRuns(attention: attention.count, running: running.count)
            .reduce(Text("")) { $0 + styled($1) }
    }

    /// Every run is the same 13pt regular: a count is distinguished only by its
    /// state color (and monospaced digits so it doesn't jitter on refresh), so
    /// "2" never jumps off the line ahead of the word it belongs to.
    private func styled(_ run: (text: String, tone: DigestTone)) -> Text {
        let t = Text(run.text).font(.system(size: 13))
        switch run.tone {
        case .attention: return t.monospacedDigit().foregroundStyle(Glass.red)
        case .running: return t.monospacedDigit().foregroundStyle(Glass.amber)
        case .plain: return t.foregroundStyle(Glass.textPrimary)
        case .calm: return t.foregroundStyle(Glass.textSecondary)
        }
    }

    // MARK: update banner

    @ViewBuilder
    private func updateBanner(_ version: String) -> some View {
        let accent = Color(.sRGB, red: 0.40, green: 0.66, blue: 1.0)
        let updating = store.isUpdating
        Button {
            store.applyUpdate()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: updating ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                    .font(.system(size: 11))
                Text(store.updateError ?? (updating ? (store.updateProgress?.message ?? "正在启动更新…") : "有新版本 v\(version) · 点击更新"))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                if !updating {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 12).padding(.vertical, 8)
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
            ForEach(attention) { task in
                sessionRow(task, color: Glass.red, detail: reason(for: task), detailLines: 2)
            }
        }
    }

    /// One session row: dot, title · source, a detail line, how long ago it was
    /// last active, and a chevron. The whole row opens the owning app/session on
    /// click; the workspace path lives in the tooltip instead of on screen.
    /// A needs-you row additionally right-clicks to 「忽略，标为完成」 — the red
    /// verdict comes partly from an LLM and is sometimes wrong (a session that
    /// just ended with suggestions), and the board should never be stuck red.
    @ViewBuilder
    private func sessionRow(_ task: AgentTask, color: Color, detail: String, detailLines: Int) -> some View {
        let row = ClickableRow(onTap: { onOpen(task) }) {
            HStack(alignment: .top, spacing: 8) {
                // +1pt past the arithmetic center: optically the dot reads as
                // sitting on the title's midline rather than above it.
                LEDDot(color: color, flashing: false).padding(.top, 4)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(task.title.isEmpty ? "\(task.source.displayName) 会话" : task.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Glass.textPrimary)
                            .lineLimit(1)
                        Text("· \(task.source.displayName)")
                            .font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                    }
                    Text(detail)
                        .font(.system(size: 11)).foregroundStyle(Glass.textSecondary)
                        .lineLimit(detailLines)
                }
                Spacer(minLength: 4)
                ageLabel(task)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Glass.textTertiary)
                    .padding(.top, 4)
            }
        }
        .help(task.workspace ?? "")

        // Only needs-you rows carry the menu; attaching it unconditionally would
        // give running / finished rows an empty context menu.
        if Self.attentionStatuses.contains(task.status) {
            row.contextMenu { dismissMenuItem(task) }
        } else {
            row
        }
    }

    /// 「忽略，标为完成」— writes `done` into the session's own state file and
    /// refreshes, so the row leaves the red block immediately instead of waiting
    /// for a hook that may never fire again.
    private func dismissMenuItem(_ task: AgentTask) -> some View {
        Button {
            guard SessionDismiss.dismiss(recordPath: task.evidence) else { return }
            Task { await store.refresh() }
        } label: {
            Label("忽略，标为完成", systemImage: "checkmark.circle")
        }
    }

    /// The one section-header style, shared by 正在执行 / 最近完成 / 余量 so the
    /// three can't drift apart again.
    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.5)
            .foregroundStyle(Glass.textTertiary)
    }

    /// Right edge of a row: how long since it was last active. A session that is
    /// supposed to be working but has gone quiet for over 5 minutes is flagged
    /// stalled (⏸ + amber) — static, so it informs without pulling the eye.
    @ViewBuilder
    private func ageLabel(_ task: AgentTask) -> some View {
        let now = snapshot.refreshedAt
        let secs = now.timeIntervalSince(task.lastActivityAt)
        let stalled = (task.status == .running || task.status == .thinking) && secs > 300
        let text = Self.relativeAge(task.lastActivityAt, now: now)
        Text(stalled ? "⏸ " + text : text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(stalled ? Glass.amber : Glass.textSecondary)
            .fixedSize()
            .padding(.top, 4)
    }

    /// Compact age of a row: "刚刚" (<1m) / "7m" (<1h) / "1h24m" (<24h). Past a
    /// day it switches to calendar wording — "昨天" / "6-21" — because the idle
    /// resume list holds days-old sessions and "76h5m" stops being readable.
    /// `now` and `calendar` are injected so this stays a pure, testable function.
    static func relativeAge(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let secs = max(0, Int(now.timeIntervalSince(date)))
        if secs < 60 { return "刚刚" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        if secs < 86_400 { return "\(mins / 60)h\(mins % 60)m" }
        // Day gap off the calendar (not 86400s arithmetic) so DST and timezone
        // shifts can't slide a row onto the wrong day.
        let gap = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if gap == 1 { return "昨天" }
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// Detail line for a needs-you row: what it is waiting on, led by the LLM
    /// note when there is one, else the tool it stopped at. No path (tooltip)
    /// and no timestamp (right-edge label).
    private func reason(for task: AgentTask) -> String {
        if let n = task.note, !n.isEmpty { return "需要你：" + n }
        if let t = task.lastTool, !t.isEmpty { return "需要你：⚙ \(t)" }
        switch task.status {
        case .waitingReview: return "等待你的输入或授权"
        case .blocked: return "被阻塞，等待信息"
        case .failed: return "执行失败，需检查"
        case .stale: return "疑似停滞"
        default: return task.status.displayName
        }
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
            ForEach(running) { task in
                sessionRow(task, color: Glass.amber, detail: runningDetail(task), detailLines: 1)
            }
        }
    }

    /// Secondary list, shown under the attention hero so running sessions stay
    /// visible as rows (never collapsed into a count) when something needs you.
    private var runningListBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Hairline()
            sectionTitle("正在执行 · \(running.count)")
            ForEach(running) { task in
                sessionRow(task, color: Glass.amber, detail: runningDetail(task), detailLines: 1)
            }
        }
    }

    /// Detail line for a running row: what it is actually doing. The LLM summary
    /// wins when there is one; otherwise the state plus the tool it is on. No
    /// path (tooltip), no model, no timestamp (right-edge label).
    private func runningDetail(_ task: AgentTask) -> String {
        if let n = task.note, !n.isEmpty { return n }
        let state = task.status == .thinking ? "思考中" : "正在执行"
        if let t = task.lastTool, !t.isEmpty { return state + " · ⚙ \(t)" }
        return state
    }

    // MARK: calm state

    private var calmState: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(Glass.green)
            VStack(alignment: .leading, spacing: 0) {
                Text("没有待处理事项")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Glass.textPrimary)
                Text("所有会话已收口")
                    .font(.system(size: 12)).foregroundStyle(Glass.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: recently completed (kept across days)

    /// Finished sessions. `recentDone` adapts the content (active → this burst's
    /// completions; idle ≥1h → the last-5 resume list); the header stays
    /// "最近完成", and each row's timestamp shows how recent it is. Rows are
    /// clickable to reopen the session.
    private var recentDoneBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Hairline()
            sectionTitle("最近完成 · \(recentDone.count)")
            ForEach(recentDone) { task in
                sessionRow(task, color: Glass.green, detail: doneDetail(task), detailLines: 1)
            }
        }
    }

    /// Detail line for a completed row: the LLM summary of what happened,
    /// falling back to the workspace path. When it finished is carried by the
    /// right-edge age label instead of this line.
    private func doneDetail(_ task: AgentTask) -> String {
        if let n = task.note, !n.isEmpty { return n }
        if let w = task.workspace, !w.isEmpty {
            return (w as NSString).abbreviatingWithTildeInPath
        }
        return ""
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
        VStack(alignment: .leading, spacing: 12) {
            Hairline()
            HStack(spacing: 8) {
                sectionTitle("余量")
                Spacer()
                legendItem(Glass.green, "充足")
                legendItem(Glass.amber, "偏低")
                legendItem(Glass.red, "耗尽")
            }
            if store.claudeAvailable {
                if let u = store.claudeUsage {
                    usageProvider("CC", u)
                    if let error = store.claudeUsageError {
                        Text(error)
                            .font(.system(size: 10)).foregroundStyle(Glass.amber)
                    }
                } else {
                    Text(store.claudeUsageError ?? "CC · 用量获取中…（首次约几秒；长期为空则检查 cc-token.json）")
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LEDDot(color: Glass.load(peak), flashing: false, size: 9)
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.textPrimary)
                if let p = u.plan, !p.isEmpty {
                    Text("· \(p)").font(.system(size: 11)).foregroundStyle(Glass.textTertiary)
                }
                if stale {
                    Text("· \(timeAgo(u.snapshotAt))快照")
                        .font(.system(size: 10)).foregroundStyle(Glass.amber.opacity(0.75))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
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
        return HStack(spacing: 12) {
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

/// Only the header's status/title area owns native window dragging. Buttons and
/// session rows remain SwiftUI hit targets; popovers do not install this view.
private struct WidgetDragRegion: NSViewRepresentable {
    let onEndDragging: () -> Void

    func makeNSView(context: Context) -> WidgetDragHandleView {
        let view = WidgetDragHandleView()
        view.toolTip = "拖动以移动组件"
        view.onEndDragging = onEndDragging
        return view
    }

    func updateNSView(_ nsView: WidgetDragHandleView, context: Context) {
        nsView.onEndDragging = onEndDragging
    }
}

final class WidgetDragHandleView: NSView {
    var onEndDragging: () -> Void = {}
    var leftMouseIsPressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    private(set) var isDragging = false
    private var completionTimer: Timer?
    private var dragOrigin = NSPoint.zero
    private var mouseOrigin = NSPoint.zero
    private var observedPhysicalPress = false
    private static let log = Logger(subsystem: "ai.linkingdigital.AgentStatusBoard", category: "widget")

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, !isDragging else { return }
        isDragging = true
        dragOrigin = window.frame.origin
        mouseOrigin = window.convertPoint(toScreen: event.locationInWindow)
        observedPhysicalPress = leftMouseIsPressed()
        NSCursor.closedHand.push()
        Self.log.notice("Widget header drag started")
        // Track AppKit mouse events directly, which works for both real and
        // accessibility-generated input. WindowServer's performDrag returns
        // immediately and may consume mouseUp or ignore synthetic button state.
        let timer = Timer(timeInterval: 0.02, target: self,
                          selector: #selector(pollForDragCompletion(_:)), userInfo: nil, repeats: true)
        completionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func pollForDragCompletion(_ timer: Timer) { completeDragIfMouseReleased() }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: dragOrigin.x + mouse.x - mouseOrigin.x,
                                      y: dragOrigin.y + mouse.y - mouseOrigin.y))
    }

    override func mouseUp(with event: NSEvent) {
        finishDragging(savePosition: window != nil)
    }

    func completeDragIfMouseReleased() {
        guard isDragging else { return }
        if leftMouseIsPressed() { observedPhysicalPress = true; return }
        // Synthetic events need not change the hardware button bit. In that
        // case mouseUp, not an initial zero bit, owns completion.
        guard observedPhysicalPress else { return }
        finishDragging(savePosition: window != nil)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishDragging(savePosition: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func finishDragging(savePosition: Bool) {
        guard isDragging else { return }
        completionTimer?.invalidate()
        completionTimer = nil
        isDragging = false
        NSCursor.pop()
        Self.log.notice("Widget header drag finished")
        if savePosition { onEndDragging() }
    }
}

/// Neutral hide control, matching the refresh button's shape. Deliberately not
/// a red orb any more: the header already carries one status orb, and a second
/// red ball in the corner read as a second status rather than as a button.
private struct CloseButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hover ? 0.55 : 0.38))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.10 : 0.06)))
        }
        .buttonStyle(.plain)
        .help("隐藏（可从菜单栏重新打开）")
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.16), value: hover)
    }
}

/// Section rule: a hairline that fades out left-to-right instead of a flat
/// divider, so it reads as a lit edge catching the overhead light rather than a
/// drawn line.
private struct Hairline: View {
    var body: some View {
        LinearGradient(
            colors: [Color.white.opacity(0.12), Color.white.opacity(0.03)],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1)
    }
}

/// A full-width row that opens the owning session on click, with a subtle hover
/// highlight and a pointing-hand cursor as the affordance. The header's title
/// area supplies a separate native drag handle.
private struct ClickableRow<Content: View>: View {
    let onTap: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chip)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { h in
                hover = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    /// Rows carry no standing background at all — every row is invisible at
    /// rest and lights up only under the cursor. A needs-you row is told apart
    /// by its red orb, the hero count above it, and its red timestamp.
    private var chip: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return shape
            .fill(Color.white.opacity(hover ? 0.08 : 0))
            .overlay(shape.strokeBorder(Color.white.opacity(hover ? 0.07 : 0), lineWidth: 0.5))
            .padding(.horizontal, -8)   // bleed the highlight outward only
            .animation(.easeOut(duration: 0.16), value: hover)
    }
}

/// A glossy battery-style meter: rounded track + a gradient fill whose WIDTH is
/// the remaining quota (drains as you use it) and whose color goes green (full)
/// → amber → red (almost out). The fill animates when the value changes.
private struct UsageBar: View {
    /// 0…100 — how much quota REMAINS.
    let remaining: Double
    private let barHeight: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w = max(barHeight, geo.size.width * min(1, max(0, remaining) / 100))
            ZStack(alignment: .leading) {
                track
                fill
                    .frame(width: w)
                    .animation(.easeOut(duration: 0.55), value: remaining)
            }
        }
        .frame(height: barHeight)
    }

    /// A recessed groove: dark bed plus a dark line along the top inner edge —
    /// the shadow an overhead light casts inside a channel.
    private var track: some View {
        Capsule()
            .fill(Color.white.opacity(0.07))
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: [Color.black.opacity(0.35), .clear],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            )
    }

    /// The liquid body, borrowed from the menu-bar orb: lighter at the top,
    /// darker at the bottom, with a sheen across the upper 45% and a static
    /// bloom at the head of the fill. Held completely still — no animation
    /// beyond the width change.
    private var fill: some View {
        Capsule()
            .fill(LinearGradient(
                colors: [Glass.blend(color, toward: .white, 0.30),
                         Glass.blend(color, toward: .black, 0.18)],
                startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.white.opacity(0.30), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: barHeight * 0.45)
            }
            .clipShape(Capsule())
            // Outside the clip so the bloom can spill past the fill's head.
            // The one accent light in the window.
            .overlay(alignment: .trailing) {
                Capsule()
                    .fill(color.opacity(0.35))
                    .frame(width: 3)
                    .blur(radius: 3)
            }
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
            // The one moving thing in the window: the needs-you orb's glow
            // breathing on a slow 2.4s sine. Everything else is still.
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * 2 * .pi / 2.4) + 1) / 2   // 0…1, 2.4s period
                sphere(glow: 0.55 + 0.45 * phase)              // 0.55…1.0
            }
        } else {
            sphere(glow: 0.35)
        }
    }

    /// A miniature of the menu-bar orb: liquid body (light on top, sunk at the
    /// bottom), an elliptical sheen up in the top third, and a thin glass shell.
    /// Reads as a bead of colored liquid rather than a flat dot.
    private func sphere(glow: Double) -> some View {
        let liquid = LinearGradient(
            colors: [Glass.blend(color, toward: .white, 0.35),
                     Glass.blend(color, toward: .black, 0.25)],
            startPoint: .top, endPoint: .bottom
        )
        let sheen = Ellipse()
            .fill(RadialGradient(
                colors: [Color.white.opacity(0.55), .clear],
                center: .center, startRadius: 0, endRadius: size * 0.30
            ))
            .frame(width: size * 0.55, height: size * 0.35)
            .offset(x: -size * 0.07, y: -size * 0.18)
        let shell = Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        return Circle()
            .fill(liquid)
            .overlay(sheen)
            .overlay(shell)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(glow), radius: size * 0.5)
    }
}
