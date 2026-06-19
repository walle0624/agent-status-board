# Agent Status Board Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a read-only macOS menu bar and dashboard app that shows current Codex and Claude Code task activity.

**Architecture:** A SwiftPM macOS GUI app owns a shared `BoardStore` that periodically asks small collectors for local task signals. SwiftUI renders a `MenuBarExtra` for glanceable status and a dashboard window for details.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, SwiftPM, macOS 14+.

---

### Task 1: Status Model And Tests

**Files:**
- Create: `Package.swift`
- Create: `Sources/AgentStatusBoard/Models/AgentModels.swift`
- Create: `Tests/AgentStatusBoardTests/AgentStatusBoardTests.swift`

- [x] Define sources, task statuses, overall board status, task records, and snapshot aggregation.
- [x] Test that running tasks take priority over review tasks.
- [x] Test that waiting review becomes the yellow attention state when nothing is running.
- [x] Test that completed or empty snapshots are green.

### Task 2: Local Collectors

**Files:**
- Create: `Sources/AgentStatusBoard/Services/Shell.swift`
- Create: `Sources/AgentStatusBoard/Services/TaskCollectors.swift`
- Create: `Sources/AgentStatusBoard/Stores/BoardStore.swift`

- [x] Parse process output for Claude Code workers and Codex helper processes.
- [x] Read recent Codex sessions from `~/.codex/session_index.jsonl`.
- [x] Read Claude Code task JSON files from `~/.claude/tasks`.
- [x] Merge collector results in a periodically refreshing store.

### Task 3: macOS UI

**Files:**
- Create: `Sources/AgentStatusBoard/App/AgentStatusBoardApp.swift`
- Create: `Sources/AgentStatusBoard/Views/ContentView.swift`
- Create: `Sources/AgentStatusBoard/Views/SidebarView.swift`
- Create: `Sources/AgentStatusBoard/Views/DashboardDetailView.swift`
- Create: `Sources/AgentStatusBoard/Views/MenuBarPanelView.swift`
- Create: `Sources/AgentStatusBoard/Views/StatusViews.swift`

- [x] Add a regular macOS app window with a sidebar-detail dashboard.
- [x] Add a menu bar extra that shows running and attention counts.
- [x] Use green, animated blue, and yellow indicators for the three top-level states.
- [x] Keep actions read-only except for opening folders and refreshing local state.

### Task 4: Run Loop

**Files:**
- Create: `script/build_and_run.sh`
- Create: `.codex/environments/environment.toml`
- Create: `README.md`

- [x] Build with SwiftPM.
- [x] Stage a local `.app` bundle under `dist/AgentStatusBoard.app`.
- [x] Launch the app bundle with `/usr/bin/open -n`.
- [x] Wire the Codex Run action to `./script/build_and_run.sh`.

### Verification

- [x] Run `swift test`.
- [x] Run `./script/build_and_run.sh --verify`.
- [x] Confirm the `AgentStatusBoard` process is alive.
