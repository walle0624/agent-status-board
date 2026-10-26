import AppKit
import SwiftUI

@main
struct AgentStatusBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = BoardStore.shared

    var body: some Scene {
        WindowGroup("Agent Status Board", id: "dashboard") {
            DesktopWidgetView(store: store, onOpen: { SessionOpener.open($0) }, inPopover: true)
                .task {
                    store.start()
                }
        }
        .defaultSize(width: 380, height: 560)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Status") {
                Button("Refresh") {
                    Task { await store.refresh(forceUsage: true) }
                }
                .keyboardShortcut("r")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let summonNotification = Notification.Name("ai.linkingdigital.AgentStatusBoard.summon")
    private let instanceLock = AppInstanceLock()
    private var duplicateMonitor: Timer?
    private var duplicateFirstSeen: [pid_t: Date] = [:]
    private var statusItemController: StatusItemController?
    private var floatingWidget: FloatingWidgetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let current = NSRunningApplication.current
        let installedURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/AgentStatusBoard.app").resolvingSymlinksInPath()
        if Bundle.main.bundleURL.resolvingSymlinksInPath() != installedURL,
           FileManager.default.fileExists(atPath: installedURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: installedURL, configuration: configuration) { _, _ in
                Task { @MainActor in NSApp.terminate(nil) }
            }
            return
        }
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter({ $0.processIdentifier != current.processIdentifier && !$0.isTerminated })
            .filter({ $0.bundleURL?.resolvingSymlinksInPath() == installedURL })
            .filter({ ($0.launchDate ?? .distantPast) < (current.launchDate ?? .distantFuture)
                || ($0.launchDate == current.launchDate && $0.processIdentifier < current.processIdentifier) })
            .first {
            DistributedNotificationCenter.default().postNotificationName(Self.summonNotification, object: nil,
                                                                        userInfo: nil, deliverImmediately: true)
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        do {
            guard try instanceLock.acquire() else {
                DistributedNotificationCenter.default().postNotificationName(Self.summonNotification, object: nil,
                                                                            userInfo: nil, deliverImmediately: true)
                NSApp.terminate(nil)
                return
            }
        } catch {
            NSLog("AgentStatusBoard: unable to acquire the application instance lock")
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(summonWidget(_:)), name: Self.summonNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(anotherApplicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        // Accessory/legacy copies do not reliably generate a launch event.
        // Only the OS-lock owner runs this lightweight fallback.
        let monitor = Timer(timeInterval: 1, target: self,
                            selector: #selector(checkForLegacyCopies(_:)), userInfo: nil, repeats: true)
        duplicateMonitor = monitor
        RunLoop.main.add(monitor, forMode: .common)
        // Accessory app: lives on the desktop as a floating widget, with a
        // menu-bar item to re-summon it and glance at the live count.
        NSApp.setActivationPolicy(.accessory)
        let store = BoardStore.shared
        store.start()

        let widget = FloatingWidgetController(store: store)
        widget.show()
        floatingWidget = widget

        statusItemController = StatusItemController(store: store, onSummon: { [weak widget] in
            widget?.show()
        })

        // Suppress the auto-opened WindowGroup window; the live panel is the
        // menu-bar popover and the desktop floating widget.
        DispatchQueue.main.async {
            for w in NSApp.windows where w.title == "Agent Status Board" {
                w.close()
            }
        }
    }

    @objc private func summonWidget(_ notification: Notification) { floatingWidget?.show() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floatingWidget?.show()
        return false
    }

    @objc private func anotherApplicationLaunched(_ notification: Notification) {
        guard let peer = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        rejectDuplicate(peer)
    }

    @objc private func checkForLegacyCopies(_ timer: Timer) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let live = Set(peers.map(\.processIdentifier))
        duplicateFirstSeen = duplicateFirstSeen.filter { live.contains($0.key) }
        for peer in peers { rejectDuplicate(peer) }
    }

    private func rejectDuplicate(_ peer: NSRunningApplication) {
        guard
              peer.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              peer.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
        // Older copies have no single-instance guard. Keep the already-running
        // updated app as the one owner even if a legacy copy is opened later.
        if let firstSeen = duplicateFirstSeen[peer.processIdentifier] {
            if Date().timeIntervalSince(firstSeen) > 1, !peer.isTerminated { peer.forceTerminate() }
        } else {
            duplicateFirstSeen[peer.processIdentifier] = Date()
            peer.terminate()
            floatingWidget?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        duplicateMonitor?.invalidate()
        instanceLock.release()
    }
}
