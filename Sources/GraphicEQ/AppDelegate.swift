import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var appState: AppState!
    private var eqEngineController: EQEngineController!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appState = AppState()
        let eqEngineController = EQEngineController(appState: appState)
        self.appState = appState
        self.eqEngineController = eqEngineController

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Graphic EQ")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        self.statusItem = statusItem

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: StatusBarPopoverView(appState: appState))
        self.popover = popover

        installTerminationSignalHandlers()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        eqEngineController?.disableEQMode()
    }

    /// Best-effort safety net: SIGTERM doesn't always route through applicationWillTerminate,
    /// so restore the original output device directly on receiving it too.
    private func installTerminationSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.eqEngineController?.disableEQMode()
            NSApplication.shared.terminate(nil)
        }
        source.resume()
        signalSources.append(source)
    }
}
