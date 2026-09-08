import Foundation

/// Describes one wallpaper shipped inside the app bundle. The video and its
/// thumbnail sit flat in `Contents/Resources/` (Xcode flattens folder
/// references added via a plain source glob), so `fileName`/`thumbnailName`
/// are looked up as plain bundle resources, no subdirectory.
struct BundledWallpaper {
    let id: UUID
    let name: String
    let fileName: String
    let thumbnailName: String
    let width: Int
    let height: Int
    let duration: Double
    let byteSize: Int64
}

enum BundledWallpapers {
    /// Ordered as they should appear in the library — first entry is the one
    /// applied by default on first launch.
    static let all: [BundledWallpaper] = [
        BundledWallpaper(id: UUID(uuidString: "6F1A2B3C-0001-4A00-9000-000000000001")!,
                         name: "Field to Mark",
                         fileName: "6F1A2B3C-0001-4A00-9000-000000000001.mp4",
                         thumbnailName: "6F1A2B3C-0001-4A00-9000-000000000001-thumb.png",
                         width: 3840, height: 2160, duration: 31.033333333333335, byteSize: 3393684),
        BundledWallpaper(id: UUID(uuidString: "6F1A2B3C-0002-4A00-9000-000000000002")!,
                         name: "Globe",
                         fileName: "6F1A2B3C-0002-4A00-9000-000000000002.mp4",
                         thumbnailName: "6F1A2B3C-0002-4A00-9000-000000000002-thumb.png",
                         width: 3840, height: 2160, duration: 12.0, byteSize: 6937841),
    ]

    /// Resolves a bundled wallpaper's video/thumbnail to their actual
    /// on-disk location inside the app bundle. `nil` if the resource is
    /// missing (shouldn't happen outside of local dev builds that skip it).
    static func resourceURLs(for wallpaper: BundledWallpaper) -> (video: URL, thumbnail: URL)? {
        guard let video = Bundle.main.url(forResource: wallpaper.id.uuidString, withExtension: "mp4"),
              let thumbnail = Bundle.main.url(forResource: "\(wallpaper.id.uuidString)-thumb", withExtension: "png")
        else { return nil }
        return (video, thumbnail)
    }
}
