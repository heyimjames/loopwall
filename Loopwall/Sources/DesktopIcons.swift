import Foundation
import AppKit

/// Shows or hides every icon on the desktop.
///
/// This is Finder's own `CreateDesktop` default rather than anything Loopwall
/// invents — the same switch the well-known `defaults write com.apple.finder
/// CreateDesktop -bool false` recipe flips. Finder caches it at launch, so the
/// change only takes effect once Finder is restarted.
///
/// It is a system-wide setting: it stays in whatever state you leave it, even
/// after Loopwall quits.
enum DesktopIcons {
    private static let finderDomain = "com.apple.finder"
    private static let key = "CreateDesktop"

    /// Icons are shown unless Finder has been explicitly told otherwise.
    static var areHidden: Bool {
        guard let defaults = UserDefaults(suiteName: finderDomain),
              defaults.object(forKey: key) != nil
        else { return false }
        return !defaults.bool(forKey: key)
    }

    static func setHidden(_ hidden: Bool) {
        guard let defaults = UserDefaults(suiteName: finderDomain) else { return }
        defaults.set(!hidden, forKey: key)
        defaults.synchronize()
        restartFinder()
    }

    /// Finder is managed by launchd, so terminating it brings it straight back
    /// with the new setting applied.
    private static func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
    }
}
