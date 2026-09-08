import Foundation
import AVFoundation
import AppKit

// MARK: - Library item

/// One video in the user's wallpaper library. The file itself always lives inside
/// Application Support, so the app never depends on the original file staying put
/// (or on sandbox bookmarks surviving a relaunch).
struct WallpaperItem: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var fileName: String
    var thumbnailName: String
    var width: Int
    var height: Int
    var duration: Double
    var byteSize: Int64
    /// Size of the file the user picked, before transcoding. Equal to `byteSize`
    /// when imported as-is.
    var originalByteSize: Int64
    var addedAt: Date

    var url: URL { LibraryStore.mediaDirectory.appendingPathComponent(fileName) }
    var thumbnailURL: URL { LibraryStore.mediaDirectory.appendingPathComponent(thumbnailName) }

    var resolutionLabel: String { "\(width)×\(height)" }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var savingsLabel: String? {
        guard originalByteSize > byteSize, originalByteSize > 0 else { return nil }
        let pct = Int((1.0 - Double(byteSize) / Double(originalByteSize)) * 100)
        guard pct >= 1 else { return nil }
        return "\(pct)% smaller"
    }

    var durationLabel: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - How the video fills a display

enum FitMode: String, Codable, CaseIterable, Identifiable {
    case fill, fit, stretch
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fill: return "Fill screen"
        case .fit: return "Fit (letterbox)"
        case .stretch: return "Stretch"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .stretch: return .resize
        }
    }
}

// MARK: - Compression presets

/// A single knob the user turns at import time. Bitrate is derived from pixel
/// count so a 720p and a 4K clip at the same preset look equally clean.
enum Quality: String, Codable, CaseIterable, Identifiable {
    case original, uhd, qhd, fhd, hd
    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original (no re-encode)"
        case .uhd: return "4K · 2160p"
        case .qhd: return "1440p"
        case .fhd: return "1080p (recommended)"
        case .hd: return "720p (smallest)"
        }
    }

    var shortLabel: String {
        switch self {
        case .original: return "Original"
        case .uhd: return "4K"
        case .qhd: return "1440p"
        case .fhd: return "1080p"
        case .hd: return "720p"
        }
    }

    /// Longest edge of the output, in pixels. `nil` means "don't resize".
    var maxDimension: CGFloat? {
        switch self {
        case .original: return nil
        case .uhd: return 3840
        case .qhd: return 2560
        case .fhd: return 1920
        case .hd: return 1280
        }
    }

    /// Rough output size so the import sheet can show an estimate before encoding.
    func estimatedBytes(sourceWidth: Int, sourceHeight: Int, fps: Double, duration: Double, capFrameRate: Bool) -> Int64 {
        let target = Transcoder.targetSize(width: sourceWidth, height: sourceHeight, maxDimension: maxDimension)
        let effectiveFPS = capFrameRate ? min(fps, 30) : fps
        let bitrate = Double(target.width * target.height) * effectiveFPS
            * Transcoder.bitsPerPixel(forHeight: target.height)
        return Int64(bitrate * duration / 8.0)
    }
}

// MARK: - Persisted preferences

struct Preferences: Codable {
    /// Stable display identifier -> library item id.
    var assignments: [String: UUID] = [:]
    var fitMode: FitMode = .fill
    var pauseWhenCovered: Bool = true
    var pauseOnBattery: Bool = false
    var pauseInLowPowerMode: Bool = true
    var pauseOnScreenSaverAndLock: Bool = true
    /// User-driven pause from the menu bar.
    var manuallyPaused: Bool = false
    var lastImportQuality: Quality = .fhd
    var capFrameRateAt30: Bool = true
    var hasCompletedFirstRun: Bool = false

    private static let key = "preferences.v1"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return Preferences() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
