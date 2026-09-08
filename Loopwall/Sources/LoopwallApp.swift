import SwiftUI
import AppKit

@main
struct LoopwallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(delegate.state)
        } label: {
            Image(systemName: "play.rectangle.on.rectangle.fill")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static private(set) var shared: AppDelegate?

    let state = AppState()
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // Menu bar only — no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        if !state.preferences.hasCompletedFirstRun || state.library.items.isEmpty {
            state.preferences.hasCompletedFirstRun = true
            showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.engine.teardown()
    }

    /// Launching an already-running menu bar app from Finder looks like nothing
    /// happened unless we surface the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// "Open With → Loopwall", dragging a file onto the app icon, or
    /// `open -a Loopwall clip.mp4`.
    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow()
        state.enqueue(urls: urls)
    }

    func showMainWindow() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController(state: state)
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}

/// The library / display window. Built in AppKit rather than as a SwiftUI `Window`
/// scene so an accessory app can create it strictly on demand.
final class MainWindowController: NSWindowController {
    init(state: AppState) {
        let hosting = NSHostingController(rootView: MainView().environmentObject(state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Loopwall"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 580))
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LoopwallMainWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
