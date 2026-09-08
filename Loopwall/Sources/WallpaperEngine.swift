import AppKit
import AVFoundation
import Combine

struct DisplayInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let isMain: Bool

    var resolutionLabel: String { "\(width)×\(height)" }
}

/// Stable per-display identity. The CoreGraphics display UUID survives unplugging
/// and rebooting, so an assignment made to "the LG on the left" stays put.
enum DisplayIdentity {
    static func key(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayID = CGDirectDisplayID(number.uint32Value)
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
               let string = CFUUIDCreateString(nil, uuid) as String? {
                return string
            }
        }
        return "name:\(screen.localizedName)"
    }
}

/// Creates a desktop-level window for each display that has a wallpaper assigned,
/// and keeps their players in sync with the current assignments and power policy.
///
/// A display with no assignment gets *no window at all* rather than a hidden one:
/// a desktop-level window composites as soon as it exists, so an empty one would
/// paint black over the system wallpaper.
@MainActor
final class WallpaperEngine: ObservableObject {

    private final class Surface {
        let window: WallpaperWindow
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var itemID: UUID?
        var isVisible = true

        init(window: WallpaperWindow) { self.window = window }
    }

    @Published private(set) var displays: [DisplayInfo] = []

    /// Set by `AppState` so the engine can turn an assignment into a file.
    var itemProvider: ((String) -> WallpaperItem?)?

    private var surfaces: [String: Surface] = [:]
    private var occlusionObservers: [String: NSObjectProtocol] = [:]
    private var preferences = Preferences()
    private let policy: PowerPolicy
    private var screenObserver: NSObjectProtocol?

    init(policy: PowerPolicy) {
        self.policy = policy
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        policy.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.updatePlayback() }
        }
        rebuild()
    }

    // MARK: - Public API

    func apply(preferences: Preferences) {
        self.preferences = preferences
        syncContent()
        updatePlayback()
    }

    /// Re-reads the attached screens, then reconciles windows against assignments.
    func rebuild() {
        displays = NSScreen.screens.map { screen in
            DisplayInfo(id: DisplayIdentity.key(for: screen),
                        name: screen.localizedName,
                        width: Int(screen.frame.width * screen.backingScaleFactor),
                        height: Int(screen.frame.height * screen.backingScaleFactor),
                        isMain: screen == NSScreen.main)
        }
        syncContent()
        updatePlayback()
    }

    func teardown() {
        for key in Array(surfaces.keys) { destroySurface(forKey: key) }
    }

    // MARK: - Reconciliation

    private func syncContent() {
        var live = Set<String>()
        for screen in NSScreen.screens {
            let key = DisplayIdentity.key(for: screen)
            guard let item = itemProvider?(key) else { continue }
            live.insert(key)

            let surface = surfaces[key] ?? makeSurface(forKey: key, screen: screen)
            surface.window.setFrame(screen.frame, display: true)
            surface.window.wallpaperView.playerLayer.videoGravity = preferences.fitMode.videoGravity

            if surface.itemID != item.id {
                load(item, into: surface)
            }
            if !surface.window.isVisible {
                surface.window.orderFrontRegardless()
            }
        }

        // Displays that lost their assignment, or vanished entirely.
        // Snapshot the keys: destroySurface mutates `surfaces`.
        for key in Array(surfaces.keys) where !live.contains(key) {
            destroySurface(forKey: key)
        }
    }

    private func makeSurface(forKey key: String, screen: NSScreen) -> Surface {
        let window = WallpaperWindow(screen: screen)
        let surface = Surface(window: window)
        surfaces[key] = surface

        // WindowServer already computes whether the desktop is covered; use that
        // instead of polling or guessing about full-screen apps.
        occlusionObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main) { [weak self, weak surface, weak window] _ in
                MainActor.assumeIsolated {
                    guard let surface, let window else { return }
                    surface.isVisible = window.occlusionState.contains(.visible)
                    self?.updatePlayback()
                }
            }
        return surface
    }

    private func destroySurface(forKey key: String) {
        guard let surface = surfaces.removeValue(forKey: key) else { return }
        unload(surface)
        surface.window.orderOut(nil)
        surface.window.close()
        if let observer = occlusionObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Content

    private func load(_ item: WallpaperItem, into surface: Surface) {
        unload(surface)

        let asset = AVURLAsset(url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        // Local files never need buffering heuristics, and this avoids a stall
        // when several displays start at once.
        player.automaticallyWaitsToMinimizeStalling = false

        surface.player = player
        surface.looper = AVPlayerLooper(player: player, templateItem: playerItem)
        surface.itemID = item.id
        surface.window.wallpaperView.playerLayer.player = player
    }

    private func unload(_ surface: Surface) {
        surface.looper?.disableLooping()
        surface.player?.pause()
        surface.player?.removeAllItems()
        surface.window.wallpaperView.playerLayer.player = nil
        surface.player = nil
        surface.looper = nil
        surface.itemID = nil
    }

    // MARK: - Playback

    func updatePlayback() {
        for surface in surfaces.values {
            guard let player = surface.player else { continue }
            let shouldPlay = policy.shouldPlay(isVisible: surface.isVisible, preferences: preferences)
            if shouldPlay {
                if player.rate == 0 { player.play() }
            } else if player.rate != 0 {
                player.pause()
            }
        }
    }
}
