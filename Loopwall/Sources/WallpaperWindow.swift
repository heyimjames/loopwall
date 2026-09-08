import AppKit
import AVFoundation

/// A borderless, click-through window pinned to the desktop layer.
final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    let wallpaperView = WallpaperView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        isMovable = false
        isMovableByWindowBackground = false
        canHide = false
        animationBehavior = .none
        // Follow the user across every Space and never show up in Mission Control
        // or cmd-tab. `.stationary` keeps it from sliding during Space transitions.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        level = Self.desktopLevel
        contentView = wallpaperView
        setFrame(screen.frame, display: false)
    }

    /// Above the system's static desktop picture, below Finder's desktop icons.
    static var desktopLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    }
}

/// Hosts the `AVPlayerLayer`. Layer-backed and resized without implicit animation
/// so a display-arrangement change doesn't produce a visible slide.
final class WallpaperView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer = root
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
