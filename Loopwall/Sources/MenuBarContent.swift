import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let name = state.currentItemName {
            Text(name)
            if let reason = state.pauseReason {
                Text(reason)
            }
        } else {
            Text("No wallpaper set")
        }

        Divider()

        Button(state.preferences.manuallyPaused ? "Resume" : "Pause") {
            state.togglePause()
        }
        .keyboardShortcut("p")

        if !state.library.items.isEmpty {
            Menu("Set Wallpaper") {
                ForEach(state.library.items) { item in
                    Button(item.name) { state.assignToAllDisplays(item) }
                }
                Divider()
                Button("None") { state.assignToAllDisplays(nil) }
            }
        }

        Divider()

        Button("Add Video or GIF…") { state.presentOpenPanel() }
        Button("Open Loopwall…") { AppDelegate.shared?.showMainWindow() }
            .keyboardShortcut(",")

        Divider()

        Button("Check for Updates…") {
            AppDelegate.shared?.updaterController.checkForUpdates(nil)
        }

        Divider()

        Button("Quit Loopwall") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
