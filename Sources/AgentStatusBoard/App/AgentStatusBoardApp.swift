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
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var floatingWidget: FloatingWidgetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
