import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var store: BoardStore
    var onSummon: (() -> Void)? = nil
    @Environment(\.openWindow) private var openWindow

    private var snapshot: AgentSnapshot { store.snapshot }

    private var activeTasks: [AgentTask] {
        snapshot.visibleTasks.filter { $0.status != .done }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            sourceRow(.codex, icon: "terminal")
            sourceRow(.claudeCode, icon: "sparkles")

            if !activeTasks.isEmpty {
                Divider()
                section("活跃会话") {
                    ForEach(activeTasks.prefix(5)) { task in
                        SessionRow(task: task)
                    }
                }
            }

            if !store.activity.isEmpty {
                Divider()
                section("活动") {
                    ForEach(store.activity.prefix(6)) { entry in
                        ActivityRow(entry: entry)
                    }
                }
            }

            Divider()
            footer
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            LEDRow(status: snapshot.overallStatus, diameter: 14)
            Text(LED.label(snapshot.overallStatus))
                .font(.headline)
            Spacer()
            if snapshot.liveCount() > 0 {
                Text("\(snapshot.liveCount()) 活跃")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新")
        }
    }

    private func sourceRow(_ source: AgentSource, icon: String) -> some View {
        let running = snapshot.count(for: source, status: .running)
            + snapshot.count(for: source, status: .thinking)
        let attention = [AgentTaskStatus.waitingReview, .blocked, .failed, .stale]
            .reduce(0) { $0 + snapshot.count(for: source, status: $1) }
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(source.displayName)
                .font(.subheadline.weight(.medium))
            Spacer()
            LEDRow(status: snapshot.overallStatus(for: source), diameter: 8)
            Text("\(running) 运行 · \(attention) 待确认")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private var footer: some View {
        HStack {
            Button {
                if let onSummon {
                    onSummon()
                } else {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
            } label: {
                Label("显示桌面组件", systemImage: "macwindow.on.rectangle")
            }
            .buttonStyle(.borderless)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
    }
}

private struct SessionRow: View {
    let task: AgentTask

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusDot(status: task.status)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(task.title).lineLimit(1)
                    Text("· \(task.source.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var detail: String {
        var parts: [String] = [task.status.displayName]
        if let m = task.model, !m.isEmpty { parts.append(m) }
        if let w = task.workspace, !w.isEmpty {
            parts.append((w as NSString).abbreviatingWithTildeInPath)
        }
        if let t = task.lastTool, !t.isEmpty { parts.append("⚙ \(t)") }
        return parts.joined(separator: " · ")
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.formatter.string(from: entry.at))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text("\(entry.source.displayName) \(entry.status.displayName) — \(entry.title)")
                .font(.caption)
                .lineLimit(1)
        }
    }

    private var dotColor: Color {
        switch entry.status {
        case .running, .thinking: LED.amber
        case .waitingReview, .blocked, .stale, .failed: LED.red
        case .done: LED.green
        }
    }
}
